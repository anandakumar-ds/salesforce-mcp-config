# Exotel Salesforce — Field Guide (Paste Version)

**What is this?** A compact, paste-ready version of the full `CLAUDE.md` field reference. Covers ~90% of real Exotel Salesforce queries in ~15k chars.

**Who needs this?**
- **Claude Desktop users** — Desktop does NOT auto-load `CLAUDE.md`. Paste this into *Project Settings → Instructions*.
- **ChatGPT, Cursor chat, Windsurf chat, any other LLM tool** — same deal.
- **Claude Code users** — you don't need this. Claude Code auto-loads the full `CLAUDE.md` (1,100+ lines) from the repo root. Just `cd` in and `claude`.

For the full reference (Loss Reason values, every custom field, Tableau dashboard mappings, 75+ SDF fields, retention formulas), see `CLAUDE.md`.

---

## Org

- **Alias**: `ameyo`
- **URL**: https://ameyo.my.salesforce.com
- **Fiscal Year**: Apr 1 – Mar 31. FY26 = Apr 2025 – Mar 2026.
- **Today's date** is the anchor — "this quarter", "this year" always mean Exotel FY, not calendar year.

---

## Revenue vs Bookings — TWO DIFFERENT SOURCES (CRITICAL)

Getting this wrong is the #1 cause of bad answers. Exotel has two separate data sources and they give very different numbers.

### Reported Revenue (default for "revenue", "actual revenue", "reported revenue")
- **Object**: `accounts_revenue__c`
- **Value**: `Revenue_Booked_Amount__c` (Label: "Reported Rev Amount")
- **Date**: `Revenue_Booked_On__c`
- **Sector**: `Cluster__c` (directly on this object)
- **GP/Profit**: `GP__c`, `Variable_Cost__c`, `Fixed_Cost__c`, `Total_Cost__c`
- **Normalized**: `Norm_Rev_Amount__c`
- **Other**: `SKU__c`, `Products__c`, `Region__c`, `Classification__c`, `Revenue_Classification__c`, `Account__c`, `Customer_Name__c`, `CSM__c`, `Account_Manager__c`

### Order Bookings (for "bookings", "OB", "deals won", "order value")
- **Object**: `Opportunity`
- **Stage filter**: `StageName IN ('Order', 'POC')` — Exotel's won stage is `'Order'`, NOT `'Closed Won'`
- **Date**: `B_Deal_Date__c` (NOT `CloseDate`)
- **Value**: `Net_New_INR__c` (formula, already in INR)
- **Raw**: `Net_New__c` (set by Finance)

**Default rule**: Any "revenue" question → `accounts_revenue__c`. Only use `Opportunity` if user explicitly says "bookings", "deals", or "pipeline".

---

## Pipeline / Funnel Stages (CRM Buddy validated, Tableau-validated)

| Concept | Stages Included |
|---------|-----------------|
| **Pipeline** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, POC Closed |
| **Funnel / Total Funnel** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending, POC, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost |
| **Open Funnel** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending |
| **Order / Booking** | POC, Order |
| **Closed / Closed Funnel** | Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, POC Closed |

**Key distinctions:**
- Pipeline ≠ Open Funnel. Pipeline is everything (won + lost + open). Open Funnel is only active deals.
- POC counts as both a won stage (Order/Booking) AND a funnel stage, but NOT as Pipeline.
- POC Closed counts as Closed AND Pipeline, but NOT as Funnel.
- **Excluded from all concepts**: Suspect, Rejected, SDF Rejected.

---

## Slang Dictionary

### Region
| User Says | Database Value |
|-----------|---------------|
| Dom, Domestic | Domestic Enterprise |
| Int | International |
| Scaleup | Scaleup |
| Internal | Internal |

### Cluster
| User Says | Database Value |
|-----------|---------------|
| BI | Banking and Insurance |
| FS | Financial Services |
| Tech | Technology |
| Marketplace | Marketplace |
| Mobility | Mobility |
| Partnerships | Partnerships |
| Retail | Retail |
| Services | Services |
| Africa | Africa |
| Romena | Romena |
| APAC | APAC |
| UAE | UAE |
| US | US |
| KSA | KSA |
| SMB | SMB |
| Mid Market | Mid Market |
| Internal | Internal |

### Parent SKU (on `accounts_revenue__c.Products__c` / `Opportunity.Parent_SKU__c`)
| User Says | Database Value |
|-----------|---------------|
| AI | Gen AI (on Opp); on Revenue: Conversational AI, Voicebot, Chatbot |
| ECC, CC, Contact Center | On Revenue: Ameyo, Ameyo Emerge, Ameyo Engage, Ameyo Fusion CX, VoIP-CC. On Opp: Contact Centre / Contact Center |
| Voice | Voice |
| SMS | SMS |
| WhatsApp, WA | Whatsapp, WhatsApp Conversational |
| Truecaller, TC | Truecaller |
| Chatbot | Chatbot |

### SKU (on `accounts_revenue__c.SKU__c` / `Opportunity.SKU__c`)
| User Says | Database Value |
|-----------|---------------|
| PF Voice | PF Voice |
| Enterprise CC, ECC | Enterprise CC |
| PF Voice CC | PF Voice CC |
| SMS | PF Messaging SMS |
| WhatsApp, WA | PF Messaging Whatsapp |
| TC, Truecaller | PF Others TC |
| AI, Conversational AI | Conversational AI |
| Voicebot | Voicebot |
| Chatbot | Chatbot |
| CQA | CQA |
| VSIP | VSIP |
| RCS | PF Messaging RCS |

### Deal Category
| User Says | Database Value |
|-----------|---------------|
| Subscription, Subs, Sub | Subscription |
| OT | One Time |
| Commit, Commit Deal, Commit Deals | Voice Commit Deals |
| Non Commit | Voice Non-Commit Deals |
| Reversals, Reversal | Partial Reversal, Full Reversal |

### Revenue Classification (on `accounts_revenue__c.Revenue_Classification__c`)
| User Says | Database Value |
|-----------|---------------|
| Net New | Scaleup1, Scaleup2, Retention1, Retention2 |
| Organic | Retention3 |
| Scaleup | Scaleup1, Scaleup2 |
| Retention | Retention1, Retention2, Retention3 |

### Classification (on `accounts_revenue__c.Classification__c`)
| User Says | Database Value |
|-----------|---------------|
| Up sell, Upsell | Up sell |
| Net New | Net New |
| New Sales | New Sales |
| Cross sell | Cross sell |
| Expansion | Expansion |

---

## Opportunity — Key Fields

### Value / Revenue
- `Net_New_INR__c` — **primary revenue metric** (formula, INR)
- `Net_New__c` — raw net new (set by Finance)
- `MRR_Amount__c` — monthly recurring revenue
- `One_Time_Value__c` — one-time value
- `Total_OB__c` — total order booking (formula)
- `Full_Potential_Value_INR__c` — full deal potential (INR)

### Dates
- `B_Deal_Date__c` — **PRIMARY booking date (USE THIS, NOT CloseDate)**
- `CloseDate` — standard SF field, unreliable for Exotel booking analysis
- `Deployment_Date__c`, `Reversal_Date__c`, `LastStageChangeDate`

### Classification
- `StageName` values: Suspect, Prospect, Approach, Proposal, Negotiation, SDF Submission, POC, On Hold, Closed won - Pending, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, Rejected, POC Closed, SDF Rejected
- `Deal_Type__c` — Subscription, On-Premise, AMC, Onetime_Customisation, Onetime_Installation, Onetime-AI
- `Classification_Type__c` — New Sales, Cross sell, Up sell, Cross Sell New, AMC Renewal, RE Renewal, License Renewal, POC, Net-New Upsell (Cross-Sell), Net-New Upsell (New Sales)
- `SKU__c` — see slang table above
- `Forecast_Category__c` — Pipeline, Upside, Commit
- `Commit_Status__c` — Non-Commit Deal, Commit Deal
- `Reversal_Type__c` — Full Reversal, Partial Reversal
- `Use_Case__c` — Collections, Marketing campaigns, Customer support, Service delivery, Sales automation

### Geography
- `Account_Cluster__c` — sector/vertical on Opp (22 values)
- `Account_Region__c` — International, Scaleup, Americas, Internal, Domestic Enterprise
- `Region__c`, `Cluster__c` — formula, derived from Account

### People
- `OwnerId` — Owner (AD)
- `Co_owner__c` — CSM
- `Owner_Manager__c` — Owner's manager
- `Product_Specialist__c` — Pre-Sales

### Loss / Win Analysis
- `Loss_Reason__c` — 67 picklist values
- `Loss_Theme__c` — Pricing and Budget Constraints, Relationship, Product Fit and Features, Internal Customer Factors, Other External Factors, Execution and Timing Issues, Lack of Value Proposition, Technical and Security Concerns
- `Win_Reasons__c` — 11 values (Strong Product differentiator, Full stack value prop, Cost differentiation, etc.)
- `Win_Theme__c` — Product Related, Customer Relationship, Pricing Advantage, Strong Implementation Strategy

### Stage Distribution (as of Mar 2026)
Order: 54.8%, Closed-No decision: 18.9%, Rejected: 10.1%, Closed Lost: 6.6%, Closed Unknown: 5.4%. Total: 73,573 opps.

---

## Account — Key Fields

### Segmentation
- `Cluster__c` — 24 values (see Cluster slang)
- `Sub_Cluster__c` — Services, Digital Natives, IT/ITeS/Tech/Telecom, Healthcare & Education, BFSI, Manufacturing & Distribution, Government, SME, SMB, ROW, UAE, Indonesia, RoAPAC, Africa, Europe, RoME
- `Region__c` — International, Scaleup, Internal, Domestic Enterprise
- `Business_Unit__c` — Enterprise North/South/West, Commercial North/South/West, East India, National Account, Africa, APAC, ME, Philippines, Americas, Europe, ISB Direct, ROW, SAARC
- `Account_Category__c` — National Account, Regional Account, SME & SMB, International

### Health / Retention
- `RAG__c` — RED, AMBER, GREEN
- `Customer_Health__c` — formula string
- `Churned_Day__c` — **formula NUMBER (NOT a date). Churned = `Churned_Day__c > 0`**
- `Revenue_Growth__c`, `GP_Growth__c`, `Expansion_Potential__c`
- `NPS_Score__c`, `CSAT__c`
- `Last_Revenue_Date__c`

### Industry
- `Nature_of_Business_Category__c` (Vertical) — BPO, IT/ITES, SaaS, Consumer Internet, Healthcare, Travel & Hospitality, Financial Services, Education, Automotives, Consulting Services, Telecommunications, Other
- `Nature_of_Business_Sub_category__c` — 65 sub-vertical values
- **DO NOT use** `Account.Industry` — use `Cluster__c` for sector questions

### People
- `OwnerId` — AD (Account Director)
- `Account_CSM__c` — CSM
- `Sales_Engineer__c`, `Researcher_Name__c`

### Flags
- `Top_Customer__c`, `Is_ABM__c`, `Is_SAAS_Premium_Account__c`, `Strategic_Alliance__c`

---

## Case — Support Tickets ("Ameyo Care" / "ECC tickets")

### Terminology (users may say any of these)
- "Ameyo Care tickets" / "ECC tickets" / "support tickets" / "Ameyo tickets" → `Case`
- "Ticket Number" = `CaseNumber`
- "Queue" = `Queue__c` (picklist, NOT Owner queue name)
- "Ticket Owner" = `Owner.Name`

### Record Types
- **Ameyo Care core**: `Normal Support`, `Change Management`, `RCA`, `Release Upgrade`, `Philippines Support`
- **Platform**: `Platform Support`, `Premium Platform Support`, `SaaS Alerts`, `AOC Alerts`, `APC Alert`
- **Other**: `Project Issues`, `Service Issue`, `Service Delivery`, `Consultancy`, `Escalation`
- **Specialized**: `CognoAI`, `Cogno Delivery`, `Compass`, `BIU`, `TrueCaller`, `TTSL`, `SUAM`, `Feedback`, `GDPR`, `CoC Tickets`

### Status Values
New, Open, Pending, Note_added, Resolved, Re-Open, Close_successful, Close_unsuccessful, Approval Pending, Resolved - RCA Pending, In Progress, Waiting on Customer (New), Waiting on DRI (New), Waiting on Third party, Closed - No Response, Delivery - In Progress, Details Pending, Closed, Closed from DRI

### Priority Values
Critical, Major, Minor (primary for Ameyo Care); Low, Medium, High, Urgent, P1, P2, P3 (other record types)

### Key Custom Fields
- `Age1__c` (STRING) — display ("320 d 21 h 19 m")
- `Age_in_min__c` (NUMBER, formula) — use for calculations
- `Queue__c` — L1, L2, L3-Escalation, Classification, Hardware, License, Release Upgrade, Change-Mgmt, Customer Pending, Resolved Queue
- `Issue_Category__c` — 82 values (ACP Issue, Calling issue, License Issue, Report Issue, Change Request, etc.)
- `Issue_Sub_category__c` — 300+ values
- `Issue_type__c` — Technical Issue, Product Usage & Configuration, Billing and Account related, Downtime, Escalation, GP Queries, Churn Request
- `Product_Type__c` (picklist) — Enterprise CC, Platform
- `Product_SKU__c` — Voice, Campaign, Exolite, Chat, Phone, Messaging, Whatsapp, Streaming
- `Support_Group__c`, `SAAS_Team_Ownership__c` (SAAS FLR / SAAS TNR), `Ticket_resolution_team__c` (L1/L2/L3 Team)
- `Resolution_Time_Minutes__c` — use for MTTR
- `SLA_Violated__c` (boolean), `Overall_SLA__c` (Met/Not_Met), `SLA_Violation_Reason__c`
- `Is_Jira_Escalated__c`, `JIRA_Escalated_Date__c`, `Jira_Ticket_Key__c`, `Jira_Ticket_Priority__c`
- `Escalation_Level__c` (1-4), `First_Escalation_time__c` through `Fourth_Escalation_time__c`

### Dashboard Filters (Ameyo Care Overview)
- All reports: `RecordType IN ('Change Management','Normal Support','RCA','Release Upgrade','Philippines Support')` + exclude test accounts
- **New Tickets**: `Status = 'New'`
- **Open Tickets**: `Status IN ('Open','Note_added','Re-Open')`
- **Pending Tickets**: `Status = 'Pending'`
- **Resolved Tickets**: `Status = 'Resolved'`
- **FLR & TNR Team**: RecordType = 'Normal Support', Status NOT IN ('Close Unsuccessful','Close Successful'), grouped by Status + Priority
- **L3 Team**: RecordType IN ('Change Management','Normal Support','Project Issues','RCA','Release Upgrade'), Status NOT IN ('Close Unsuccessful','Close Successful')

### Owner Queue Names (filter on `Owner.Name`)
- **FLR**: FLR Support Queue, SAAS FLR Queue
- **TNR**: TNR - Critical/Major/Minor Queue, SAAS TNR Queue, SAAS TNR Premium/Standard Critical/Major/Minor Queue
- **L3**: L3 Support Queue, L3 Escalation - Support
- **Other**: APC/AOC(Support), Classification/Helpdesk(Support), Change Management Queue, Release Upgrade Queue, Philippines Support, Problem Management, Compass Queue, Premium Support Queue

### Ticket Volume (YTD FY26)
- Platform Support: 19,257 (LARGEST)
- Normal Support (Ameyo Care): 4,988
- Support: 1,952
- CognoAI: 963
- Service: 703, SUAM: 292, Service Delivery: 224, Change Mgmt: 84

---

## Lead — Key Fields
- `LeadSource` — "Answer Engine" (AI chatbots), "IS Generated" (SDR-generated), etc.
- `UTM_Campaign__c` — e.g., 'chatgpt.com' for ChatGPT-sourced leads
- `Owner.UserRole.Name LIKE '%SDR%'` — filter for SDR leads

---

## accounts_revenue__c — Key Fields (full)

### Revenue
- `Revenue_Booked_Amount__c` — PRIMARY revenue
- `Revenue_Booked_On__c` — recognition date
- `Norm_Rev_Amount__c` — normalized
- `Total_Rev_break_Amount__c` — revenue break
- `Revenue_Classification__c` — see slang table

### Cost & Profit
- `GP__c` — Gross Profit
- `Fixed_Cost__c`, `Variable_Cost__c`, `Total_Cost__c`

### Product
- `SKU__c`, `Parent_SKU__c`, `Derived_ParentSKU__c`, `Products__c`, `Product_Type__c`

### Classification
- `Classification__c`, `Revenue_Attribution__c`, `AOP_Category__c`, `Rev_Source__c`, `Rev_Sub_Source__c`

### Account / Geography
- `Account__c` — ref to Account (Setup-Tenant Account)
- `Customer_Universal_Account__c` — ref to Account (universal)
- `Customer_Name__c`, `Cluster__c`, `Region__c`

### People
- `Account_Manager__c` (User), `CSM__c` (User)

---

## Retention Metrics

All computed on `accounts_revenue__c`:

- **NRR** (Net Revenue Retention) = Current period revenue / Preceding period revenue (includes upsell/cross-sell)
- **GRR** (Gross Revenue Retention) = Current period revenue / Preceding period revenue (excludes expansion)
- **Net GPR** = NRR formula but using `GP__c`
- **Gross GPR** = GRR formula but using `GP__c`
- Variants: Rolling 3M, Rolling 12M, YTD

---

## GP / Margin Formulas
- **GP**: `GP__c` on `accounts_revenue__c`
- **GP Margin** = `GP__c / Revenue_Booked_Amount__c` (compute in post-processing)
- **Costs**: `Variable_Cost__c`, `Fixed_Cost__c`, `Total_Cost__c`

---

## Custom Objects — Quick Reference

| Object | Purpose |
|--------|---------|
| `accounts_revenue__c` | Revenue recognition records |
| `Target__c` | Per-user GP/Revenue/OB targets |
| `Accounts_Target__c` | Revenue/GP targets by account (used in Variance Analysis) |
| `Booking_Target__c` | Booking targets (joins to Opportunity) |
| `SDF__c` | Sales Deal Form / commercial proposals (164 fields) |
| `SDF_Line_Item__c` | SDF line items with SKU/pricing |
| `Opportunity_Trend__c` | Opportunity snapshots for trending |
| `Event` | Meetings (used by Powerplay + Mgmt dashboards) |
| `Program__c` | Project/program management |
| `Opp_Related_Programs__c` | Junction: Opportunity ↔ Program |
| `Survey__c` | Customer satisfaction surveys |
| `Support_Quality__c` | Quality audit scorecards |
| `AMC__c` | Annual Maintenance Contract records |
| `Legal_Tickets__c` | Legal review tickets |
| `SaaS_Daily_Usage__c` | Daily SaaS usage metrics per tenant |

---

## CRM Buddy Analytical Patterns

Apply these when producing answers:

1. **"My" vs org-wide detection** — "my deals"/"my accounts"/"I closed" → add `OwnerId = [current user]` (or `Account_Manager__c = [user]` for revenue) filter
2. **No single number** — always include dimensional breakdowns (by cluster, SKU, month, owner). Never return just one aggregate.
3. **Currency formatting** — ₹X.XX L (lakhs, ÷100000) when < 1 Cr; ₹X.XX Cr (crores, ÷10000000) when ≥ 1 Cr
4. **Pipeline aging indicators** — 🔴 > 120 days, 🟡 60-120 days, 🟢 < 60 days
5. **Root cause for "why" questions** — if user asks "why did X happen", pull `Loss_Reason__c` / `Loss_Theme__c`, stage progression, age at stage
6. **Response scaling** — micro question (specific metric) → concise answer; macro question (overview) → structured breakdown
7. **Zero data graceful handling** — if a filter returns 0 rows, suggest what to try (wider date range, different cluster)
8. **Top/bottom indicators** — 🟢 for top performers, 🔴 for bottom performers

---

## SOQL Rules

- **Default**: `LIMIT 200` unless user asks for everything
- **Won stage** = `'Order'` (NOT `'Closed Won'`)
- **Multipicklist fields** (`Product_Type__c`, `Type_of_Solution__c`, `ECC_Termination__c`, `Setup__c`, `CRM_3rd_Party__c`) require `INCLUDES` operator, NOT `LIKE`
- **`Description` field** cannot be filtered with `LIKE`
- **`Subject` field** cannot be used in `GROUP BY`
- **Aliases in ORDER BY** — not supported. Use aggregate function directly: `ORDER BY COUNT(Id) DESC`, NOT `ORDER BY count_val DESC`
- **Opportunity time filters** — use `B_Deal_Date__c`, NOT `CloseDate`
- **Revenue questions** — default to `accounts_revenue__c`, not Opportunity
- **Top N queries** — `ORDER BY [metric] DESC LIMIT N`
- **Currency** — format in lakhs or crores with ₹ symbol in output

---

## Example Queries (reference patterns)

```sql
-- FY26 Revenue by Cluster
SELECT Cluster__c, SUM(Revenue_Booked_Amount__c) rev
FROM accounts_revenue__c
WHERE Revenue_Booked_On__c >= 2025-04-01
  AND Revenue_Booked_On__c <= 2026-03-31
GROUP BY Cluster__c
ORDER BY SUM(Revenue_Booked_Amount__c) DESC

-- FY26 Bookings by Parent SKU
SELECT Parent_SKU__c, SUM(Net_New_INR__c) ob, COUNT(Id) deals
FROM Opportunity
WHERE StageName IN ('Order','POC')
  AND B_Deal_Date__c >= 2025-04-01
  AND B_Deal_Date__c <= 2026-03-31
GROUP BY Parent_SKU__c
ORDER BY SUM(Net_New_INR__c) DESC

-- Open Ameyo Care tickets by Priority
SELECT Priority, COUNT(Id) cnt
FROM Case
WHERE RecordType.Name IN ('Normal Support','Change Management','RCA','Release Upgrade','Philippines Support')
  AND Status IN ('Open','Note_added','Re-Open','New','Pending')
GROUP BY Priority

-- Churned accounts
SELECT Id, Name, Cluster__c, Churned_Day__c
FROM Account
WHERE Churned_Day__c > 0
ORDER BY Churned_Day__c DESC
LIMIT 200

-- Loss analysis by theme (current FY)
SELECT Loss_Theme__c, COUNT(Id) deals, SUM(Net_New_INR__c) lost_value
FROM Opportunity
WHERE StageName = 'Closed Lost'
  AND CloseDate >= 2025-04-01
GROUP BY Loss_Theme__c
ORDER BY SUM(Net_New_INR__c) DESC
```
