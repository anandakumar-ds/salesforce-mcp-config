'use strict';

/**
 * ECC Revenue Router — HTTP service.
 *
 * Endpoints
 *   GET  /health                 — liveness/readiness (no auth)
 *   GET  /v1/context?phone=...   — returns tier + RAG + CSM for a phone number
 *   POST /v1/route                — returns a routing decision for an inbound call
 *
 * Auth: all /v1/* endpoints require `X-Router-Key: <ROUTER_SHARED_KEY>`.
 * Compared with a constant-time check to avoid timing side-channels.
 *
 * Consumers
 *   - Exotel IVR HTTP action node → /v1/route
 *   - Open CTI softphone / screen-pop LWC → /v1/context
 *   - Internal debugging tools → /v1/context
 */

const crypto = require('node:crypto');
const express = require('express');
const pinoHttp = require('pino-http');
const pino = require('pino');

const config = require('./config');
const cache = require('./cache');
const sf = require('./salesforce');
const { toE164, variants } = require('./normalize');

const logger = pino({ level: config.logLevel });
const app = express();

app.disable('x-powered-by');
app.use(express.json({ limit: '32kb' }));
app.use(pinoHttp({ logger, redact: ['req.headers["x-router-key"]'] }));

// ------------------------------------------------------------------
// Queue map — loaded at startup, cached for the process lifetime
// ------------------------------------------------------------------
let queueMap = null;

async function ensureQueueMap() {
    if (queueMap) return queueMap;
    queueMap = await sf.loadQueueConfig();
    logger.info({ queueMap }, 'Loaded queue config');
    return queueMap;
}

// ------------------------------------------------------------------
// Auth middleware
// ------------------------------------------------------------------
function requireSharedKey(req, res, next) {
    const provided = req.header('X-Router-Key') || '';
    const expected = config.routerSharedKey;
    if (
        provided.length === expected.length &&
        crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected))
    ) {
        return next();
    }
    return res.status(401).json({ error: 'unauthorized' });
}

// ------------------------------------------------------------------
// Handlers
// ------------------------------------------------------------------
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        uptime_seconds: Math.round(process.uptime()),
        cache: cache.stats(),
        queue_map_loaded: queueMap !== null,
    });
});

/**
 * Core resolver — shared by /context and /route handlers.
 * Looks up the phone in cache, falls back to Salesforce.
 */
async function resolvePhoneContext(rawPhone, log) {
    const canonical = toE164(rawPhone);
    if (!canonical) {
        return { canonical: null, context: null, cacheHit: false };
    }

    const cached = cache.get('phone', canonical);
    if (cached !== undefined) {
        return { canonical, context: cached, cacheHit: true };
    }

    const lookupVariants = variants(rawPhone);
    let context;
    try {
        context = await sf.lookupAccountByPhone(lookupVariants);
    } catch (err) {
        log.error({ err: err.message, canonical }, 'Salesforce lookup failed');
        throw err;
    }

    // Cache both hits and misses to avoid repeat-churn on unknown numbers.
    cache.set('phone', canonical, context);
    return { canonical, context, cacheHit: false };
}

/**
 * GET /v1/context?phone=+919876543210
 * Returns the full tier/RAG/CSM payload for a phone number, or null if
 * no Account was matched.
 */
app.get('/v1/context', requireSharedKey, async (req, res) => {
    const phone = (req.query.phone || '').toString();
    if (!phone) return res.status(400).json({ error: 'missing phone' });

    try {
        const { canonical, context, cacheHit } = await resolvePhoneContext(phone, req.log);
        if (!canonical) {
            return res.status(400).json({ error: 'invalid_phone', phone });
        }
        return res.json({
            phone: canonical,
            cache_hit: cacheHit,
            context,  // may be null if no match
        });
    } catch (err) {
        return res.status(502).json({ error: 'salesforce_unavailable' });
    }
});

/**
 * POST /v1/route
 * Body: { phone: string, caller_id?: string, call_sid?: string }
 * Returns: { tier, queue_name, priority, account_id?, account_name?, rag?,
 *            is_hypercare?, reason }
 *
 * The IVR action node consumes `queue_name` to transfer the call and
 * `tier`/`priority` to set call metadata.
 */
app.post('/v1/route', requireSharedKey, async (req, res) => {
    const body = req.body || {};
    const phone = (body.phone || body.caller_id || '').toString();
    const callSid = (body.call_sid || '').toString();

    if (!phone) return res.status(400).json({ error: 'missing phone' });

    try {
        await ensureQueueMap();
        const { canonical, context } = await resolvePhoneContext(phone, req.log);
        if (!canonical) {
            return res.status(400).json({ error: 'invalid_phone', phone });
        }

        const tier = context ? context.tier : 'UNKNOWN';
        const queueName = queueMap[tier] || queueMap.STANDARD;

        // Priority mapping for Case creation and call-queue hold music;
        // IVR can use this to set SIP priority headers if desired.
        const priority =
            tier === 'HYPERCARE'
                ? 'Critical'
                : tier === 'STRATEGIC'
                  ? 'Critical'
                  : tier === 'PREMIUM'
                    ? 'Major'
                    : 'Minor';

        const response = {
            phone: canonical,
            call_sid: callSid || null,
            tier,
            queue_name: queueName,
            priority,
            account_id: context ? context.account_id : null,
            account_name: context ? context.account_name : null,
            rag: context ? context.rag : null,
            is_hypercare: context ? context.is_hypercare_active : false,
            csm_email: context && context.csm ? context.csm.email : null,
            reason: context
                ? `matched via ${context.match.source || 'unknown'}`
                : 'no_account_match',
        };

        req.log.info(
            {
                phone: canonical,
                tier,
                queueName,
                matched: Boolean(context),
                callSid,
            },
            'route_decision'
        );

        return res.json(response);
    } catch (err) {
        req.log.error({ err: err.message }, 'Route handler failed');
        return res.status(502).json({ error: 'salesforce_unavailable' });
    }
});

// ------------------------------------------------------------------
// Error handler
// ------------------------------------------------------------------
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
    logger.error({ err: err.message, stack: err.stack }, 'Unhandled error');
    res.status(500).json({ error: 'internal_error' });
});

// ------------------------------------------------------------------
// Startup
// ------------------------------------------------------------------
async function start() {
    try {
        await ensureQueueMap();
    } catch (err) {
        logger.error(
            { err: err.message },
            'Failed to load queue map at startup — will retry on first /route call'
        );
    }

    app.listen(config.port, () => {
        logger.info(
            { port: config.port, env: config.nodeEnv },
            'ECC Revenue Router listening'
        );
    });
}

if (require.main === module) {
    start();
}

module.exports = app;
