# 04 — Screen Pop, CTI Softphone, and Layouts

**Audience:** SF Admin, ECC Admin
**Purpose:** Make revenue tier, CSM, and account context visible to support agents in real time — during calls and while handling tickets.
**Prerequisites:** Fields from [01](./01-field-definitions-and-phone-audit.md) deployed; Flow from [02](./02-case-flow-specification.md) active.

---

## 1. Three Places Where Tier Needs to Be Visible

| Touchpoint | Where | Fires When |
|---|---|---|
| **CTI Softphone** | Top-right corner of Salesforce Console, during active call | Call rings agent (from IVR call context payload) |
| **Case Screen Pop** | Case record page opens when call is answered or Case created | Call answered → Case auto-created, OR inbound email-to-case |
| **Case Highlights Panel** | Always visible on Case page, not just at pop | Agent opens any Case manually |

All three are configured in Salesforce. Nothing to do in ECC beyond passing call context.

---

## 2. Compact Layout — Case

Compact Layout controls the fields shown in the **Highlights Panel** at the top of a Case record. It's the first thing an agent sees when opening a Case.

### 2.1 — Configuration

**Path:** Setup → Object Manager → Case → Compact Layouts → New

**Layout Name:** `Support Agent — Revenue Aware`

**Fields (order matters, left-to-right in highlights):**

| Order | Field | Why it's here |
|---|---|---|
| 1 | `CaseNumber` | Identity |
| 2 | `Account_Revenue_Tier_Badge__c` (formula — see §2.3) | Immediate tier signal |
| 3 | `Account.Name` | Customer name |
| 4 | `Priority` | Urgency |
| 5 | `Status` | Workflow state |
| 6 | `Account_RAG_at_Creation__c` | Health at creation |
| 7 | `Account_CSM_Name__c` | Who to loop in |
| 8 | `Age1__c` | Ticket age |

**Assign as Primary Compact Layout for:** all support-agent profiles (L1, L2, L3, FLR, TNR profiles)

---

### 2.2 — Page Layout Additions

In addition to compact layout, add these fields to the **standard Case page layout** for support profiles in a new dedicated section:

**Section name:** "Revenue Context"
**Position:** Just below the Highlights panel, above the main Case Details section.

Fields (arranged in 2 columns):

| Column 1 | Column 2 |
|---|---|
| Account_Revenue_Tier__c | Account_CSM_Name__c |
| Account_RAG_at_Creation__c | Is_Top_Customer__c |
| Account_LTM_Revenue__c (if built) | Account.Support_Group__c |

**Hidden on page layout (still on compact layout for highlights):**
`Account_Revenue_Tier_Badge__c` — purely display, no need to duplicate.

---

### 2.3 — Tier Badge Formula Field on Case

**Purpose:** Visual shorthand with color-coded emoji/text for fast agent triage.

| Attribute | Value |
|---|---|
| API Name | `Account_Revenue_Tier_Badge__c` |
| Label | Tier |
| Object | Case |
| Type | Formula (Text) |
| Length | 60 |

**Formula:**
```
CASE(Account_Revenue_Tier__c,
  "HYPERCARE", "🚨 HYPERCARE",
  "STRATEGIC", "⭐ STRATEGIC",
  "PREMIUM",   "🔷 PREMIUM",
  "UNKNOWN",   "❓ UNKNOWN",
  "STANDARD"
)
```

> Emojis render in most Salesforce Lightning contexts. If unreliable, fall back to text-only prefixes ("[!] HYPERCARE", "[*] STRATEGIC").

---

## 3. Case Highlights Panel — Visual Design Reference

What the agent sees when a Case opens:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  #DCA-0045671   🚨 HYPERCARE   ACME CORP   Critical   Open   🔴 RED     │
│  CSM: Priya Sharma                             Age: 2 d 14 h 11 m       │
└─────────────────────────────────────────────────────────────────────────┘
```

vs. a Standard ticket:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  #DCA-0045672    STANDARD   Small Co Pvt Ltd    Minor    New   —        │
│  CSM: —                                        Age: 0 d 0 h 3 m         │
└─────────────────────────────────────────────────────────────────────────┘
```

The visual contrast alone — 🚨 HYPERCARE vs no badge — drives agent attention without needing training.

---

## 4. CTI Softphone Layout

Salesforce Open CTI controls what shows in the **softphone panel** (top-right of Console) during an active call. The Exotel CTI adapter is already installed; we update the softphone layout.

### 4.1 — Configuration

**Path:** Setup → Softphone Layouts → New

**Layout Name:** `Support Agent — Revenue Aware`

### 4.2 — Inbound Call Display (before Case is created)

During ringing / active call, before a Case exists, the softphone shows:

```
┌─────────────────────────────────────┐
│  📞 Inbound Call                    │
│  +91 98765 43210                    │
│                                     │
│  ──────────────────────────────── │
│  🚨 HYPERCARE                       │
│  ACME CORP                          │
│  RAG: 🔴 RED                        │
│  CSM: Priya Sharma                  │
│                                     │
│  [ Create Case ]   [ Open Account ] │
│  [ View Open Tickets ]              │
└─────────────────────────────────────┘
```

### 4.3 — Call Context Payload → Softphone Display Mapping

The IVR call context payload (see [03 §4.2 Node 7](./03-ivr-nodeflow-design.md#node-7--transfer-to-queue-with-call-context)) maps to softphone fields:

| Call Context Variable | Softphone Display |
|---|---|
| `support_tier` | Tier badge (top line, colored) |
| `account_name` | Customer name (second line, bold) |
| `rag_status` | RAG icon + color (third line) |
| `csm_name` | CSM name (fourth line) |
| `caller_number` | Caller phone (standard CTI display) |
| `lookup_source` | Hidden — emit as debug/audit only |

### 4.4 — Screen Pop Behavior

Configure screen pop behavior per call disposition:

| Scenario | Screen Pop |
|---|---|
| Inbound call, matched Account with open Cases | Pop the most recent open Case for that Account |
| Inbound call, matched Account with no open Cases | Pop a **new Case create page** pre-filled with AccountId, Priority based on tier |
| Inbound call, no Account match | Pop a **search screen** with caller number pre-filled |
| Outbound call | No screen pop (agent typically initiates with context already loaded) |

### 4.5 — Pre-filled Fields for "Create Case" Action

When agent clicks **Create Case** from softphone:

```
Case.AccountId           = <matched account id from IVR>
Case.Priority            = IF(tier == 'HYPERCARE', 'Critical',
                              IF(tier == 'STRATEGIC', 'Major',
                                 IF(tier == 'PREMIUM', 'Major', 'Minor')))
Case.Origin              = 'Phone'
Case.Exotel_CTI__Call_Sid__c      = <from CTI>
Case.Exotel_CTI__From__c          = <caller number>
Case.Exotel_CTI__Call_Duration__c = <from CTI>
```

The Flow in [02](./02-case-flow-specification.md) re-validates the tier at save time and stamps `Account_Revenue_Tier__c`.

---

## 5. Quick Actions on Case — For Tier-Aware Workflows

Add these quick actions to the Case page layout for Strategic/Hypercare workflows.

### 5.1 — "Notify CSM" Quick Action

**Type:** Chatter post
**Trigger button label:** Notify CSM
**Effect:** Posts a Chatter message mentioning the Account CSM (from `Account_CSM_Name__c`) on the Case feed:

```
@{Account_CSM_Name__c} — new {Account_Revenue_Tier__c} ticket from {Account.Name}:
{Subject}
```

Useful for L1 agents handling Strategic tickets who want to loop in CSM proactively.

### 5.2 — "Escalate to L3" Quick Action

**Type:** Update Record action
**Fields updated:**
- `OwnerId` → L3 Escalation Queue
- `Status` → Open
- `Escalation_Level__c` → 1

**Visible only when:** `Account_Revenue_Tier__c IN ('HYPERCARE', 'STRATEGIC')` (via Lightning dynamic action conditions)

### 5.3 — "Add to CSM Watch" Quick Action

**Type:** Create Chatter follow
**Effect:** Adds the Account CSM as a follower on the Case so they see all updates.

---

## 6. List Views for Agents — Filtered by Tier

### 6.1 — "My Hypercare Tickets"

**Filter:**
```
OwnerId = CURRENT_USER
Status NOT IN ('Close_successful', 'Close_unsuccessful', 'Closed')
Account_Revenue_Tier__c = 'HYPERCARE'
```

Pinned at top of Case list view for all Support profiles.

### 6.2 — "My Strategic Tickets"

Same as above with tier = STRATEGIC.

### 6.3 — "All Open Tier 1+ (Team)"

**Filter:**
```
OwnerId IN (Hypercare Support Queue, Strategic Support Queue)
Status NOT IN ('Close_successful', 'Close_unsuccessful', 'Closed')
```

Visible to L2/L3 team leads and managers for team-wide visibility.

### 6.4 — "Aging Strategic Tickets > 24h"

**Filter:**
```
Account_Revenue_Tier__c IN ('HYPERCARE', 'STRATEGIC')
Status NOT IN ('Close_successful', 'Close_unsuccessful', 'Closed')
CreatedDate <= LAST_N_HOURS:24
```

Supervisor view for SLA management.

---

## 7. Dashboard Components

### 7.1 — Tier Distribution — Open Tickets

**Report type:** Cases
**Filter:** `Status NOT IN ('Close_successful', 'Close_unsuccessful', 'Closed')`
**Grouping:** `Account_Revenue_Tier__c`
**Visualization:** Horizontal bar chart

### 7.2 — Tier Distribution — Tickets Created (This Month)

**Filter:** `CreatedDate = THIS_MONTH`
**Grouping:** `Account_Revenue_Tier__c`, sub-grouping: `RecordType.Name`
**Visualization:** Stacked column chart

### 7.3 — SLA Compliance by Tier

**Filter:** `ClosedDate = LAST_N_MONTHS:3`
**Grouping:** `Account_Revenue_Tier__c`
**Metrics:**
- Avg `First_Response_Time__c`
- Avg `Resolution_Time_Minutes__c`
- % with `SLA_Violated__c = FALSE`

Add to a new "Revenue-Aware Support" dashboard pinned on the Support team home page.

---

## 8. Conditional Formatting — Lightning Page

On the Case Lightning Record Page, use **Dynamic Visibility** to conditionally show/hide components based on tier.

### 8.1 — Hypercare Banner Component

Add a Rich Text component at the top of the Case page:

```html
<div style="background: #d04124; color: white; padding: 12px; border-radius: 6px; font-weight: bold;">
  🚨 HYPERCARE ACCOUNT — Escalate immediately to L3 if not resolved within 2 hours.
  Notify CSM {!Case.Account_CSM_Name__c} for status.
</div>
```

**Dynamic visibility filter:** `Account_Revenue_Tier__c = "HYPERCARE"`

### 8.2 — Strategic Reminder Component

Add a Rich Text component:

```html
<div style="background: #fff4bc; padding: 8px; border-left: 4px solid #f5a623;">
  ⭐ STRATEGIC ACCOUNT — CSM {!Case.Account_CSM_Name__c} should be kept in loop on all updates.
</div>
```

**Dynamic visibility filter:** `Account_Revenue_Tier__c = "STRATEGIC"`

### 8.3 — CSM Activity Tab

Add a related list showing recent Activities/Events on the Account where Owner = Account_CSM. Gives agent context on what CSM has been doing.

**Dynamic visibility filter:** `Account_Revenue_Tier__c IN ("HYPERCARE", "STRATEGIC", "PREMIUM")`

---

## 9. Agent Training — One-Pager

A one-page reference for agents on what the tier badges mean and expected behavior.

| Badge | What to do first | SLA target |
|---|---|---|
| 🚨 HYPERCARE | Acknowledge within 15 min, post Chatter @CSM, escalate to L3 if blocked | 2 hr response / 8 hr resolution |
| ⭐ STRATEGIC | Acknowledge within 30 min, keep CSM informed of status changes | 4 hr response / 24 hr resolution |
| 🔷 PREMIUM | Acknowledge within 1 hr, standard escalation if needed | 4 hr response / 24 hr resolution |
| (STANDARD) | Standard FLR workflow | Standard SLA |
| ❓ UNKNOWN | Confirm Account, then re-evaluate priority | Standard SLA |

Pin this in the Support Team Chatter group + include in new-hire onboarding.

---

## 10. Accessibility & Edge Cases

| Concern | Handling |
|---|---|
| Agents using screen readers | Emoji badges should also have text labels ("Hypercare Account", not just 🚨). Formula field already includes text. |
| Browser font doesn't render emojis | Fallback: configure text-only variant of `Account_Revenue_Tier_Badge__c` via a org-wide user preference or profile-level switch |
| Compact layout space constraints | Maximum 6–8 fields in compact layout. If adding more, remove `CaseNumber` (shown in page header anyway) |
| Tier changes mid-ticket | Creation-time tier (`Account_RAG_at_Creation__c`, `Account_Revenue_Tier__c`) is preserved. Agent can manually check current Account tier via related list. |
| CSM changes mid-ticket | `Account_CSM_Name__c` on Case is stamped at creation. If CSM changes, Case still shows original CSM. Add a formula field on Case that pulls current CSM: `Account_CSM_Current__c = Account.Account_CSM__r.Name` |

---

## 11. Deployment Checklist

- [ ] Compact layout `Support Agent — Revenue Aware` created and assigned to support profiles
- [ ] Page layout "Revenue Context" section added for support profiles
- [ ] `Account_Revenue_Tier_Badge__c` formula field deployed
- [ ] Softphone layout updated with tier display and pre-filled Create Case action
- [ ] Screen pop rules configured in Open CTI settings
- [ ] Quick Actions: Notify CSM, Escalate to L3, Add to CSM Watch deployed
- [ ] 4 list views created (My Hypercare, My Strategic, Team Open Tier 1+, Aging Strategic)
- [ ] Hypercare / Strategic conditional banner components added to Case Lightning Record Page
- [ ] Dashboard with 3 tier reports pinned on Support team home
- [ ] Agent training one-pager published in Chatter Support Team group
- [ ] UAT with 5+ agents across all tiers (see [06](./06-test-and-rollout.md))

---

## 12. Open Questions for SF Admin / UX

1. Should `Account_CSM_Name__c` stamp at creation-time only, or also have a `Account_CSM_Current__c` formula that auto-updates? *Recommendation: both — stamp + formula.*
2. Should Hypercare banner also email the CSM on Case creation? *Recommendation: Yes, via separate After-Save flow. Out of scope for v1.*
3. Which profiles get the new compact layout? Only support profiles, or CSM profiles too? *Recommendation: Support profiles only initially; CSMs see Accounts, not Cases as primary workflow.*
4. Should tier badges be clickable (filter list view)? *Recommendation: No for v1. Global search works.*
