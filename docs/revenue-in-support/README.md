# Revenue System Embedded in Support

**Initiative:** Make the support workflow revenue-aware by surfacing Salesforce Account revenue context into ECC (Exotel Contact Center) for every customer interaction — calls and tickets — across all customers.

**Status:** Design phase. Artifacts below are implementation-ready specs, not yet deployed.

**Date:** 2026-04-15

---

## Problem

Today, inbound support calls and tickets are routed by queue rules that are blind to commercial context:
- An agent handling a `Top_Customer__c = true` strategic account sees the same screen as an agent handling a low-ARR ticket
- High-revenue customers can sit in a generic FLR queue behind smaller accounts
- CSMs are not surfaced to agents at first contact
- Hypercare accounts (escalated commercial situations) get no routing priority

All the source data exists in Salesforce — `Top_Customer__c`, `RAG__c`, `Is_SAAS_Premium_Account__c`, `Hypercare_active__c`, `accounts_revenue__c.Revenue_Booked_Amount__c`. The gap is purely integration and configuration.

---

## Solution — Three Layers

```
                    ┌──────────────────────────────────┐
                    │   Salesforce (source of truth)   │
                    │  Account + accounts_revenue__c   │
                    └───────────────┬──────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
    ┌─────▼─────┐             ┌─────▼─────┐             ┌─────▼─────┐
    │ IVR HTTP  │             │  Case      │             │ Screen    │
    │  Callout  │             │  Flow      │             │  Pop      │
    │  (Calls)  │             │  (Tickets) │             │  (Agent)  │
    └─────┬─────┘             └─────┬─────┘             └─────┬─────┘
          │                         │                         │
          ▼                         ▼                         ▼
   Tier-based queue         Tier-based queue         Revenue context
   routing (voice)          assignment (tickets)     visible to agent
```

---

## Tier Model

| Tier | Rule | Treatment |
|---|---|---|
| **HYPERCARE** | `Hypercare_active__c = true` AND `Hypercare_End_Date__c >= TODAY` | Dedicated Hypercare queue, senior agent, 2hr response SLA |
| **STRATEGIC** | `Top_Customer__c = true` OR `Is_SAAS_Premium_Account__c = true` | Strategic Support Queue, L2+, 4hr SLA |
| **PREMIUM** | `SAAS_Enterprise_Account__c = true` AND `RAG__c IN ('GREEN','AMBER')` | Premium Support Queue, L2 priority |
| **STANDARD** | Everything else | Default L1 → L2 flow |

> Tier is stamped on the Account as `Support_Tier__c` (formula field) and on the Case as `Account_Revenue_Tier__c` (stamped via Flow at creation).

---

## Documents in This Package

| # | Document | Audience | Purpose |
|---|---|---|---|
| 01 | [Field Definitions & Phone Audit](./01-field-definitions-and-phone-audit.md) | SF Admin, Data team | New fields to create, data quality audit queries |
| 02 | [Case Flow Specification](./02-case-flow-specification.md) | SF Admin, SF Developer | Before-Save Flow detailed spec with XML skeleton |
| 03 | [IVR Nodeflow Design](./03-ivr-nodeflow-design.md) | ECC Admin, Exotel PS | HTTP callout + tier resolution + queue routing |
| 04 | [Screen Pop & Layouts](./04-screen-pop-and-layouts.md) | SF Admin, ECC Admin | CTI softphone layout + Compact layout + conditional formatting |
| 05 | [PS Engagement Brief](./05-ps-engagement-brief.md) | Exotel Professional Services | Formal brief to engage PS for IVR callout + queue config |
| 06 | [Test & Rollout](./06-test-and-rollout.md) | QA, Support Ops | UAT test plan + rollout runbook + operational SOQL |

---

## Quick Stats (Scope Sizing)

Based on Ameyo Care volumes (YTD 2026 from CLAUDE.md audit):
- **Normal Support tickets:** 4,988 (core Ameyo Care)
- **Platform Support tickets:** 19,257 (largest volume)
- **CognoAI tickets:** 963
- **Total in-scope support tickets/year:** ~26,000

At ~100 tickets/day across all in-scope record types — well within Salesforce governor limits for Before-Save Flow + subqueries.

Account-side:
- Revenue tier distribution (to be measured via operational SOQL in doc 06) will tell us queue capacity requirements

---

## Prerequisites & Dependencies

### Must Exist Before Rollout
1. **Phone number data quality** — Account.Phone and Contact.Phone must be populated and normalized for ANI → Account matching to work. *This is the single biggest risk.* See [01](./01-field-definitions-and-phone-audit.md).
2. **Salesforce Connected App** — OAuth 2.0 Client Credentials flow for IVR → SF authentication
3. **Revenue Tier field** — `Support_Tier__c` formula on Account
4. **New Case fields** — `Account_Revenue_Tier__c`, `Account_RAG_at_Creation__c`, `Account_CSM_Name__c`, `Is_Top_Customer__c`, `Account_LTM_Revenue__c` (optional)
5. **New ECC queues** — Hypercare, Strategic, Premium support queues with agent assignment

### External Dependencies (PS / Infra)
- Exotel PS for IVR nodeflow HTTP action configuration
- Infra team for queue capacity sizing (if new queues exceed current channel allocation)

---

## Known Gaps & Open Questions

| Gap | Impact | Plan |
|---|---|---|
| Phone number data quality is unknown | Blocks call-channel tier lookup | Run audit queries in [01](./01-field-definitions-and-phone-audit.md), remediate before IVR config |
| Revenue tier thresholds not agreed | Tier assignment may not match business intent | Run tier distribution analysis in [06](./06-test-and-rollout.md), validate with Sales + CS leadership |
| Hypercare flag drift | Active flag may not align with end date — 2 fields, one source of truth | Nightly cleanup job OR treat end date as source of truth (see [02](./02-case-flow-specification.md)) |
| Multi-tenant accounts (Setup_Account, Parent_Account on Case) | A ticket may reference a child account with different tier than parent | Decide: use Account on Case, or walk up to Universal Account? See [02](./02-case-flow-specification.md) |
| Ticket created via email vs call | Email ticket has no ANI — tier from Account lookup via sender email domain | Flow handles this via Case.AccountId (already resolved by existing rules) |

---

## Success Metrics

To track post-rollout (target: +30 days, +90 days):

| Metric | Baseline Source | Target |
|---|---|---|
| Strategic account avg response time | Case.First_Response_Time__c WHERE Account_Revenue_Tier__c = 'STRATEGIC' | Reduce by 50% vs pre-rollout |
| Strategic account FCR (First Call Resolution) | Case + Survey__c | Improve by 15% |
| Strategic/Premium tickets mis-routed to L1 | Case.Queue__c transitions | < 5% |
| CSAT for Strategic accounts | Survey__c.Overall_Experience__c | +0.5 points |
| % calls with successful tier lookup | IVR log analysis | > 90% |

---

## Build Order

```
Week 1   → Phone audit + remediation + Support_Tier__c formula on Account
Week 2   → New Case fields + Before-Save Flow (sandbox)
Week 2   → Compact layout + Tier_Badge__c formula (quick visible win)
Week 3   → Salesforce Connected App + IVR callout node (PS engagement kicks off)
Week 4   → IVR nodeflow update + new queue config in ECC
Week 4   → CTI softphone layout config
Week 5   → UAT with L1/L2 agents across all tier scenarios
Week 6   → Production rollout (staged: tickets first, then calls)
```

Staging tickets-first is deliberate: the Case Flow has zero ECC/IVR dependencies and delivers immediate agent-visible value. The call-channel leg requires PS engagement and phone data cleanup.

---

## Owners

| Area | Owner |
|---|---|
| Salesforce schema + Flow | SF Admin + SF Dev |
| ECC queue config + IVR nodeflow | ECC Admin + Exotel PS |
| Phone data cleanup | Data team + Support Ops |
| Tier threshold definition | Sales Ops + Customer Success leadership |
| Agent training + UAT | Support Ops + L1/L2/L3 leads |
| Success metrics tracking | Support Analytics |

---

## References

- Exotel Contact Center docs: https://docs.exotel.com/contact-center
- Harmony (6x) docs: https://docs.exotel.com/harmony
- ECC SPOF Audit Dashboard: https://docs.google.com/spreadsheets/d/1MJicBR0YRGQ9vXIWnq1HH7r-VaRDPZ1jPezu9dQcNMQ/edit
- Salesforce Org: ameyo.my.salesforce.com
- Source CLAUDE.md field audit: `/Users/shivanand/Desktop/ai-sales-assistant/upbeat-ride/CLAUDE.md`
