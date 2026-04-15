# 05 — Exotel Professional Services Engagement Brief

**To:** Exotel ECC Professional Services (PS) Team
**From:** Support Ops + Sales Engineering (internal Exotel initiative)
**Date:** 2026-04-15
**Priority:** P2 (target kickoff within 4 weeks)

---

## 1. Request Summary

We want to **embed Salesforce Account revenue context into the ECC support workflow** so that:
- Inbound support calls are routed to tier-appropriate queues based on live Salesforce lookup of the caller's Account tier (HYPERCARE / STRATEGIC / PREMIUM / STANDARD)
- Support agents see revenue context (tier, CSM name, RAG, last 12M revenue) in the CTI softphone during the call and on the Case record after pickup
- Hypercare and Strategic accounts get priority treatment in queue routing

This is an internal Exotel initiative for our own Ameyo Care support team. It will also serve as a reference architecture for customers asking the same question.

---

## 2. What We Need from PS

### 2.1 — Capability Confirmation (Documentation Review)

Please confirm, citing docs.exotel.com, which of the following are supported on our deployment (4x and/or 6x):

| # | Capability | 4x? | 6x? | Doc Reference |
|---|---|---|---|---|
| Q1 | **HTTP GET action node** in IVR nodeflow that calls external URL | ? | ? | |
| Q2 | Timeout + fallback branch on HTTP action (e.g., 2-second timeout → default branch) | ? | ? | |
| Q3 | Parse JSON response and extract fields into IVR variables | ? | ? | |
| Q4 | Variable-based branching (if/else decision nodes) | ? | ? | |
| Q5 | Pass variables as call context payload to agent CTI softphone | ? | ? | |
| Q6 | Max payload size / field count for call context | ? | ? | |
| Q7 | Queue overflow rules (if tier queue empty → fall to next queue) | ? | ? | |
| Q8 | Static bearer token auth on HTTP action headers | ? | ? | |
| Q9 | OAuth 2.0 client credentials flow support in IVR | ? | ? | |
| Q10 | Versioning and rollback of nodeflow changes | ? | ? | |

### 2.2 — Implementation Scope

If capabilities Q1–Q7 are confirmed, please scope the following PS tasks:

1. **New IVR nodeflow** for the inbound support DID(s) including:
   - HTTP action node → middleware endpoint
   - Response parsing into variables
   - 5-way branch on `support_tier` variable
   - Queue assignment per tier
   - Overflow rules per tier

2. **New Queues in ECC**:
   - `Hypercare Support Queue`
   - `Strategic Support Queue`
   - `Premium Support Queue`
   - (FLR and existing queues stay for STANDARD and UNKNOWN)

3. **Queue agent assignment**:
   - Senior agents → Hypercare + Strategic
   - Experienced L2 → Premium
   - Existing assignment for Standard

4. **CTI softphone layout update** to display tier badge, account name, RAG, CSM name from call context payload during ringing / active call.

5. **Testing support** for our UAT scenarios (see [06](./06-test-and-rollout.md)).

### 2.3 — Questions on Platform Limits

- Our current inbound support call volume: [TO FILL IN — Support Ops to confirm]
- Peak BHCA on inbound support DID: [TO FILL IN]
- Concurrent agents handling support: [TO FILL IN from roster]
- Do we need channel allocation review for the new tier queues? Or do they share the existing support pool?

---

## 3. What We Are Building (No PS Help Needed)

For context, here's what's being built in parallel by the Salesforce + Data teams:

| Component | Owner | Status |
|---|---|---|
| Salesforce Account.Support_Tier__c formula field | SF Admin | Week 1 |
| Salesforce Connected App for middleware auth | SF Admin + Security | Week 1–2 |
| Middleware service (Node.js) exposing `/api/v1/account-tier?phone=` | Internal engineering | Week 2–3 |
| Salesforce Case Before-Save Flow (stamps tier on tickets) | SF Admin | Week 2 |
| Case compact layout, page layout, conditional banners | SF Admin | Week 2 |
| Phone number data quality audit + cleanup | Data team | Week 1–2 |

The middleware exposes a simple REST endpoint. PS involvement is only for the ECC-side IVR nodeflow + queue + softphone layout changes.

---

## 4. Proposed Integration — Sequence Diagram

```
Caller           Exotel IVR          Middleware          Salesforce
  │                   │                   │                   │
  │───call──────────▶ │                   │                   │
  │                   │─capture ANI       │                   │
  │                   │─HTTP GET ──────▶  │                   │
  │                   │  ?phone=+9198...  │                   │
  │                   │                   │─check cache       │
  │                   │                   │   (hit → skip SF) │
  │                   │                   │─query Account ──▶ │
  │                   │                   │                   │─return
  │                   │                   │◀────────────────── │
  │                   │                   │─store in cache    │
  │                   │◀─────200 OK────── │                   │
  │                   │  {tier: "STRATEGIC",...}              │
  │                   │─branch on tier                        │
  │                   │─play Strategic IVR prompt             │
  │                   │─queue: Strategic Support              │
  │◀──hold music──── │                   │                   │
  │                   │─agent selected                        │
  │                   │─pass call context ──▶ Agent CTI       │
  │◀──talk────────▶ Agent                                     │
```

---

## 5. Reference Architecture Diagram

```
┌────────────────┐      ┌──────────────┐     ┌───────────────────┐
│   Caller       │─────▶│   Exotel     │    │  Middleware       │
│   (PSTN/SIP)   │      │   Platform   │───▶│  (AWS Lambda)     │
└────────────────┘      │   + IVR      │    │  /account-tier    │
                        └──────┬───────┘    └─────────┬─────────┘
                               │                      │
                               │                      ▼
                         ┌─────▼─────┐         ┌────────────────┐
                         │   Agent   │         │   Salesforce    │
                         │   CTI     │◀────────│  Account, Case  │
                         │           │ screen  │  + Connected    │
                         │           │  pop    │   App           │
                         └───────────┘         └────────────────┘
```

---

## 6. Middleware API Contract (for PS reference)

PS doesn't build this — but needs to know the contract for configuring the HTTP action node.

```
GET https://support-router.internal.exotel.com/api/v1/account-tier?phone={{normalized_phone}}

Headers:
  Authorization: Bearer <shared-secret>
  X-Request-Id:  {{call_sid}}
  Accept:        application/json

Timeout: 2s

Response (200 OK, matched):
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
  "lookup_source": "cache"
}

Response (200 OK, no match):
{
  "matched": false,
  "phone_queried": "+919876543210"
}

Response (5xx or timeout):
  IVR treats this as tier=STANDARD and continues routing.
```

Full spec: [03 — IVR Nodeflow Design](./03-ivr-nodeflow-design.md).

---

## 7. Testing Scope PS Should Cover

Before UAT, PS should validate the nodeflow handles:

| # | Test | Expected |
|---|---|---|
| PS-T1 | Caller number matches Strategic Account | Routed to Strategic Queue |
| PS-T2 | Caller number matches Hypercare Account | Routed to Hypercare Queue |
| PS-T3 | Caller number has no match in Salesforce | Routed to UNKNOWN / Helpdesk |
| PS-T4 | Middleware times out (inject 3s delay) | Routed to STANDARD; no call drop |
| PS-T5 | Middleware returns 500 error | Routed to STANDARD; no call drop |
| PS-T6 | Middleware returns malformed JSON | Routed to STANDARD; IVR logs error |
| PS-T7 | Strategic queue has no available agents | Overflow to next tier queue per config |
| PS-T8 | Call context payload arrives at agent CTI | Tier + Account Name + CSM visible in softphone |

We will provide test phone numbers and configure a test middleware endpoint for PS to call during build.

---

## 8. Timeline

| Week | PS Activity |
|---|---|
| Week 0 | **Kickoff call** — walk through this brief, confirm capabilities, agree scope |
| Week 1 | PS provides written capability confirmation (Q1–Q10) + scope estimate |
| Week 2 | SF Connected App + middleware ready; we share test endpoint URL with PS |
| Week 3 | PS builds nodeflow + queues in ECC sandbox/staging |
| Week 4 | PS executes PS-T1 through PS-T8 in sandbox; we join UAT |
| Week 5 | Internal UAT (our Support Ops team) on sandbox |
| Week 6 | Production rollout (staged — starts with 10% of inbound calls via A/B DID routing) |

---

## 9. Rollback Plan

PS to confirm how to execute each rollback:

| Scenario | Rollback Action | Executable in |
|---|---|---|
| Middleware down | Disable HTTP action node → fallback to current routing | < 5 min |
| Wrong tier routing detected | Revert nodeflow to previous published version | < 10 min |
| Queue overflow causing agent overload | Adjust queue capacity / fall-through rules | < 15 min |
| Complete initiative rollback | Remove HTTP action node entirely, restore original routing | < 30 min |

---

## 10. Success Criteria

PS work is considered done when:

- [ ] Written confirmation of Q1–Q10 capability questions received from PS
- [ ] Sandbox nodeflow passes all PS-T1 through PS-T8 tests
- [ ] CTI softphone displays tier, account name, CSM in ringing state for matched calls
- [ ] Rollback plan documented and tested
- [ ] PS provides a runbook for ops team to make minor config changes (queue membership, overflow rules) without re-engaging PS

---

## 11. Open Commercial Question

Is this work covered under our existing ECC support contract, or does it require a separate SOW?

If SOW — please provide scope + effort estimate per week 1.

---

## 12. Contacts

| Role | Name | Email |
|---|---|---|
| Project Sponsor | [TBD — Head of Support Ops] | |
| Technical Owner (SF side) | [TBD — SF Admin Lead] | |
| Technical Owner (ECC side) | [TBD — ECC Admin] | |
| Middleware Owner | [TBD — Platform Eng] | |
| PS Engagement Lead | [To be assigned by PS] | |

---

## 13. Attachments / References

Full design package:
- [README.md](./README.md) — Initiative overview
- [01 — Field Definitions & Phone Audit](./01-field-definitions-and-phone-audit.md)
- [02 — Case Flow Specification](./02-case-flow-specification.md)
- [03 — IVR Nodeflow Design](./03-ivr-nodeflow-design.md) ← this is the doc PS cares about most
- [04 — Screen Pop & Layouts](./04-screen-pop-and-layouts.md)
- [06 — Test & Rollout](./06-test-and-rollout.md)

**Please reply with:**
1. Capability confirmations (Q1–Q10)
2. Scope estimate + timeline
3. Any constraints or concerns we haven't addressed
4. Commercial treatment (existing contract / new SOW)
