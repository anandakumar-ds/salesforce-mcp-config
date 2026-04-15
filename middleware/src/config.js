'use strict';

/**
 * Environment configuration loader for the ECC Revenue Router middleware.
 *
 * Reads `.env` via `dotenv`, validates required variables, and freezes the
 * resulting object so callers cannot mutate it at runtime.
 */

require('dotenv').config();

function required(name) {
    const v = process.env[name];
    if (!v || String(v).trim() === '') {
        throw new Error(`Missing required env var: ${name}`);
    }
    return v;
}

function optional(name, fallback) {
    const v = process.env[name];
    return v === undefined || v === '' ? fallback : v;
}

function toInt(name, fallback) {
    const v = process.env[name];
    if (v === undefined || v === '') return fallback;
    const n = parseInt(v, 10);
    if (Number.isNaN(n)) throw new Error(`Env var ${name} must be an integer, got "${v}"`);
    return n;
}

const config = Object.freeze({
    port: toInt('PORT', 8080),
    nodeEnv: optional('NODE_ENV', 'development'),
    logLevel: optional('LOG_LEVEL', 'info'),

    salesforce: Object.freeze({
        loginUrl: required('SF_LOGIN_URL'),
        clientId: required('SF_CLIENT_ID'),
        clientSecret: required('SF_CLIENT_SECRET'),
        apiVersion: optional('SF_API_VERSION', '62.0'),
    }),

    cache: Object.freeze({
        maxItems: toInt('CACHE_MAX_ITEMS', 50000),
        ttlSeconds: toInt('CACHE_TTL_SECONDS', 900),
    }),

    routerSharedKey: required('ROUTER_SHARED_KEY'),

    // Optional env overrides — if set, these skip the Salesforce
    // Queue_Config__mdt lookup at startup.
    queueOverrides: Object.freeze({
        HYPERCARE: optional('QUEUE_HYPERCARE'),
        STRATEGIC: optional('QUEUE_STRATEGIC'),
        PREMIUM: optional('QUEUE_PREMIUM'),
        STANDARD: optional('QUEUE_STANDARD'),
    }),
});

module.exports = config;
