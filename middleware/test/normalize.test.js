'use strict';

/**
 * Unit tests for phone-number normalization.
 * Run with: `npm test`
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { toE164, variants, stripFormatting } = require('../src/normalize');

// --------- stripFormatting ---------
test('stripFormatting: removes spaces, dashes, parens', () => {
    assert.equal(stripFormatting('(+91) 98765-43210'), '+919876543210');
    assert.equal(stripFormatting('98765 43210'), '9876543210');
    assert.equal(stripFormatting(''), '');
    assert.equal(stripFormatting(null), '');
});

// --------- toE164 ---------
test('toE164: already-canonical +91 number', () => {
    assert.equal(toE164('+919876543210'), '+919876543210');
});

test('toE164: 10-digit Indian mobile', () => {
    assert.equal(toE164('9876543210'), '+919876543210');
});

test('toE164: leading 0 local Indian mobile', () => {
    assert.equal(toE164('09876543210'), '+919876543210');
});

test('toE164: 12-digit with 91 prefix (no plus)', () => {
    assert.equal(toE164('919876543210'), '+919876543210');
});

test('toE164: spaced/punctuated India number', () => {
    assert.equal(toE164('+91-98765-43210'), '+919876543210');
    assert.equal(toE164('+91 98765 43210'), '+919876543210');
});

test('toE164: rejects 5-digit garbage', () => {
    assert.equal(toE164('12345'), null);
});

test('toE164: rejects empty/null', () => {
    assert.equal(toE164(''), null);
    assert.equal(toE164(null), null);
});

test('toE164: US number +1415...', () => {
    assert.equal(toE164('+14155551234'), '+14155551234');
});

test('toE164: 00-prefixed international dial-out', () => {
    assert.equal(toE164('00919876543210'), '+919876543210');
});

// --------- variants ---------
test('variants: Indian +91 number yields all common formats', () => {
    const v = variants('+919876543210');
    assert.ok(v.includes('+919876543210'));
    assert.ok(v.includes('919876543210'));
    assert.ok(v.includes('9876543210'));
    assert.ok(v.includes('09876543210'));
});

test('variants: 10-digit input produces same canonical set', () => {
    const v = variants('9876543210');
    assert.ok(v.includes('+919876543210'));
    assert.ok(v.includes('9876543210'));
});

test('variants: deduplicates identical forms', () => {
    const v = variants('+919876543210');
    const seen = new Set(v);
    assert.equal(seen.size, v.length);
});

test('variants: empty/invalid returns empty array', () => {
    assert.deepEqual(variants(''), []);
    assert.deepEqual(variants('12345'), []);
});
