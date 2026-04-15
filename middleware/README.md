# ECC Revenue Router

Middleware that enriches Exotel IVR and Open CTI events with Salesforce
Account revenue-tier context (HYPERCARE / STRATEGIC / PREMIUM / STANDARD)
so inbound calls can be routed to the right queue and agents see the right
screen pop.

## Architecture

```
Exotel IVR  ──HTTP─▶  ECC Revenue Router  ──OAuth──▶  Salesforce
                     (this service)                  (Account/Contact)
                            │
                            ▼
                     LRU cache (15 min TTL)
```

The service is intentionally stateless apart from the in-memory cache: you
can run multiple replicas behind any HTTP load balancer. Each replica
maintains its own token and cache.

## Endpoints

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| `GET`  | `/health` | Liveness/readiness | none |
| `GET`  | `/v1/context?phone=+919876543210` | Return tier + RAG + CSM for the phone | `X-Router-Key` |
| `POST` | `/v1/route` | Return routing decision `{tier, queue_name, priority}` | `X-Router-Key` |

### `POST /v1/route` — request body

```json
{
  "phone": "+919876543210",
  "caller_id": "+919876543210",
  "call_sid": "exotel-abc-123"
}
```

### Response

```json
{
  "phone": "+919876543210",
  "call_sid": "exotel-abc-123",
  "tier": "HYPERCARE",
  "queue_name": "Hypercare_Support_Queue",
  "priority": "Critical",
  "account_id": "001xx000003DHP0AAO",
  "account_name": "Acme Corp",
  "rag": "RED",
  "is_hypercare": true,
  "csm_email": "jane@exotel.com",
  "reason": "matched via contact"
}
```

## Prerequisites

1. **Connected App** — `ECC_Revenue_Router` (see
   `force-app/main/default/connectedApps/ECC_Revenue_Router.connectedApp-meta.xml`).
   After deploying, open it in Setup and:
   - Enable "Enable Client Credentials Flow".
   - Set the "Run As" user to a dedicated integration user.
   - Capture the Consumer Key + Consumer Secret.
2. **Integration user** — API-only Salesforce user assigned the
   `ECC_Revenue_Router_Integration` permission set.
3. **Queue config** — Deploy the `Queue_Config__mdt` records (Hypercare,
   Strategic, Premium, Standard) and ensure the corresponding SF Queues
   already exist.

## Local development

```bash
cp .env.example .env
# fill in SF_CLIENT_ID, SF_CLIENT_SECRET, ROUTER_SHARED_KEY

npm install
npm run dev
```

Test against a known phone number:

```bash
curl -H "X-Router-Key: $ROUTER_SHARED_KEY" \
  "http://localhost:8080/v1/context?phone=%2B919876543210"
```

## Deployment

```bash
docker build -t ecc-revenue-router:latest .
docker run -p 8080:8080 --env-file .env ecc-revenue-router:latest
```

Point the Exotel IVR HTTP action node at `https://<host>/v1/route` with the
`X-Router-Key` header set. Configure the IVR to branch on `queue_name` and
transfer the call to the matching Salesforce-linked queue in Exotel.

## Observability

- **Structured logs** via `pino` — one log line per request with method,
  path, status, duration, phone (canonical), tier, queue_name.
- **Cache metrics** via `/health` — `cache.size` and `cache.max`.
- No PII is logged beyond the canonical phone number and Account ID.

## Security notes

- The `X-Router-Key` is a shared HMAC-style secret. Rotate via your secret
  manager; the service reads it at startup.
- The service talks to Salesforce over TLS using a Connected App — no
  username/password flow. Rotate the Consumer Secret periodically.
- The integration user has **read-only** access to Account, Contact, Case,
  and `Queue_Config__mdt`. It cannot create or modify records.
