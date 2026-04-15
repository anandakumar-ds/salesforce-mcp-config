# 03 — IVR Nodeflow Design (Call Channel)

**Audience:** ECC Admin, Exotel Professional Services
**Purpose:** Route inbound support calls to tier-appropriate queues based on live Salesforce lookup of caller's Account tier.
**Platform:** Exotel 4x or 6x (Harmony) — documented capabilities only.

---

## 1. Scope & Capability Statement

### Documented Capability
Per [docs.exotel.com/contact-center](https://docs.exotel.com/contact-center) and [docs.exotel.com/harmony](https://docs.exotel.com/harmony):

- **IVR nodeflow (callflow)** — supported on both 4x and 6x
- **HTTP action / Webhook node** in IVR — supported for pulling data mid-call from external systems
- **Variable capture and branching** in IVR — standard
- **Queue assignment / skill-based routing** — standard

### Not Documented / Requires PS Confirmation
- Exact request timeout behavior and retry semantics of the HTTP action node
- Maximum payload size for variables passed to agent via CTI call context
- Exact syntax for OAuth 2.0 client credentials handshake embedded in IVR (most customers use middleware for this)

> **For anything marked "requires PS confirmation," see [05 — PS Engagement Brief](./05-ps-engagement-brief.md).**

---

## 2. Architecture Options

### Option A — Direct IVR → Salesforce (Simpler, Riskier)

```
Caller → Exotel IVR → HTTP GET to Salesforce /services/data/v59.0/query/
                   ↓
                   (OAuth token must be pre-negotiated and injected as header)
                   ↓
                   Response parsed in IVR
                   ↓
                   Queue assignment
```

**Pros:** Fewer moving parts, no middleware to maintain.
**Cons:**
- OAuth token refresh inside IVR is non-trivial (tokens expire every 2 hours)
- Salesforce API errors/timeouts hit caller wait time directly
- Hard to add caching
- Security: OAuth credentials stored in IVR config = audit risk

### Option B — IVR → Middleware → Salesforce (Recommended)

```
Caller → Exotel IVR → HTTP GET to middleware endpoint (sub-100ms cached response)
                                      ↓
                             Token mgmt, caching, retries
                                      ↓
                             Salesforce /services/data/v59.0/query/
```

**Pros:**
- Token refresh handled outside IVR
- 5-minute in-memory cache on phone → tier mapping dramatically reduces SF API load
- Single place to add retries, circuit breakers
- Security: OAuth creds live in middleware vault, not IVR config
- Easier to add business logic (override lists, test numbers)

**Cons:** Extra service to deploy and monitor.

### Recommendation: **Option B**

Middleware can be minimal — a 200-line Node.js / Python service with:
- `/lookup?phone=XXX` endpoint
- In-memory LRU cache (5-min TTL)
- Salesforce OAuth client credentials flow with refresh
- Deploy on AWS Lambda + API Gateway, or existing internal service infra

This doc specifies Option B design. Option A is mentioned only as fallback if middleware is not approved.

---

## 3. Middleware Specification

### 3.1 — API Contract

**Endpoint:**
```
GET https://support-router.internal.exotel.com/api/v1/account-tier?phone={e164_phone}
Headers:
  Authorization: Bearer <static-ivr-shared-secret>
  X-Request-Id: <ivr-session-id>
```

**Success Response (200):**
```json
{
  "matched": true,
  "account_id": "001XXXXXXXXXXXXXX",
  "account_name": "Acme Corp",
  "support_tier": "STRATEGIC",
  "rag_status": "GREEN",
  "csm_name": "Priya Sharma",
  "csm_email": "priya@exotel.com",
  "support_group": "Normal Support",
  "is_hypercare": false,
  "lookup_source": "cache" | "salesforce",
  "lookup_ms": 42
}
```

**No Match (200):**
```json
{
  "matched": false,
  "phone_queried": "+919876543210"
}
```

**Error (500 / timeout):**
```json
{
  "error": "salesforce_timeout",
  "message": "Salesforce API did not respond within 2s",
  "fallback_tier": "STANDARD"
}
```

IVR should treat **any non-200 response** as `tier = STANDARD` and route accordingly.

---

### 3.2 — Salesforce Query Used by Middleware

```sql
SELECT
    Id, Name,
    Support_Tier__c,
    RAG__c,
    Hypercare_active__c,
    Support_Group__c,
    Account_CSM__r.Name,
    Account_CSM__r.Email
FROM Account
WHERE (Phone = :normalizedPhone OR Phone = :plus91Phone OR Phone = :bareIndianPhone)
  AND IsDeleted = FALSE
LIMIT 1
```

Middleware normalizes phone into 3 formats (`+919876543210`, `919876543210`, `9876543210`) and passes all three as bind variables.

**Fallback query** (if Account.Phone miss): check Contact.Phone

```sql
SELECT AccountId, Account.Support_Tier__c, Account.RAG__c, Account.Name,
       Account.Account_CSM__r.Name, Account.Account_CSM__r.Email
FROM Contact
WHERE (Phone = :normalizedPhone OR MobilePhone = :normalizedPhone OR
       Phone = :plus91Phone OR MobilePhone = :plus91Phone)
  AND AccountId != NULL
LIMIT 1
```

---

### 3.3 — Middleware Authentication to Salesforce

Use **OAuth 2.0 Client Credentials Flow** via a Salesforce Connected App.

**Connected App Configuration (SF Admin task):**

| Setting | Value |
|---|---|
| Name | `ECC Revenue Router` |
| API Enabled | Yes |
| OAuth Scopes | `api`, `refresh_token`, `offline_access` |
| Require Secret for Web Server Flow | Yes |
| Client Credentials Flow Run-As User | A dedicated integration user with read-only access to Account, Contact |
| IP Restrictions | Middleware service IP range |

**Token Request (middleware):**
```
POST https://ameyo.my.salesforce.com/services/oauth2/token
Body: grant_type=client_credentials
      &client_id=<consumer_key>
      &client_secret=<consumer_secret>
```

Token valid for 2 hours. Middleware refreshes on 401 response. Keep a 5-min buffer before expiry to avoid race.

---

### 3.4 — Middleware Caching

- **Cache key:** normalized phone
- **Cache value:** full response payload
- **TTL:** 300 seconds (5 min)
- **Invalidation:** none (naturally expires)

If Account tier changes mid-call-cycle, propagation takes up to 5 minutes. Acceptable given tier changes are infrequent.

---

## 4. IVR Nodeflow Design

### 4.1 — Node Map

```
[START: Inbound Call]
       │
       ▼
[Node 1] CAPTURE CALLER ID (ANI)
  {{caller_number}} auto-captured
       │
       ▼
[Node 2] NORMALIZE (optional regex strip)
  strip '+', '91' prefix, spaces — store as {{normalized_phone}}
       │
       ▼
[Node 3] HTTP GET to middleware
  URL: https://support-router.internal.exotel.com/api/v1/account-tier?phone={{normalized_phone}}
  Headers: Authorization: Bearer <shared-secret>
  Timeout: 2s
  On timeout/error → Node 5e (Standard queue)
       │
       ▼
[Node 4] PARSE RESPONSE → extract support_tier, account_name, csm_name, rag_status
       │
       ▼
[Node 5] BRANCH on {{support_tier}}
  ├─ "HYPERCARE" → Node 6a (Hypercare Queue)
  ├─ "STRATEGIC" → Node 6b (Strategic Queue)
  ├─ "PREMIUM"   → Node 6c (Premium Queue)
  ├─ "STANDARD"  → Node 6d (Standard FLR Queue)
  └─ "" / null   → Node 6e (Unknown/Helpdesk Queue + log)
       │
       ▼
[Node 6x] ANNOUNCE + HOLD
  Play tier-specific hold message while waiting
       │
       ▼
[Node 7] TRANSFER TO QUEUE
  Pass call context payload to agent
       │
       ▼
[END: Agent answers → CTI screen pop fires]
```

---

### 4.2 — Node Detail

#### Node 1 — Capture Caller ID

- **Node type:** Built-in / automatic
- **Variable:** `{{caller_number}}` — populated by ECC from SIP headers / PSTN signaling
- **Edge cases:**
  - If private / masked CLI → `{{caller_number}}` is blank or `anonymous`
  - Branch: if blank → skip to Node 6e (Unknown queue)

#### Node 2 — Normalize Phone

- **Node type:** Variable manipulation / set-variable
- **Action:** strip `+`, leading country code `91`, whitespace
- **Logic (pseudo):**
  ```
  {{normalized_phone}} = replace({{caller_number}}, /[\s+\-()]/g, '')
  if length({{normalized_phone}}) == 12 && starts_with({{normalized_phone}}, '91')
      {{normalized_phone}} = substring({{normalized_phone}}, 2)
  ```
- **Result:** 10-digit Indian mobile format, or original for international

> **PS confirmation:** IVR nodeflow variable manipulation syntax varies between 4x and 6x. PS to provide the exact syntax for the customer's deployment.

#### Node 3 — HTTP GET to Middleware

- **Node type:** HTTP action / Webhook
- **Method:** GET
- **URL:** `https://support-router.internal.exotel.com/api/v1/account-tier?phone={{normalized_phone}}`
- **Headers:**
  ```
  Authorization: Bearer <static-shared-secret-configured-in-IVR>
  X-Request-Id: {{call_sid}}
  Accept: application/json
  ```
- **Timeout:** 2 seconds
- **Response parse:** store full response as `{{sf_response}}` (JSON object)
- **On success (2xx):** proceed to Node 4
- **On timeout / 5xx:** proceed directly to Node 6e with `{{support_tier}} = "STANDARD"` and log error

#### Node 4 — Parse Response

Extract fields into IVR variables:
```
{{support_tier}}   = {{sf_response.support_tier}}
{{account_name}}   = {{sf_response.account_name}}
{{csm_name}}       = {{sf_response.csm_name}}
{{rag_status}}     = {{sf_response.rag_status}}
{{matched}}        = {{sf_response.matched}}
```

If `{{matched}} = false` → set `{{support_tier}} = "UNKNOWN"` and proceed.

#### Node 5 — Branch Decision

Conditional routing based on `{{support_tier}}`:

| Condition | Branch |
|---|---|
| `{{support_tier}} == "HYPERCARE"` | Node 6a |
| `{{support_tier}} == "STRATEGIC"` | Node 6b |
| `{{support_tier}} == "PREMIUM"` | Node 6c |
| `{{support_tier}} == "STANDARD"` | Node 6d |
| else | Node 6e |

#### Nodes 6a–6e — Queue Assignment

| Branch | Queue | Hold Music / IVR Prompt | Expected Wait (target) |
|---|---|---|---|
| 6a HYPERCARE | Hypercare Support Queue | "Connecting you to your dedicated support team..." | < 30s |
| 6b STRATEGIC | Strategic Support Queue | "Thank you for calling, connecting to priority support..." | < 60s |
| 6c PREMIUM | Premium Support Queue | "Thank you for calling. Please hold while we connect you." | < 120s |
| 6d STANDARD | FLR Support Queue | Standard Exotel Care IVR prompt | Per existing SLA |
| 6e UNKNOWN | Classification/Helpdesk Queue | "Please hold while we transfer your call." | Per existing SLA |

#### Node 7 — Transfer to Queue with Call Context

When agent is selected and ringing, pass these variables as **call context payload** to the agent's CTI softphone:

```json
{
  "account_name": "{{account_name}}",
  "support_tier": "{{support_tier}}",
  "rag_status": "{{rag_status}}",
  "csm_name": "{{csm_name}}",
  "caller_number": "{{caller_number}}",
  "lookup_source": "{{sf_response.lookup_source}}"
}
```

This payload is consumed by the CTI softphone (Open CTI adapter in Salesforce). See [04 — Screen Pop & Layouts](./04-screen-pop-and-layouts.md) for consumption details.

> **PS confirmation:** Exact field list that can be passed as call context varies by ECC version and CTI adapter version. PS to confirm.

---

## 5. Edge Cases & Fallbacks

| Scenario | Handling |
|---|---|
| CLI private / anonymous | Skip lookup → UNKNOWN queue + flag for post-call review |
| CLI is an unknown number (not in SF) | UNKNOWN queue with a short prompt asking caller to provide account ID via DTMF |
| Middleware timeout (>2s) | STANDARD queue with no disruption to caller |
| Middleware returns `tier = HYPERCARE` but no agents logged in | ECC queue overflow rules take over — define overflow to Strategic queue → then Standard queue |
| Caller calls repeatedly (same ANI, back-to-back) | Cache ensures consistent tier; log repeated callers for follow-up |
| Number matches multiple accounts (SF query returned first) | Middleware logs warning, IVR proceeds with first match; Data team cleans up |
| International number (no +91) | Middleware attempts international lookup; if no match, STANDARD queue |

---

## 6. Testing Approach

### 6.1 — Pre-Launch Tests

Run each test by placing a real call from a test phone to the IVR DID.

| # | Test | Expected Behavior |
|---|---|---|
| T1 | Call from a registered Strategic customer phone | Routed to Strategic Support Queue, prompt played, agent sees context payload |
| T2 | Call from Hypercare customer (flag active + future end date) | Routed to Hypercare Queue |
| T3 | Call from Hypercare customer (flag active but end date expired) | Routed per base tier (NOT Hypercare) |
| T4 | Call from Premium (SAAS Enterprise + RAG GREEN) | Premium Queue |
| T5 | Call from unknown number | UNKNOWN / Helpdesk Queue |
| T6 | Call from a number that exists in SF but tier = STANDARD | Standard FLR Queue |
| T7 | Middleware disabled / down during test | STANDARD Queue, caller experience unaffected |
| T8 | Middleware returns 500 | STANDARD Queue |
| T9 | Middleware slow (inject 3s delay) | Timeout after 2s → STANDARD Queue |
| T10 | Private / masked CLI | UNKNOWN Queue |

### 6.2 — Load Test

Middleware under load:
- Target: handle 100 req/sec sustained (BHCA max is 100k/hr = 28 req/sec across all customers)
- Cache hit ratio target: > 80% after warm-up
- p99 latency target: < 300ms

---

## 7. Monitoring & Observability

### IVR-side
- Log every HTTP callout: request phone, response tier, response time, cache hit/miss
- Dashboard metric: % calls with successful tier lookup (target > 90%)
- Dashboard metric: % calls falling to STANDARD due to middleware failure (target < 2%)

### Middleware-side
- Emit structured logs per request: phone, tier, source (cache/sf), latency, status
- Metrics: request rate, cache hit rate, SF API latency, error rate
- Alerting: SF API error rate > 5% over 5 min → page on-call

### Salesforce-side
- Monitor API usage from Integration User; alert if nearing daily API limit
- Monthly report on tier distribution (see [06](./06-test-and-rollout.md))

---

## 8. Security & Compliance

| Concern | Mitigation |
|---|---|
| Salesforce credentials in IVR config | Option B middleware keeps creds out of IVR — stored in vault |
| Static shared secret between IVR and middleware | Rotate quarterly; restrict by source IP |
| Phone numbers logged in middleware | Consider hashing for audit logs; retention policy 30 days |
| Integration user permissions | Read-only on Account, Contact only; no write permissions |
| PII exposure | Only Account Name, CSM name, tier, RAG transmitted — no customer PII beyond phone |

---

## 9. Rollback Plan

Rollback must be executable in < 5 minutes:

1. **Disable HTTP callout node** in IVR nodeflow → all calls fall through to existing queue routing
2. Or: **Flip feature flag** in middleware to always return `STANDARD` tier
3. Or: **Revert IVR nodeflow** to previous published version (both 4x and 6x support nodeflow versioning)

No Salesforce-side rollback needed — Case Flow operates independently and has its own rollback (deactivate Flow).

---

## 10. Open Questions for PS

See [05 — PS Engagement Brief](./05-ps-engagement-brief.md) for the full list. Highlights:

1. Does the 4x / 6x HTTP action node support 2-second timeout with graceful fallback?
2. What is the max payload size for call context variables passed to agent?
3. Is there a native OAuth 2.0 flow in IVR nodeflow, or must we use static bearer token via middleware?
4. Can we pass structured JSON as call context, or must we pass key-value pairs?
5. What's the recommended pattern for queue overflow when tier-specific queue has no available agents?
