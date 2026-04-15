# Revenue-Aware ECC Routing — Deployment Plan & Architecture

**Audience:** Professional Services, CX Ops, Support Leadership
**Owner:** Shivanand (shivanand@exotel.com)
**Branch:** `claude/upbeat-ride`
**Status:** Salesforce side built; awaiting PS engagement for telephony wiring.

---

## 1. Executive summary

Every inbound support call and every new Salesforce Case will carry the
account's revenue tier as metadata, so routing, priority, and screen pop
become tier-aware without manual agent lookup. Tiers are derived from
existing Salesforce flags — no new data entry. The Salesforce + middleware
side is fully built; PS needs to wire the Exotel IVR and Open CTI
softphone to consume it.

| Tier | Driver (on Account) | Target queue |
|------|---------------------|--------------|
| HYPERCARE | `Hypercare_active__c = 'Active'` AND `Hypercare_End_Date__c >= NOW()` | Hypercare_Support_Queue |
| STRATEGIC | `Top_Customer__c = TRUE` OR `Is_SAAS_Premium_Account__c = TRUE` | Strategic_Support_Queue |
| PREMIUM | `SAAS_Enterprise_Account__c = TRUE` AND `RAG__c IN ('GREEN','AMBER')` | Premium_Support_Queue |
| STANDARD | everything else | FLR_Support_Queue |
| UNKNOWN | no Account link | FLR_Support_Queue (fallback) |

---

## 2. Architecture

```
 ┌─────────────────────┐        ┌────────────────────────────┐       ┌──────────────────┐
 │ Inbound call        │        │   ECC Revenue Router       │       │   Salesforce     │
 │ → Exotel IVR        │──HTTP─▶│  (Node/Express middleware) │──OAuth│  • Account       │
 │ (HTTP action node)  │        │   • /v1/route              │  CC───│  • Contact       │
 └─────────────────────┘        │   • /v1/context            │       │  • Queue_Config  │
                                │   • LRU cache (15 min TTL) │       └──────────────────┘
 ┌─────────────────────┐        └────────────────────────────┘
 │ Agent desktop       │                    ▲
 │ Open CTI softphone  │────────────────────┘
 │ (screen pop LWC)    │
 └─────────────────────┘

 ┌──────────────────────────────────────────────────────────────────────────┐
 │ New Case → Before-Save Flow → stamps Account_Revenue_Tier__c,            │
 │ Account_RAG_at_Creation__c, Account_CSM_Name__c, Is_Top_Customer__c     │
 │ → Queue_Config__mdt drives assignment                                    │
 └──────────────────────────────────────────────────────────────────────────┘
```

Two independent paths share the same tier model:

- **Call path:** IVR → Router → Salesforce phone lookup → tier → queue name
  → IVR transfers the call to the Salesforce-bound Exotel queue.
- **Case path:** Case insert → Before-Save Flow reads Account
  `Support_Tier__c` formula → stamps tier fields → standard Case
  assignment rules route to the tier queue.

The middleware is stateless apart from the in-process LRU cache, so it
scales horizontally behind any HTTP load balancer.

---

## 3. Component inventory

### Already built (this branch)

| Layer | Artifact | Path |
|-------|----------|------|
| Account formulas | `Support_Tier__c`, `Support_Tier_Badge__c` | `force-app/main/default/objects/Account/fields/` |
| Case fields (×6) | tier, RAG snapshot, CSM, LTM revenue, Top Customer flag, badge | `force-app/main/default/objects/Case/fields/` |
| Case Flow | `Case_RevenueTier_BeforeSave` Before-Save | spec in `02-case-flow-specification.md` |
| Queue config | `Queue_Config__mdt` + 4 records | `force-app/main/default/objects/Queue_Config__mdt/`, `force-app/main/default/customMetadata/` |
| Apex tests | 10 tests incl. 200-record bulk | `force-app/main/default/classes/Case_RevenueTier_FlowTest.cls` |
| Connected App | `ECC_Revenue_Router` (OAuth 2.0 CC) | `force-app/main/default/connectedApps/` |
| Permission Set | `ECC_Revenue_Router_Integration` (read-only) | `force-app/main/default/permissionsets/` |
| Middleware | Node/Express service, Dockerized | `middleware/` |
| UAT matrix | 53 test cases | `06-test-and-rollout.md` |

### Pending (PS or ops)

| Layer | Item | Owner |
|-------|------|-------|
| Telephony | IVR nodeflow HTTP action node + branch logic | PS |
| Telephony | 4 Exotel queue destinations bound to SF queues | PS + CX Ops |
| Agent desktop | Open CTI softphone manifest update (banner + pop) | PS |
| Salesforce | 4 SF Queues created with team membership | Support Leadership |
| Salesforce | Connected App Client Credentials Flow enabled + Run As user | Salesforce admin |
| Infra | Host middleware (container platform, DNS, TLS) | Internal SRE |

---

## 4. Deployment plan — phased

### Phase 0 — Pre-flight (before any deploy)

- [ ] Verify `Hypercare_active__c` picklist value is `Active` in the
      target sandbox. (Spec assumed value; one-line fix if different.)
- [ ] Run the phone-field audit SOQL from
      [01-field-definitions-and-phone-audit.md](01-field-definitions-and-phone-audit.md)
      and confirm ≥ 70 % phone-to-account match rate on last 30 days of
      calls. Below that, pause and clean up phone data first.
- [ ] Confirm the four target SF Queues exist (or create them) with the
      right agent membership.

### Phase 1 — Salesforce deploy (UAT sandbox)

- [ ] `sf project deploy start -d force-app/main/default` from
      `claude/upbeat-ride`.
- [ ] `sf apex test run -n Case_RevenueTier_FlowTest -w 10 -c` — expect
      10/10 pass, ≥ 75 % coverage on the Flow-adjacent code paths.
- [ ] Manually create 5 Cases (one per tier scenario) and confirm field
      stamping in the UI.

### Phase 2 — Middleware deploy (UAT)

- [ ] Open the deployed `ECC_Revenue_Router` Connected App → "Manage" →
      enable Client Credentials Flow → set Run-As user to the dedicated
      integration user with `ECC_Revenue_Router_Integration` assigned.
- [ ] Capture Consumer Key + Secret.
- [ ] `docker build -t ecc-revenue-router:uat middleware/`
- [ ] Deploy to UAT host, populate `.env` with Consumer Key/Secret +
      `ROUTER_SHARED_KEY`.
- [ ] `curl -H "X-Router-Key: …" https://<uat-host>/v1/context?phone=%2B91…`
      — expect 200 with tier populated for a known account.

### Phase 3 — IVR + CTI wiring (PS-led)

- [ ] PS adds the HTTP action node to the target IVR nodeflow (design in
      [03-ivr-nodeflow-design.md](03-ivr-nodeflow-design.md)).
- [ ] PS binds the four Exotel queue destinations to the SF queues.
- [ ] PS updates the Open CTI softphone manifest per
      [04-screen-pop-and-layouts.md](04-screen-pop-and-layouts.md).
- [ ] End-to-end smoke: dial into each tier's test number, confirm queue
      transfer + banner render.

### Phase 4 — UAT (1 week)

- [ ] Execute the 53-case UAT matrix in
      [06-test-and-rollout.md](06-test-and-rollout.md).
- [ ] Daily stand-up: review failed calls, false positives on
      hypercare, cache-staleness complaints.
- [ ] Sign-off: Support Leadership + CX Ops.

### Phase 5 — Production rollout (staged)

- [ ] Deploy Salesforce metadata via change set or SFDX to prod.
- [ ] Deploy middleware to prod cluster (2 replicas min).
- [ ] Flip IVR nodeflow to prod — **single hotline first**, monitor 24 h.
- [ ] Expand to all support hotlines in a rolling rollout.

---

## 5. Dependency matrix

| Blocks | Blocked by | Owner |
|--------|------------|-------|
| Phase 1 | Phase 0 pre-flight | Us |
| Phase 2 | Phase 1, Salesforce admin enabling Client Credentials Flow | Us + SF admin |
| Phase 3 | Phase 2, PS capability confirmation (auth scheme, latency, call_sid) | PS |
| Phase 4 | Phase 3 | Support + us |
| Phase 5 | Phase 4 sign-off | Us + PS |

---

## 6. Rollout & rollback

**Rollout guardrails**

- Start with **one hotline** in prod for 24 hours before expanding.
- Monitor: middleware p95 latency, Salesforce API error rate, cache hit
  rate, and first-response time per tier on new Cases.

**Rollback — IVR**

- Single flag in the IVR nodeflow: disable the HTTP action node's branch
  and fall back to the pre-existing default queue. Reversible in < 5 min.

**Rollback — Case Flow**

- Deactivate `Case_RevenueTier_BeforeSave` Flow in Setup. Existing Cases
  keep their stamped values; new Cases revert to default assignment.

**Rollback — middleware**

- Route the IVR back to the legacy path. The middleware is stateless;
  leaving it running or taking it down has zero Salesforce side-effects.

---

## 7. Success metrics (30-day review)

| Metric | Baseline | Target |
|--------|----------|--------|
| Time-to-agent for HYPERCARE / STRATEGIC calls | (current) | −40 % |
| First-response time on HYPERCARE Cases | (current) | < 15 min |
| % of Cases with correctly stamped tier | 0 % | > 99 % |
| Middleware uptime | N/A | > 99.9 % |
| Phone-to-account match rate | (from phone audit) | > 85 % |

---

## 8. Open capability questions for PS

Full list in [05-ps-engagement-brief.md](05-ps-engagement-brief.md). Top
three blockers for the UAT build:

1. **Auth scheme for the HTTP action node** — does Exotel support
   arbitrary header pass-through (`X-Router-Key`)? If not, what's the
   supported equivalent (token in query string, basic auth)?
2. **Call-transfer latency budget** — what's the acceptable upper bound
   for the HTTP action node's round-trip? We currently target < 300 ms
   p95; need confirmation the IVR can tolerate that without call quality
   issues.
3. **`call_sid` pass-through** — can the HTTP node include the call SID
   in the POST body so we can correlate router logs with Exotel CDRs?

---

## 9. Appendices (detailed docs)

- [README.md](README.md) — executive summary
- [01-field-definitions-and-phone-audit.md](01-field-definitions-and-phone-audit.md) — SF fields, phone audit, normalization
- [02-case-flow-specification.md](02-case-flow-specification.md) — Before-Save Flow
- [03-ivr-nodeflow-design.md](03-ivr-nodeflow-design.md) — IVR + middleware API
- [04-screen-pop-and-layouts.md](04-screen-pop-and-layouts.md) — CTI softphone + page layouts
- [05-ps-engagement-brief.md](05-ps-engagement-brief.md) — full 10 capability questions
- [06-test-and-rollout.md](06-test-and-rollout.md) — UAT matrix + runbook
- [middleware/README.md](../../middleware/README.md) — middleware ops manual
