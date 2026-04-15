'use strict';

/**
 * In-memory LRU cache for phone-number → tier context lookups.
 *
 * Rationale: a single customer hotline number can receive thousands of calls
 * per hour; the Salesforce Account they map to rarely changes within a
 * 15-minute window. TTL is short enough that RAG/Hypercare changes surface
 * quickly during an active incident, long enough to absorb call spikes
 * without hammering the API.
 */

const { LRUCache } = require('lru-cache');
const config = require('./config');

const cache = new LRUCache({
    max: config.cache.maxItems,
    ttl: config.cache.ttlSeconds * 1000,
    allowStale: false,
    updateAgeOnGet: false,
    updateAgeOnHas: false,
});

/**
 * Build a namespaced cache key — prevents accidental collision between
 * lookup kinds (e.g. phone vs. account-id) if we extend later.
 * @param {string} kind
 * @param {string} id
 * @returns {string}
 */
function key(kind, id) {
    return `${kind}:${id}`;
}

function get(kind, id) {
    return cache.get(key(kind, id));
}

function set(kind, id, value) {
    cache.set(key(kind, id), value);
}

function stats() {
    return {
        size: cache.size,
        max: cache.max,
    };
}

function clear() {
    cache.clear();
}

module.exports = { get, set, stats, clear };
