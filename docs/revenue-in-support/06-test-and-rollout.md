# 06 — Test Plan, Rollout Runbook & Operational SOQL

**Audience:** QA, Support Ops, SF Admin, ECC Admin
**Purpose:** Validate the solution end-to-end and operate it post-launch.

---

# Part A — UAT Test Plan

## A.1 — Test Environment Requirements

| Requirement | Value |
|---|---|
| Salesforce Sandbox | Full-copy sandbox with recent refresh (last 30 days) |
| Test Accounts | At least 1 per tier: Hypercare, Strategic, Premium, Standard |
| Test Phone Numbers | Routed to IVR test DID; phones registered to test Accounts |
| ECC Environment | Sandbox/staging with nodeflow deployed |
| Middleware | Test instance pointing to SF sandbox |
| Test Agents | 2+ agents logged in to each tier queue |
| Test Tools | SoftPhone, Salesforce Developer Console, Postman (for middleware) |

## A.2 — Test Data Setup

### Before UAT Starts

Run this setup script in the sandbox to create canonical test accounts:

```apex
// UAT test data setup — run in Developer Console (Execute Anonymous)

// Create test CSM user first (if not exists)
User csm = [SELECT Id FROM User WHERE Email = 'uat-csm@exotel.com' LIMIT 1];
// if not found, create per user setup conventions

List<Account> testAccounts = new List<Account>{
    new Account(
        Name = 'UAT Hypercare Active',
        Phone = '+919000000001',
        Hypercare_active__c = 'Active',
        Hypercare_End_Date__c = DateTime.now().addDays(30),
        Account_CSM__c = csm.Id,
        RAG__c = 'RED'
    ),
    new Account(
        Name = 'UAT Hypercare Expired',
        Phone = '+919000000002',
        Hypercare_active__c = 'Active',
        Hypercare_End_Date__c = DateTime.now().addDays(-5),
        Account_CSM__c = csm.Id,
        RAG__c = 'AMBER'
    ),
    new Account(
        Name = 'UAT Strategic Top',
        Phone = '+919000000003',
        Top_Customer__c = true,
        Account_CSM__c = csm.Id,
        RAG__c = 'GREEN'
    ),
    new Account(
        Name = 'UAT Strategic SAAS Premium',
        Phone = '+919000000004',
        Is_SAAS_Premium_Account__c = true,
        Account_CSM__c = csm.Id,
        RAG__c = 'AMBER'
    ),
    new Account(
        Name = 'UAT Premium',
        Phone = '+919000000005',
        SAAS_Enterprise_Account__c = true,
        Account_CSM__c = csm.Id,
        RAG__c = 'GREEN'
    ),
    new Account(
        Name = 'UAT Premium RED (should fall to Standard)',
        Phone = '+919000000006',
        SAAS_Enterprise_Account__c = true,
        Account_CSM__c = csm.Id,
        RAG__c = 'RED'
    ),
    new Account(
        Name = 'UAT Standard',
        Phone = '+919000000007',
        Account_CSM__c = csm.Id
    )
};
insert testAccounts;
System.debug('Inserted ' + testAccounts.size() + ' UAT accounts');
```

## A.3 — UAT Test Matrix

### A.3.1 — Salesforce Flow Tests (Ticket Channel)

| # | Scenario | Setup | Action | Expected |
|---|---|---|---|---|
| UAT-01 | Hypercare active tier stamping | Hypercare Active account | Create Case manually with AccountId set | `Account_Revenue_Tier__c = HYPERCARE`, Priority = Critical, OwnerId = Hypercare Queue, CSM name stamped |
| UAT-02 | Hypercare expired falls back | Hypercare Expired account | Create Case | Tier = STANDARD or whatever base tier applies — NOT HYPERCARE |
| UAT-03 | Top Customer → Strategic | Strategic Top account | Create Case | Tier = STRATEGIC, OwnerId = Strategic Queue |
| UAT-04 | SAAS Premium → Strategic | Strategic SAAS Premium account | Create Case | Tier = STRATEGIC |
| UAT-05 | SAAS Enterprise + GREEN → Premium | Premium account | Create Case | Tier = PREMIUM, OwnerId unchanged (assignment rules take over) |
| UAT-06 | SAAS Enterprise + RED → STANDARD | Premium RED account | Create Case | Tier = STANDARD (RED excluded from Premium criteria) |
| UAT-07 | Regular account → Standard | Standard account | Create Case | Tier = STANDARD |
| UAT-08 | Case without Account | No AccountId | Create Case | Tier = UNKNOWN, no queue change |
| UAT-09 | Priority override | Hypercare + Priority=Minor | Create Case with Priority=Minor | Priority upgraded to Critical |
| UAT-10 | Priority preservation | Strategic + Priority=Critical | Create Case | Priority stays Critical |
| UAT-11 | Email-to-Case | Send email to case@ameyo.com from test address | Case auto-created | Tier stamped correctly via Account resolution |
| UAT-12 | Bulk insert 200 cases | Apex bulk insert | Execute | All 200 cases have tier stamped, no governor limit errors |

### A.3.2 — IVR Call Tests (Call Channel)

| # | Scenario | Setup | Action | Expected |
|---|---|---|---|---|
| UAT-20 | Strategic inbound call | Phone = +919000000003 | Call DID from test phone | Routed to Strategic Queue; softphone shows STRATEGIC tier + CSM |
| UAT-21 | Hypercare inbound call | +919000000001 | Call DID | Hypercare Queue; softphone shows HYPERCARE |
| UAT-22 | Hypercare expired inbound call | +919000000002 | Call DID | NOT Hypercare; base tier queue |
| UAT-23 | Premium inbound call | +919000000005 | Call DID | Premium Queue; softphone shows PREMIUM |
| UAT-24 | Standard inbound call | +919000000007 | Call DID | FLR Queue; softphone shows STANDARD |
| UAT-25 | Unknown inbound call | Phone not in SF | Call DID | Unknown/Helpdesk Queue; softphone has no tier info |
| UAT-26 | Private CLI | Block caller ID | Call DID | Unknown Queue |
| UAT-27 | Middleware timeout | Inject 3s delay in middleware | Call DID | Standard Queue; call completes without drop |
| UAT-28 | Middleware 500 error | Toggle middleware to error mode | Call DID | Standard Queue; call completes |
| UAT-29 | Salesforce down | Stop SF responding | Call DID | Middleware returns cached result if available; else Standard Queue |
| UAT-30 | Agent screen pop matches call | Strategic call answered | Agent picks up | Softphone context retained; Case pre-fills with AccountId + Priority=Major |
| UAT-31 | Concurrent calls (stress) | 5 calls in 10 seconds | Various tier phones | All routed correctly; no middleware errors |

### A.3.3 — Agent Experience Tests (Layout & Screen Pop)

| # | Scenario | Setup | Action | Expected |
|---|---|---|---|---|
| UAT-40 | Hypercare banner visible | Hypercare Case | Agent opens Case | Red Hypercare banner visible at top |
| UAT-41 | Strategic banner visible | Strategic Case | Agent opens Case | Yellow Strategic banner visible |
| UAT-42 | Compact layout shows tier | Any Case | Agent opens Case | Tier badge visible in highlights |
| UAT-43 | CSM name in highlights | Strategic Case with CSM | Agent opens Case | CSM name visible without needing to click Account |
| UAT-44 | Quick action: Notify CSM | Strategic Case | Agent clicks Notify CSM | Chatter post created mentioning CSM |
| UAT-45 | Quick action: Escalate to L3 | Strategic Case | Agent clicks Escalate | OwnerId = L3 Escalation Queue, Escalation_Level__c = 1 |
| UAT-46 | "My Hypercare Tickets" list view | Agent owns 2 Hypercare cases | Open list view | Both cases visible |
| UAT-47 | Emoji rendering | Any Case with tier | View in Chrome, Safari, Firefox | Emoji renders in all browsers |
| UAT-48 | Dashboard — Tier Distribution | Navigate to Support Dashboard | View widget | Shows counts per tier |

### A.3.4 — Rollback Tests

| # | Scenario | Action | Expected |
|---|---|---|---|
| UAT-50 | Deactivate Case Flow | Turn off Case_RevenueTier_BeforeSave in Setup | New Cases have no tier stamp; existing Cases unaffected |
| UAT-51 | Disable middleware | Stop middleware service | Calls still route; middleware-dependent tier routing falls to STANDARD |
| UAT-52 | Revert IVR nodeflow | Rollback to previous version | Calls route per old logic |
| UAT-53 | Revert everything | All three rollbacks | System returns to pre-launch state within 30 min |

---

## A.4 — Sign-off Criteria

UAT is signed off when:
- [ ] All UAT-01 through UAT-12 pass (Salesforce Flow — ticket channel)
- [ ] All UAT-20 through UAT-31 pass (IVR — call channel)
- [ ] All UAT-40 through UAT-48 pass (agent UX)
- [ ] All UAT-50 through UAT-53 pass (rollback)
- [ ] 5+ agents have done at least 2 test calls each and reported no issues
- [ ] Support Ops team lead signs off

---

---

# Part B — Rollout Runbook

## B.1 — Pre-Launch Checklist

### Salesforce Side (T-1 week)

- [ ] All fields from [01](./01-field-definitions-and-phone-audit.md) deployed to production
- [ ] `Support_Tier__c` formula returns expected values on spot-checked accounts (run §C.1 below)
- [ ] `Case_RevenueTier_BeforeSave` Flow active in production
- [ ] Apex test class `Case_RevenueTier_FlowTest` at > 90% coverage
- [ ] Queue_Config__mdt records deployed
- [ ] 4 Salesforce Queues created with agent membership
- [ ] Compact layout assigned to support profiles
- [ ] Conditional banners deployed on Case Lightning Record Page
- [ ] Case assignment rules updated to skip HYPERCARE/STRATEGIC
- [ ] Phone number audit complete; Strategic+Hypercare at 100% phone coverage
- [ ] Phone normalization batch completed

### ECC Side (T-1 week)

- [ ] Exotel PS has delivered validated nodeflow in staging
- [ ] 4 new queues created in ECC with agent assignment
- [ ] CTI softphone layout updated
- [ ] Middleware deployed to production with monitoring
- [ ] Middleware → Salesforce connectivity verified
- [ ] Rollback plan tested in staging

### Training (T-3 days)

- [ ] Agent one-pager published in Chatter Support group
- [ ] All-hands training: 30-min session with screen share
- [ ] L1, L2, L3 leads briefed
- [ ] CSM team briefed on what agents will now see

## B.2 — Launch Day Sequence

### Option A — Big Bang (simple, higher risk)

Monday 9 AM:
1. Activate Flow (T+0)
2. Enable middleware (T+5 min)
3. Deploy IVR nodeflow change (T+15 min)
4. Update CTI softphone layout (T+30 min)
5. Monitor dashboards for 2 hours (T+30 min to T+2:30)
6. All-clear notification to ops team (T+3 hours)

### Option B — Staged Rollout (recommended)

**Day 1 — Tickets only (no IVR changes)**
- Activate Salesforce Flow
- Deploy compact layout + banners + quick actions
- Agents see tier on all new tickets; no call routing change
- Monitor for 3 days
- If stable, proceed to Day 4

**Day 4 — Add IVR routing for 10% of DIDs (A/B test)**
- Route specific test DIDs through new nodeflow
- Monitor tier lookup success rate, queue performance, agent feedback
- Tune thresholds / queue sizes if needed
- Run for 1 week

**Day 11 — Full IVR rollout**
- Switch all inbound support DIDs to new nodeflow
- Monitor daily for 2 weeks
- Retrospective after 30 days

## B.3 — Monitoring During Launch

For the first 48 hours post-launch, monitor in real-time:

### Salesforce
- Cases created per hour vs baseline
- Case tier distribution (should match historical Account tier distribution)
- Flow errors / debug logs (Setup → Flows → Paused and Waiting Interviews)
- Apex CPU time trending

### Middleware
- Request rate
- Cache hit rate
- Error rate (> 1% → investigate)
- p99 latency (< 500ms → healthy)

### ECC
- Queue wait times per tier
- Abandonment rate per tier
- Agent utilization per queue

### Agent Experience
- Slack/Chatter channel for agent feedback
- Watch for: "I can't see tier", "wrong customer info", "banner showing for wrong tier"

## B.4 — Rollback Triggers

Halt rollout and rollback if:
- Case creation success rate drops > 2% vs baseline
- Tier lookup error rate > 5% for > 30 min
- Agent reports of wrong tier > 3 in first hour
- Middleware p99 latency > 2 seconds sustained
- SF API daily quota consumption > 90%

Rollback procedure — see [03 §9](./03-ivr-nodeflow-design.md#9-rollback-plan) and [02 §5](./02-case-flow-specification.md#5-error-handling--fault-paths).

## B.5 — Communication Plan

| When | Audience | Message |
|---|---|---|
| T-7 days | Support + CSM teams | "Revenue-aware support launches in 1 week — training session Tuesday" |
| T-1 day | All-hands Chatter | Reminder + link to agent one-pager |
| T+0 | #support-ops Slack | "Launch started — monitoring underway" |
| T+3 hours | All-hands | Status update |
| T+48 hours | All-hands | 48-hr retrospective |
| T+30 days | Leadership | 30-day impact report with metrics |

---

---

# Part C — Operational SOQL Queries

Ongoing monitoring queries the Support Ops and Analytics teams should run periodically.

## C.1 — Tier Distribution (Post-Formula Deployment)

Run AFTER deploying `Support_Tier__c` to validate the formula returns sensible values.

```sql
SELECT Support_Tier__c, COUNT(Id) AccountCount
FROM Account
WHERE IsDeleted = FALSE
GROUP BY Support_Tier__c
ORDER BY COUNT(Id) DESC
```

**Expected output shape:**
```
STANDARD      — ~90% of accounts
PREMIUM       — 5–8%
STRATEGIC     — 2–5%
HYPERCARE     — < 1%
```

If any tier is over/under-represented, revisit threshold logic with Sales Ops + CS leadership.

---

## C.2 — Tier Distribution (Open Tickets, Last 30 Days)

```sql
SELECT Account_Revenue_Tier__c, COUNT(Id) CaseCount
FROM Case
WHERE CreatedDate = LAST_N_DAYS:30
  AND IsDeleted = FALSE
  AND RecordType.DeveloperName IN (
    'Normal_Support','Change_Management','RCA','Release_Upgrade',
    'Philippines_Support','Platform_Support','CognoAI'
  )
GROUP BY Account_Revenue_Tier__c
ORDER BY COUNT(Id) DESC
```

---

## C.3 — Tickets by Tier × Record Type (Stacked View)

```sql
SELECT Account_Revenue_Tier__c, RecordType.Name, COUNT(Id) CaseCount
FROM Case
WHERE CreatedDate = LAST_N_DAYS:30
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c, RecordType.Name
ORDER BY RecordType.Name, COUNT(Id) DESC
```

---

## C.4 — Average First Response Time by Tier

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) Cases,
       AVG(First_Response_Time__c) AvgFRT_min
FROM Case
WHERE ClosedDate = LAST_N_DAYS:30
  AND First_Response_Time__c != NULL
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
ORDER BY Account_Revenue_Tier__c
```

**Benchmark (post-launch target):** Hypercare < 120 min, Strategic < 240 min, Premium < 240 min, Standard < 480 min

---

## C.5 — Average Resolution Time by Tier

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) Cases,
       AVG(Resolution_Time_Minutes__c) AvgRes_min
FROM Case
WHERE ClosedDate = LAST_N_DAYS:30
  AND Resolution_Time_Minutes__c != NULL
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
ORDER BY Account_Revenue_Tier__c
```

---

## C.6 — SLA Compliance by Tier

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) TotalCases,
       SUM(CASE WHEN SLA_Violated__c = FALSE THEN 1 ELSE 0 END) SLAMet,
       SUM(CASE WHEN SLA_Violated__c = TRUE  THEN 1 ELSE 0 END) SLAViolated
FROM Case
WHERE ClosedDate = LAST_N_DAYS:30
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
```

Note: The `SUM(CASE WHEN...)` pattern works in Tableau/BigQuery but SOQL doesn't support it directly. Use two separate queries or compute in Salesforce Reports.

**SOQL-compliant alternative:**

```sql
-- Query 1: SLA met
SELECT Account_Revenue_Tier__c, COUNT(Id) SLAMet
FROM Case
WHERE ClosedDate = LAST_N_DAYS:30 AND SLA_Violated__c = FALSE
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c

-- Query 2: SLA violated
SELECT Account_Revenue_Tier__c, COUNT(Id) SLAViolated
FROM Case
WHERE ClosedDate = LAST_N_DAYS:30 AND SLA_Violated__c = TRUE
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
```

---

## C.7 — Hypercare/Strategic Accounts With Open Tickets

```sql
SELECT Account.Name, Account.Support_Tier__c,
       COUNT(Id) OpenCases,
       MIN(CreatedDate) OldestCreated
FROM Case
WHERE Account.Support_Tier__c IN ('HYPERCARE','STRATEGIC')
  AND Status NOT IN ('Close_successful','Close_unsuccessful','Closed')
  AND IsDeleted = FALSE
GROUP BY Account.Name, Account.Support_Tier__c
ORDER BY COUNT(Id) DESC
```

Supervisor daily review.

---

## C.8 — Tier Mismatches (Creation vs Current)

Detect Cases where tier at creation no longer matches Account's current tier (Account was upgraded/downgraded mid-case).

```sql
SELECT Id, CaseNumber,
       Account_Revenue_Tier__c   CaseTier,
       Account.Support_Tier__c   CurrentTier,
       Account.Name,
       CreatedDate
FROM Case
WHERE Status NOT IN ('Close_successful','Close_unsuccessful','Closed')
  AND Account_Revenue_Tier__c != NULL
  AND Account.Support_Tier__c != NULL
  AND Account_Revenue_Tier__c != Account.Support_Tier__c
  AND IsDeleted = FALSE
ORDER BY CreatedDate DESC
LIMIT 100
```

**Supervisor action:** review weekly — if downgrade, confirm SLA treatment; if upgrade to Hypercare, reassign.

---

## C.9 — Tier-Aware Aging Buckets

Tickets open too long, especially in high tiers.

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) TotalOpen,
       SUM(CASE WHEN Age_in_min__c > 720  THEN 1 ELSE 0 END) Over_12hr,
       SUM(CASE WHEN Age_in_min__c > 1440 THEN 1 ELSE 0 END) Over_24hr,
       SUM(CASE WHEN Age_in_min__c > 4320 THEN 1 ELSE 0 END) Over_3d
FROM Case
WHERE Status NOT IN ('Close_successful','Close_unsuccessful','Closed')
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
```

Same note on SUM CASE WHEN — split into separate queries or use Reports.

---

## C.10 — CSM Coverage on Strategic+ Tickets

Are CSMs actually named on the high-tier tickets? (CSM lookup field blank = data gap.)

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) Total,
       COUNT(Account_CSM_Name__c) WithCSM
FROM Case
WHERE Account_Revenue_Tier__c IN ('HYPERCARE','STRATEGIC','PREMIUM')
  AND CreatedDate = LAST_N_DAYS:30
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
```

**Expected:** `WithCSM / Total` close to 100% — if < 90%, investigate Account.Account_CSM__c coverage.

---

## C.11 — Revenue Weighted Open Ticket Backlog

How much ARR is currently waiting on an open ticket?

```sql
SELECT Account_Revenue_Tier__c,
       COUNT(Id) OpenTickets,
       SUM(Account_LTM_Revenue__c) BacklogLTMRevenue
FROM Case
WHERE Status NOT IN ('Close_successful','Close_unsuccessful','Closed')
  AND Account_LTM_Revenue__c != NULL
  AND IsDeleted = FALSE
GROUP BY Account_Revenue_Tier__c
```

Powerful metric: "₹12 Cr of revenue is currently waiting on 47 open Strategic tickets."

---

## C.12 — Flow Execution Health (Are Tickets Getting Stamped?)

```sql
SELECT RecordType.Name, COUNT(Id) Total, COUNT(Account_Revenue_Tier__c) Stamped
FROM Case
WHERE CreatedDate = LAST_N_DAYS:7
  AND IsDeleted = FALSE
GROUP BY RecordType.Name
ORDER BY COUNT(Id) DESC
```

If Stamped < Total for in-scope record types → Flow misconfig / Accounts have blank Support_Tier__c.

---

# Part D — Post-Launch Metrics & Success Criteria

Track these at T+30 days and T+90 days vs pre-launch baseline.

| Metric | Query | Baseline (pre) | Target (post) |
|---|---|---|---|
| Avg FRT — Strategic tickets | C.4 filtered | Current value | Reduce 50% |
| Avg Resolution — Strategic | C.5 filtered | Current value | Reduce 30% |
| Strategic SLA compliance | C.6 filtered | Current value | > 95% |
| % Strategic tickets mis-routed to L1 | Custom query on Case.Queue__c transitions | N/A | < 5% |
| % Calls with successful tier lookup | Middleware logs | N/A | > 90% |
| Agent satisfaction with new UX | Survey | N/A | > 8/10 |
| CSM engagement on Strategic tickets | C.10 filtered | Current value | > 95% |

---

# Part E — Retrospective Template (T+30 days)

Sections to cover in the T+30 day retrospective:

1. **What worked**
2. **What didn't**
3. **Agent feedback themes**
4. **Data quality issues uncovered**
5. **Metric changes vs baseline**
6. **Tech debt created**
7. **Decisions needed for v2**

Proposed v2 candidates:
- Extend tier logic to include `Revenue_Booked_Amount__c` thresholds (currently not used — tier is purely flag-based)
- Proactive CSM email on Hypercare ticket creation
- Self-service tier override in Case (supervisor action)
- Dashboard push to Slack when Strategic+ ticket unassigned > 30 min
- Extend to outbound calls (agent dials customer — show tier context)
- Feed tier into voice agent (VoiceBot greeting customized by tier)
