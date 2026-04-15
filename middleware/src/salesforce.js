'use strict';

/**
 * Salesforce client for the ECC Revenue Router.
 *
 * Uses OAuth 2.0 Client Credentials flow against the `ECC_Revenue_Router`
 * connected app. A dedicated integration user (assigned the
 * `ECC_Revenue_Router_Integration` permission set) is the running user
 * configured on the connected app. This middleware holds no end-user
 * credentials.
 *
 * Responsibilities:
 *  - Fetch/refresh access tokens transparently.
 *  - Resolve a phone number to its Account via Contact/Account phone fields.
 *  - Return tier + RAG + CSM context in a shape the IVR/CTI can consume.
 */

const jsforce = require('jsforce');
const config = require('./config');

let cachedToken = null; // { accessToken, instanceUrl, expiresAtMs }

const TOKEN_BUFFER_MS = 60 * 1000; // refresh 60s before expiry

/**
 * Exchange client credentials for an access token.
 * @returns {Promise<{accessToken: string, instanceUrl: string, expiresAtMs: number}>}
 */
async function fetchToken() {
    const url = `${config.salesforce.loginUrl}/services/oauth2/token`;
    const body = new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: config.salesforce.clientId,
        client_secret: config.salesforce.clientSecret,
    });

    const resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
    });

    if (!resp.ok) {
        const text = await resp.text();
        throw new Error(`Salesforce token endpoint returned ${resp.status}: ${text}`);
    }

    const json = await resp.json();

    // Salesforce client-credentials responses don't always include expires_in
    // — default to 2 hours (conservative) and refresh well before.
    const expiresInSec = json.expires_in ? Number(json.expires_in) : 7200;

    return {
        accessToken: json.access_token,
        instanceUrl: json.instance_url,
        expiresAtMs: Date.now() + expiresInSec * 1000,
    };
}

/**
 * Return a jsforce Connection with a fresh-enough token.
 * @returns {Promise<jsforce.Connection>}
 */
async function getConnection() {
    const now = Date.now();
    if (!cachedToken || cachedToken.expiresAtMs - TOKEN_BUFFER_MS < now) {
        cachedToken = await fetchToken();
    }
    return new jsforce.Connection({
        instanceUrl: cachedToken.instanceUrl,
        accessToken: cachedToken.accessToken,
        version: config.salesforce.apiVersion,
    });
}

/**
 * Escape a string for safe interpolation into a SOQL string literal.
 * Doubles single quotes and backslashes — callers must still wrap with
 * single quotes in the SOQL template.
 * @param {string} s
 * @returns {string}
 */
function soqlEscape(s) {
    return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

/**
 * Look up an Account by phone-number variants.
 * Returns the single best-scoring Account context, or null if no match.
 *
 * Match priority (caller-configurable via ordering of `phoneVariants`):
 *   1. Contact.Phone / Contact.MobilePhone → Contact.Account
 *   2. Account.Phone
 *
 * @param {string[]} phoneVariants - Non-empty, deduplicated list.
 * @returns {Promise<object|null>}
 */
async function lookupAccountByPhone(phoneVariants) {
    if (!Array.isArray(phoneVariants) || phoneVariants.length === 0) return null;

    const conn = await getConnection();
    const inClause = phoneVariants.map((v) => `'${soqlEscape(v)}'`).join(',');

    // Contact-first match — returns the parent Account with all tier context.
    const contactSoql = `
        SELECT Id, Name, Phone, MobilePhone, AccountId,
               Account.Id, Account.Name,
               Account.Support_Tier__c, Account.Support_Tier_Badge__c,
               Account.RAG__c, Account.Top_Customer__c,
               Account.Is_SAAS_Premium_Account__c, Account.SAAS_Enterprise_Account__c,
               Account.Hypercare_active__c, Account.Hypercare_End_Date__c,
               Account.Cluster__c, Account.Region__c,
               Account.Account_CSM__r.Id, Account.Account_CSM__r.Name,
               Account.Account_CSM__r.Email
        FROM Contact
        WHERE AccountId != null
          AND (Phone IN (${inClause}) OR MobilePhone IN (${inClause}))
        LIMIT 1
    `;

    const contactResult = await conn.query(contactSoql);
    if (contactResult.totalSize > 0) {
        const c = contactResult.records[0];
        return shapeContext(c.Account, { source: 'contact', contactId: c.Id, contactName: c.Name });
    }

    // Fallback — match on Account.Phone directly
    const accountSoql = `
        SELECT Id, Name, Phone,
               Support_Tier__c, Support_Tier_Badge__c,
               RAG__c, Top_Customer__c,
               Is_SAAS_Premium_Account__c, SAAS_Enterprise_Account__c,
               Hypercare_active__c, Hypercare_End_Date__c,
               Cluster__c, Region__c,
               Account_CSM__r.Id, Account_CSM__r.Name, Account_CSM__r.Email
        FROM Account
        WHERE Phone IN (${inClause})
        LIMIT 1
    `;

    const accountResult = await conn.query(accountSoql);
    if (accountResult.totalSize > 0) {
        return shapeContext(accountResult.records[0], { source: 'account' });
    }

    return null;
}

/**
 * Normalize a raw Account SObject into the response payload.
 * Keeps the IVR/CTI wire format stable even if SF field names change.
 */
function shapeContext(acct, extras) {
    if (!acct) return null;
    const csm = acct.Account_CSM__r || null;
    return {
        account_id: acct.Id,
        account_name: acct.Name,
        tier: acct.Support_Tier__c || 'UNKNOWN',
        tier_badge: acct.Support_Tier_Badge__c || null,
        rag: acct.RAG__c || null,
        is_hypercare_active: acct.Hypercare_active__c === 'Active',
        hypercare_end_date: acct.Hypercare_End_Date__c || null,
        top_customer: Boolean(acct.Top_Customer__c),
        is_saas_premium: Boolean(acct.Is_SAAS_Premium_Account__c),
        is_saas_enterprise: Boolean(acct.SAAS_Enterprise_Account__c),
        cluster: acct.Cluster__c || null,
        region: acct.Region__c || null,
        csm: csm
            ? { id: csm.Id, name: csm.Name, email: csm.Email || null }
            : null,
        match: extras || {},
    };
}

/**
 * Load tier → queue mapping from Queue_Config__mdt (unless env overrides
 * are set, in which case those win). Call once at startup.
 * @returns {Promise<Record<string, string>>}
 */
async function loadQueueConfig() {
    const overrides = config.queueOverrides;
    const anyOverride = Object.values(overrides).some((v) => v && v.trim() !== '');
    if (anyOverride) {
        return {
            HYPERCARE: overrides.HYPERCARE || 'Hypercare_Support_Queue',
            STRATEGIC: overrides.STRATEGIC || 'Strategic_Support_Queue',
            PREMIUM: overrides.PREMIUM || 'Premium_Support_Queue',
            STANDARD: overrides.STANDARD || 'FLR_Support_Queue',
        };
    }

    const conn = await getConnection();
    const soql = `
        SELECT Tier__c, Queue_DeveloperName__c
        FROM Queue_Config__mdt
        WHERE Active__c = true
    `;
    const result = await conn.query(soql);
    const map = {};
    for (const row of result.records) {
        if (row.Tier__c && row.Queue_DeveloperName__c) {
            map[row.Tier__c] = row.Queue_DeveloperName__c;
        }
    }
    // Safety default for UNKNOWN tier
    if (!map.UNKNOWN) map.UNKNOWN = map.STANDARD || 'FLR_Support_Queue';
    return map;
}

module.exports = {
    getConnection,
    lookupAccountByPhone,
    loadQueueConfig,
    _fetchToken: fetchToken, // exposed for tests / debugging
};
