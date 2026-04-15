'use strict';

/**
 * Phone-number normalization for Indian + international numbers.
 *
 * Salesforce Phone/MobilePhone fields in this org are inconsistent — some
 * records have `+91`, some `91`, some leading `0`, some are 10-digit local.
 * To maximize match rate we produce a canonical E.164 form *and* a set of
 * lookup variants that cover the common mis-formats.
 */

/**
 * Strip everything that isn't a digit (keep a leading +).
 * @param {string} raw
 * @returns {string}
 */
function stripFormatting(raw) {
    if (raw === null || raw === undefined) return '';
    const s = String(raw).trim();
    if (s === '') return '';
    const hasPlus = s.startsWith('+');
    const digits = s.replace(/\D+/g, '');
    return hasPlus ? `+${digits}` : digits;
}

/**
 * Best-effort canonicalization to E.164. Assumes India (+91) when no
 * country code is present and the number is 10 digits (mobile) or starts
 * with 0 (local).
 * @param {string} raw
 * @returns {string|null} E.164 form or null if unrecognized.
 */
function toE164(raw) {
    const s = stripFormatting(raw);
    if (!s) return null;

    // Already E.164 — accept if 8-15 digits after the +
    if (s.startsWith('+')) {
        const d = s.slice(1);
        if (d.length >= 8 && d.length <= 15) return `+${d}`;
        return null;
    }

    // Bare digit string
    const d = s;

    // 10-digit mobile — India
    if (d.length === 10 && /^[6-9]/.test(d)) return `+91${d}`;

    // 11-digit with leading 0 — India local
    if (d.length === 11 && d.startsWith('0') && /^0[6-9]/.test(d)) return `+91${d.slice(1)}`;

    // 12-digit starting 91 — India without plus
    if (d.length === 12 && d.startsWith('91') && /^91[6-9]/.test(d)) return `+${d}`;

    // 13-digit with 00 prefix (international dial-out)
    if (d.length >= 12 && d.startsWith('00')) {
        const intl = d.slice(2);
        if (intl.length >= 8 && intl.length <= 15) return `+${intl}`;
    }

    // Otherwise, if 8-15 digits, treat as already-international
    if (d.length >= 8 && d.length <= 15) return `+${d}`;

    return null;
}

/**
 * Build the set of lookup variants we'll query Salesforce with.
 * The order is "most-likely-match first" but callers should combine them
 * into a single SOQL `IN` clause.
 *
 * @param {string} raw
 * @returns {string[]} deduplicated list of variants (may be empty)
 */
function variants(raw) {
    const canonical = toE164(raw);
    if (!canonical) return [];

    const out = new Set();
    out.add(canonical);

    // Strip + ("919876543210")
    const noPlus = canonical.slice(1);
    out.add(noPlus);

    // Indian variants — +91XXXXXXXXXX → last 10 digits
    if (canonical.startsWith('+91') && canonical.length === 13) {
        const last10 = canonical.slice(3);
        out.add(last10);                 // 9876543210
        out.add(`0${last10}`);           // 09876543210
        out.add(`91${last10}`);          // 919876543210 (dup guard)
        out.add(`+91 ${last10}`);        // "+91 9876543210"
        out.add(`+91-${last10}`);        // "+91-9876543210"
    }

    return Array.from(out);
}

module.exports = { stripFormatting, toE164, variants };
