# Exotel Salesforce MCP

This project provides Salesforce MCP (Model Context Protocol) integration for AI coding assistants.

## Salesforce Org Details
- **Org Alias**: ameyo
- **Org URL**: https://ameyo.my.salesforce.com
- **Toolsets Enabled**: orgs, data, metadata, users

## Revenue Definition (TWO sources)

### 1. Reported Revenue (actual revenue recognized)
When asked about "revenue", "reported revenue", "actual revenue":
- **Object**: `accounts_revenue__c`
- **Value Field**: `Revenue_Booked_Amount__c` (Label: "Reported Rev Amount")
- **Date Field**: `Revenue_Booked_On__c`
- **Cluster/Sector**: `Cluster__c` (directly on this object)
- Other useful fields: `SKU__c`, `Products__c`, `Region__c`, `Classification__c`, `Revenue_Classification__c`, `Account__c`, `Customer_Name__c`, `CSM__c`, `Account_Manager__c`, `Norm_Rev_Amount__c`

### 2. Order Bookings (deals won on Opportunity)
When asked about "bookings", "order value", "deals won":
- **Object**: Opportunity
- **Stages**: `Order` and `POC` (queried separately, NOT combined)
- **Date Field**: `B_Deal_Date__c` (NOT CloseDate)
- **Value Field**: `Net_New_INR__c` (formula, already in INR)
- **Booking Value Formula** (Tableau-validated):
  - Order stage: `Net_New_INR__c` (full value)
  - POC stage: `Net_New_INR__c / 36` (normalized — POC = 36-month commitment)
  - Total Booking = SUM(Order Net_New_INR__c) + SUM(POC Net_New_INR__c) / 36
- **Two-query pattern**: Always generate separate queries for Order and POC stages. The summary step applies the /36 division to POC and combines.
- `Net_New__c` — Raw net new value (DOUBLE, set by Finance)

### Default: Use `accounts_revenue__c` for revenue questions unless user specifically asks about deals/bookings/pipeline.

## Sector / Vertical Mapping
When asked about a "sector" (e.g., Retail, BFSI, Healthcare):
- **On `accounts_revenue__c`**: Use `Cluster__c`
- **On Opportunity**: Use `Account_Cluster__c` (or `Account.Cluster__c`)
- **NOT** `Account.Industry` or `Account.Cohort_Industry__c`
- Sub-sector detail: use `Account.Sub_Cluster__c`

## Pipeline / Funnel Stage Mapping (CRM Buddy Mapping Dictionary, Tableau-validated)

When users ask about "pipeline", "funnel", "open funnel", "bookings", or "closed deals", map to these exact stage sets. This is the authoritative mapping from CRM Buddy's `AI_Mapping_Dictionary` table.

| Concept (User Says) | Stages Included | Notes |
|---------------------|----------------|-------|
| **Pipeline** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, POC Closed | Full lifecycle excluding Suspect, Rejected, SDF Rejected. Includes won+lost+open |
| **Funnel** / **Total Funnel** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending, POC, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost | Same as Pipeline but with POC instead of POC Closed |
| **Open Funnel** | Prospect, Approach, Proposal, Negotiation, SDF Submission, On Hold, Closed won - Pending | Active pipeline — not yet won or lost |
| **Closed** / **Closed Funnel** | Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, POC Closed | All lost/abandoned stages |
| **Order** / **Booking** | POC, Order | Won deals only (both POC and final Order) |

**Key distinctions:**
- "Pipeline" ≠ "Open Funnel" — Pipeline includes everything; Open Funnel is only active deals
- POC is counted as both a won stage (Order/Booking) AND a funnel stage, but NOT as Pipeline
- POC Closed is counted as Closed AND Pipeline, but NOT as Funnel
- Suspect, Rejected, SDF Rejected are excluded from ALL concepts above

## Slang / Abbreviation Mappings (CRM Buddy Mapping Dictionary)

### Region Slang
| User Says | Maps To (Database Value) |
|-----------|------------------------|
| Dom, Domestic | Domestic Enterprise |
| Int | International |
| Scaleup | Scaleup |
| Internal | Internal |

### Cluster Abbreviations
| User Says | Maps To |
|-----------|---------|
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

### Parent SKU Slang
| User Says | Maps To |
|-----------|---------|
| AI | Gen AI |
| ECC | Contact Centre / Contact Center |

### Deal Category Slang
| User Says | Maps To |
|-----------|---------|
| Subscription, Subs, Sub | Subscription |
| OT | One Time |

### Voice Commit Deals
| User Says | Maps To |
|-----------|---------|
| Commit Deal, Commit Deals, Commit | Voice Commit Deals |
| Non Commit | Voice Non-Commit Deals |

### Reversal Type
| User Says | Maps To |
|-----------|---------|
| Reversals, Reversal | Partial Reversal, Reversal Reversal |

## Key Salesforce Objects & Fields

### Opportunity
- Stage values: Suspect, Approach, Prospect, Proposal, Negotiation, POC, On Hold, Order (Won), Closed Lost, Closed-No decision, Closed Unknown, Closed Duplicate, Rejected, SDF Rejected
- `Net_New_INR__c` — **Primary revenue metric** (formula, INR)
- `B_Deal_Date__c` — **Booking date** (use for revenue time filters)
- `MRR_Amount__c` — Monthly recurring revenue (NUMBER, not Currency)
- `Deal_Type__c` — Subscription, On-Premise, Onetime_Customisation, AMC
- `Classification_Type__c` — New Sales, Cross sell, Up sell, Cross Sell New, Net-New Upsell (Cross-Sell), Net-New Upsell (New Sales), AMC Renewal, License Renewal
- `Loss_Reason__c` — Reason for deal loss
- `LastStageChangeDate` — Standard field for tracking stage movement

### Case (Support Tickets) — "Ameyo Care" / "ECC Tickets"

**Terminology Mapping** (users may say any of these):
- "Ameyo Care tickets" / "ECC tickets" / "support tickets" / "Ameyo tickets" → Case object
- "Ticket Number" = `CaseNumber` (format: DCA*, starts with record type prefix)
- "Ticket Status" = `Status`, "Ticket Owner" = `Owner.Name`
- "Queue" = `Queue__c` (picklist on Case, NOT Owner queue name)

**Record Types** (used as filters on all Ameyo Care dashboards):
- **Ameyo Care core**: `Normal Support`, `Change Management`, `RCA`, `Release Upgrade`, `Philippines Support`
- **Other support**: `Project Issues`, `Service Issue`, `Service Delivery`, `Consultancy`, `Escalation`
- **Platform/SAAS**: `Platform Support`, `Premium Platform Support`, `SaaS Alerts`, `AOC Alerts`, `APC Alert`
- **Specialized**: `CognoAI`, `Cogno Delivery`, `Compass`, `BIU`, `TrueCaller`, `TTSL`, `SUAM`, `SUAM Exotel`, `Feedback`, `GDPR`, `CoC Tickets`, `GP & Churn Request`, `Solutions Consultancy`, `Conversation`

**Status Values**: New, Open, Pending, Note_added, Resolved, Re-Open, Close_successful, Close_unsuccessful, Approval Pending, Resolved - RCA Pending, In Progress, Waiting on Customer (New), Waiting on DRI (New), Waiting on Third party, Closed - No Response, Delivery - In Progress, Details Pending, Pending - FD, Closed, Closed from DRI

**Priority Values**: Critical, Major, Minor (primary for Ameyo Care); also Low, Medium, High, Urgent, P1, P2, P3

**Key Custom Fields**:
- `Age1__c` (STRING) — Ticket age display (e.g., "320 d 21 h 19 m")
- `Age_in_min__c` (NUMBER) — Age in minutes (formula, use for calculations)
- `Queue__c` — Picklist: L1, L2, L3-Escalation, Classification, Hardware, License, Release Upgrade, Change-Mgmt, Customer Pending, Resolved Queue, etc.
- `Issue_Category__c` — Picklist (82 values): ACP Issue, Agent UI/Functionality issue, Application Issue, Calling issue, Change Request, DNC India, Enquiry, Fusion, HA Issues, IVR, License Issue, Maintenance Issues, Product Functionality Issue, Report Issue, etc.
- `Issue_Sub_category__c` — Picklist (300+ values): detailed sub-categories
- `Customer_Issue_Category__c` — Customer-facing issue category (similar but customer-labeled)
- `Customer_Issue_Sub_category__c` / `Customer_Issue_Subcategory__c` — Two variant sub-category fields
- `Issue_type__c` — Technical Issue, Product Usage & Configuration, Billing and Account related, Downtime, Escalation, GP Queries, Churn Request
- `Product_Type__c` (PICKLIST, not multi) — `Enterprise CC`, `Platform`
- `Product_SKU__c` — Voice, Campaign, Exolite, Chat, Phone, Messaging, Whatsapp, Streaming, etc.
- `Support_Group__c` (STRING) — Support group assignment (e.g., "Normal Support")
- `SAAS_Team_Ownership__c` — `SAAS FLR`, `SAAS TNR`
- `Ticket_resolution_team__c` — `L1 Team`, `L2 Team`, `L3 Team`
- `Date_Resolved__c` (DATETIME) — When ticket was resolved
- `Resolution_Time_Minutes__c` (NUMBER, formula) — Use for MTTR calculations
- `Is_Jira_Escalated__c` (BOOLEAN) — Whether ticket is escalated to Jira
- `JIRA_Escalated_Date__c` (DATETIME) — When Jira escalation happened
- `Jira_Ticket_Key__c` (STRING) — Jira ticket reference
- `Jira_Ticket_Priority__c` — Highest, High, Medium, Low, Lowest
- `Customer_pending_hours__c` (NUMBER) — Hours spent waiting on customer
- `Escalation_Level__c` (NUMBER) — 1 through 4
- `First_Escalation_time__c` through `Fourth_Escalation_time__c` (DATETIME)
- `SLA_Violated__c` (BOOLEAN) — SLA breach flag
- `Overall_SLA__c` — Met, Not_Met
- `SLA_Violation_Reason__c` — Product Delay, Process Gap, Engineer's Delay, etc.
- `Case_Progress__c` (PICKLIST, 122 values) — Detailed progress tracking
- `RCA_Category__c`, `RCA_Issuetype__c`, `RCA_Sub_category__c` — Root cause analysis fields
- `AMC_Type__c` (STRING) — AMC type for the account
- `ECC_Termination__c` (MULTIPICKLIST) — Cloud Termination, Call Server Termination, DID Termination, etc.
- `Environment__c` — UAT, Production
- `Downtime_Type__c` — Customer End, Issue End, Maintenance, No Downtime
- `CM_Phase__c` — Initiation, Planning, Scheduling, Execution, Monitoring (Change Management)

**Owner Queue Names** (for filtering by team):
- FLR (First Level Resolution): `FLR Support Queue`, `SAAS FLR Queue`
- TNR (Ticket Not Resolved/Second Level): `TNR - Critical Queue`, `TNR - Major Queue`, `TNR - Minor Queue`, `SAAS TNR Queue`, `SAAS TNR Premium Critical/Major/Minor Queue`, `SAAS TNR Standard Critical/Major/Minor Queue`
- L3: `L3 Support Queue`, `L3 Escalation - Support`
- Other: `APC/AOC(Support)`, `Classification/Helpdesk(Support)`, `Change Management Queue`, `Release Upgrade Queue`, `Philippines Support`, `Problem Management`, `Compass Queue`, `Premium Support Queue`

**Ticket Volume by Product Line** (YTD 2026):
- **Platform Support** (19,257 tickets) — LARGEST. "Platform tickets"/"Voice tickets"/"Exotel tickets"
  - Origin: Email (85%), Platform-Voice (10%), Platform-Chat (3%), Portal (1%)
  - Issue_Category__c: Phone (1,845), Cogno chat (565), mostly null (16,790)
  - Product_SKU__c and Issue_type__c mostly unfilled on Platform tickets
- **Normal Support** (4,988 tickets) — "Ameyo Care"/"ECC tickets"
  - Uses: Issue_Category__c, Issue_Sub_category__c, Queue__c, Priority (Critical/Major/Minor)
- **Support** (1,952 tickets) — General support record type
- **CognoAI** (963 tickets) — "AI tickets"/"Cogno tickets"/"chatbot tickets"
  - Cogno_Issue_Category__c: Incident (64%), Service Request (12%), Project Alerts (9%)
  - Cogno_Services__c: Cogno ChatBot (37%), Campaigns Dashboard (16%), LiveChat (12%), WhatsApp Bot (5%)
  - Cogno_Sub_Category__c: OTP Related Issues, Template Related Issue, Livechat Concurrency Issue, etc.
- **Service** (703), **SUAM** (292), **Service Delivery** (224), **Change Management** (84), **Escalation** (48)

**Dashboard Report Filters** (how the Ameyo Care Overview dashboard filters data):
- All Ameyo Care reports: `RecordType IN ('Change Management','Normal Support','RCA','Release Upgrade','Philippines Support')` + exclude test accounts
- **New Tickets**: Status = 'New'
- **Open Tickets**: Status IN ('Open','Note_added','Re-Open')
- **Pending Tickets**: Status = 'Pending'
- **Resolved Tickets**: Status = 'Resolved'
- **FLR & TNR Team**: RecordType = 'Normal Support', Status NOT IN ('Close Unsuccessful','Close Successful'), grouped by Status + Priority
- **L3 Team**: RecordType IN ('Change Management','Normal Support','Project Issues','RCA','Release Upgrade'), Status NOT IN ('Close Unsuccessful','Close Successful'), grouped by Status + Priority
- **Issue Category Breakdown**: grouped by Account.Name across Issue_Category__c
- **Created/Resolved Weekly**: grouped by CreatedDate/Date_Resolved__c week + Priority, last 3 months
- **Created/Resolved This Month**: current month by Priority

### Lead
- SDR role identified via `Owner.UserRole.Name LIKE '%SDR%'`
- ChatGPT leads tracked via `UTM_Campaign__c = 'chatgpt.com'` and `LeadSource = 'Answer Engine'`
- SDR-generated opportunities use `LeadSource = 'IS Generated'` (not 'SDR Generated')

### Account
- `Revenue_Growth__c` — Revenue growth metric
- `Churned_Day__c` — Number field (NOT a date)

## Dashboard → Data Source Mapping (Tableau-Validated, March 2026)

All dashboards are on the Salesforce Home page. Mappings below are validated against actual Tableau Metadata GraphQL API extraction from 12 workbooks (11,053 fields, 22 data sources).

### Mgmt Dashboard (Tableau embedded)

| Sub-Tab | Tableau Data Source(s) | Upstream SF Tables | Value Field(s) | Key Filters |
|---------|----------------------|-------------------|----------------|-------------|
| **CEO** | OneExo Revenue+ DS, Opportunity+ DS, Excel (Finance/HR/Tech) | Account, Accounts_Revenue__c, Opportunity, User + External Excel | ACI/API/GPI counts, NRR/GRR %, product penetration | Region, Cluster |
| **MIS → Revenue Analysis** | OneExo Revenue+ DS (443 fields) | User, Account, Accounts_Revenue__c, Opportunity | Revenue_Booked_Amount__c | Year, Region, Cluster, Parent SKU, SKU, Rev Classification, Product Type, Account Name, Account Manager, Rev Source, CSM |
| **MIS → Historical Account Rev** | OneExo Revenue+ DS | User, Account, Accounts_Revenue__c, Opportunity | Revenue_Booked_Amount__c (monthly by Customer_Name__c, Cluster__c) | Same as above |
| **MIS → GP Analysis** | OneExo Revenue+ DS | User, Account, Accounts_Revenue__c, Opportunity | GP__c, Variable_Cost__c, Fixed_Cost__c, Total_Cost__c | Same as above |
| **MIS → Historical Account GP** | OneExo Revenue+ DS | User, Account, Accounts_Revenue__c, Opportunity | GP__c (monthly breakdown) | Same as above |
| **Variance → Revenue** | OneExo Revenue+ DS (×3 time variants) | Accounts_Revenue__c + **Accounts_Target__c** | Revenue_Booked_Amount__c (Target vs Actual) | Year, Region, Cluster |
| **Variance → GP** | OneExo Revenue+ DS (×3 time variants) | Accounts_Revenue__c + **Accounts_Target__c** | GP__c (Target vs Actual) | Year, Region, Cluster |
| **Variance → Booking** | Opportunity+ DS (×2) | Opportunity + **Booking_Target__c** | Net_New_INR__c (Target vs Actual) | Year, Region, Cluster |
| **Variance → GM Profile** | OneExo Revenue+ DS (×3 time variants) | Accounts_Revenue__c + **Accounts_Target__c** | GP margin % trends | Year, Region, Cluster |
| **Order Booking** | Opportunity+ DS (934 fields) | Opportunity, Account, Lead, User, Campaign, OpportunityLineItem, **Program__c** | Net_New_INR__c, B_Deal_Date__c | Date, Year, Commit\|One-Time, Region, Cluster, Classification Type, Use Case, Source, Account Name, Reversal Type, Opp Owner, Parent SKU, SKU |
| **Pipeline** | Opportunity+ DS | Opportunity, Account, Lead, User, Campaign, OpportunityLineItem, **Program__c** | Net_New_INR__c | Analysis Type, Stages, Forecast Category |
| **Loss Analysis** | Opportunity+ DS | Opportunity, Account, Lead, User, Campaign | Net_New_INR__c, Loss_Theme__c | Loss Reason, Region, Cluster, Status, Source, Classification Type, Year, Quarter, Month, Opp Owner, Product Type |
| **Booking to Revenue** | Tableau Prep flow → **OB_to_Revenue__c** | OB_to_Revenue__c, Account, Opportunity (NOT direct SOQL — Tableau Prep transformation) | OB + Revenue + GP journey | Region, Cluster |
| **Booking Forecast** | Opportunity+ DS | Opportunity, **Booking_Target__c**, Opportunity_Trend__c, Campaign, **Opp_Related_Programs__c** | Net_New_INR__c (Forecast/Target/Actual) | Forecast View, Commit\|One-Time, Region, Parent SKU, Cluster, Status, Classification Type |
| **Penetration Index** | Prep Extract + SF DS | Account, Accounts_Revenue__c, Opportunity_Trend__c, **Lead_Backup__c** | ACI/API/PPI/GPI metrics | PPI-Reporting Month, Min Revenue Limit, Region, Cluster, Parent SKU, AD Name, Account Name, CSM Name |
| **Retention → Revenue** | OneExo Revenue+ DS (×2) | User, Account, Accounts_Revenue__c, Opportunity | Revenue_Booked_Amount__c → NRR, GRR % | Month, Region, Cluster, Parent_SKU__c, SKU__c, AD Name, CSM Name, Account Name, Revenue_Classification |
| **Retention → Gross Profit** | OneExo Revenue+ DS (×2) | User, Account, Accounts_Revenue__c, Opportunity | GP__c → Net GPR, Gross GPR % | Same as Revenue retention |
| **Lead Analysis** | Lead+ DS (416 fields) | Account, Lead, Campaign, Opportunity | COUNT(Id) (MTD/QTD/YTD) | Lead Parameter, BDR, Lead Category, Lead Status, Cluster, Region, Lead Source |
| **Key KPIs** | Opportunity+ DS (×2, 1579 fields) | Opportunity, Opportunity_Trend__c, **Program__c**, User, Account, Lead | Sales Cycle, Win Rate, Conversion Rate | Classification Type, Region, Cluster, Account Owner, Parent SKU |
| **Meetings** | Event+ DS (579 fields) | User, Account, Accounts_Revenue__c, Opportunity, Event | Total Meetings, Productive Meetings | AD/CSM, Productive Meeting, Meeting/Demo, Region, Cluster, Meeting Type, Meeting Category, Meeting Owner, Account Name |
| **Account Credits** | ⚠️ External (AWS QuickSight — NOT Salesforce) | N/A | Credit limits, billing status | accountSid, billingtype, entity, type, status |
| **PF QuickSight** | ⚠️ External (AWS QuickSight — NOT Salesforce) | N/A | Call volumes, usage revenue, completion % | StartDate, EndDate, AccountSid, Cluster, CSM |

### Other Top-Level Tabs

| Tab | Type | Data Source | Purpose |
|-----|------|-------------|---------|
| **Sales User** | Native SF | accounts_revenue__c (GP, Revenue) + Opportunity (Net New OB) + Target__c | Per-user GP/Revenue/OB targets vs actuals (monthly) |
| **Powerplay** | Native SF | Event (Meetings) + Opportunity (Funnel) | Gamification scorecards (Sales, Sales ClusterHead, CX) |
| **Inside Sales** | Native SF | Lead | SDR workspace: My Leads (New/AI/AE/AF/Dead/Stale/Accp/Pend/Rej), My Activities |
| **Cluster Dashboard** | Tableau | accounts_revenue__c (Revenue) + Opportunity (Net New OB, Opp Analysis) | Per-cluster views: FM Funded-I, FM Funded-II & Traditional-II, Traditional-I, SME Funded, BFSI & Strategic Large, APAC, ME, Africa |
| **Support** | Native SF | Case | Ticket management: Ameyo Care, Change Mgmt, APC/AOC, SAAS, Services, SLA's, SLA Delay %, Weekly, User Dashboard, Feedback, Breached SLA, Escalation |
| **Delivery Cadence** | Native SF | Opportunity (delivery pipeline) | Delivery Forecast, Delivery Funnel, Delivery Ageing View (by Region, Cluster, Team) |

### Tableau Workbook Reference (from Metadata API extraction)

| Workbook | Tableau Data Sources | Upstream SF Tables | Sheets |
|----------|--------------------|--------------------|--------|
| Revenue Dashboard | OneExo Revenue+ | User, Account, Accounts_Revenue__c, Opportunity | 171 |
| Variance Analysis | Opp+ ×2, Revenue+ ×3 | User, Account, Lead, Opportunity, Accounts_Revenue__c, Accounts_Target__c, Booking_Target__c | 8 |
| Opportunity Analysis | Opportunity+ | Opp_Related_Programs__c, Program__c, User, Account, OpportunityLineItem, Lead, Campaign, Opportunity | 134 |
| Booking Forecast | Opportunity+ | Opp_Related_Programs__c, User, Account, OpportunityLineItem, Campaign, Opportunity_Trend__c, Booking_Target__c, Opportunity | 15 |
| OB to Rev & GP Journey | Tableau Prep ×2 | Account, OB_to_Revenue__c, inspire1__Project__c, Opportunity | 28 |
| Burn Schedule | Tableau Prep | Account, OB_to_Revenue__c, inspire1__Project__c, Opportunity | 9 |
| CEO Dashboard | Excel + SF ×2 | Excel sheets + User, Account, Accounts_Revenue__c + full Opp stack | 77 |
| Key KPIs | Opportunity+ ×2 | Program__c, User, Account, Lead, Opportunity_Trend__c, Opportunity | 0 |
| Lead Analysis | Lead+ | Account, Lead, Campaign, Opportunity | 23 |
| Meetings | Event+ | User, Account, Accounts_Revenue__c, Opportunity, Event | 57 |
| Penetration Index | Prep Extract + SF | User, Account, Accounts_Revenue__c, Opportunity_Trend__c, Lead_Backup__c | 33 |
| Retention | Index + Revenue+ | User, Account, Accounts_Revenue__c, Opportunity | 131 |

### New SF Objects Discovered via Tableau (not in previous mappings)

| Object | Used By | SOQL-Queryable | Notes |
|--------|---------|----------------|-------|
| **Accounts_Target__c** | Variance Analysis | Yes | Revenue/GP targets, joins to accounts_revenue__c |
| **Booking_Target__c** | Variance Analysis, Booking Forecast | Yes | Booking targets, joins to Opportunity |
| **Program__c** | Opportunity Analysis, Key KPIs | Yes | Project/program management |
| **Opp_Related_Programs__c** | Opportunity Analysis, Booking Forecast | Yes | Junction: Opportunity ↔ Program |
| **OB_to_Revenue__c** | OB to Rev, Burn Schedule | No (Tableau Prep only) | Tableau Prep transformation output |
| **Lead_Backup__c** | Penetration Index | No (Prep extract) | Tableau Prep extract |

### Retention Metrics Structure (from accounts_revenue__c, Tableau-validated)
- **NRR** (Net Revenue Retention): Current period revenue / Preceding period revenue (including upsell/cross-sell)
- **GRR** (Gross Revenue Retention): Current period revenue / Preceding period revenue (excluding expansion)
- **Net GPR** (Net Gross Profit Retention): Same as NRR but using GP__c
- **Gross GPR** (Gross Gross Profit Retention): Same as GRR but using GP__c
- Rolling 3M, Rolling 12M, YTD variants available
- Keyholes: Regional, Cluster, SKU breakdowns

### Cluster Categories (from Cluster Dashboard tabs)
FM Funded-I, FM Funded-II & Traditional-II, Traditional-I, SME Funded, BFSI & Strategic Large, APAC, ME, Africa

## SOQL Tips
- Multipicklist fields (`Product_Type__c`, `Type_of_Solution__c`) require `INCLUDES` operator, NOT `LIKE`
- `Description` field cannot be filtered with `LIKE` in SOQL
- `Subject` field cannot be used in `GROUP BY`
- Cannot use alias names in `ORDER BY` — use the aggregate function directly (e.g., `ORDER BY COUNT(Id) DESC`)
- Won stage = `'Order'` (not 'Closed Won')

## Complete Field Audit (March 2026)

### Opportunity Object (227 fields total, 186 custom)

#### Key Value & Revenue Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Amount` | Amount | currency | Standard field |
| `Net_New_INR__c` | Net_New INR | double | FORMULA, primary revenue metric in INR |
| `Net_New__c` | Net New -by Finance | double | Raw net new value set by Finance |
| `MRR_Amount__c` | MRR Amount | double | Monthly recurring revenue |
| `MRR_Amount_formula__c` | MRR Amount | double | FORMULA version of MRR |
| `Norm_MRR__c` | Norm. MRR | double | FORMULA, normalized MRR |
| `One_Time_Value__c` | One Time Amount | double | One-time deal value |
| `One_Time_Amount_formula__c` | One Time Amount | double | FORMULA version |
| `TotalAmount__c` | Normalise Amount | double | Normalized total |
| `Normalise_Amount_formula__c` | Normalise Amount | double | FORMULA |
| `Normalize_Amount_INR__c` | Normalize Amount INR Multiplier | double | FORMULA, INR conversion |
| `Total_OB__c` | Total OB | double | FORMULA, total order booking |
| `Full_Potential_Value__c` | Full Potential Value | double | Full deal potential |
| `Full_Potential_Value_INR__c` | Full Potential Value INR | double | FORMULA |
| `Committed_Booking_Value__c` | Committed Booking Value | double | |
| `Committed_Contract_Value__c` | Committed Contract Value | currency | |
| `Deposit_Amount__c` | Deposit Amount | double | |
| `SDR_Budget_Amount__c` | SDR Budget Amount | double | |

#### Key Date Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `CloseDate` | Close Date | date | Standard, NOT used for booking date |
| `B_Deal_Date__c` | B Deal Date | date | PRIMARY booking date |
| `Deployment_Date__c` | Deployment Date | date | |
| `Reversal_Date__c` | Reversal Date | date | |
| `Lead_Closure_Date__c` | Lead Closure Date | date | |
| `Opp_Closure_Date__c` | Opp_Closure_Date | date | |
| `Opp_Actual_Closure_Date__c` | Opp Actual Closure Date | date | |
| `PGTM_Close_Date__c` | PGTM Close Date | date | |
| `Next_Step_Date__c` | Next Step Date | date | |
| `LastStageChangeDate` | Last Stage Change Date | datetime | Standard |
| `Last_Activity_Date__c` | Last Activity Date | datetime | |
| `Last_Reverse_stage__c` | Last Reverse stage | datetime | |
| `ISQL_Accepted_Date__c` | ISQL Accepted Date | date | |
| `ISQL_Rejected_Date__c` | ISQL Rejected Date | date | |

#### Stage Date Tracking Fields
| API Name | Label |
|----------|-------|
| `Approach_Stage_Date__c` | Approach Stage Date |
| `Prospect_Stage_Date__c` | Prospect Stage Date |
| `Proposal_Stage_Date__c` | Proposal Stage Date |
| `Negotiation_Stage_Date__c` | Negotiation Stage Date |
| `POC_Stage_Date__c` | POC Stage Date |
| `On_Hold_Stage_Date__c` | On-Hold Stage Date |
| `Closed_won_Pending_Stage_Date__c` | Closed won - Pending Stage Date |
| `Order_Stage_Date__c` | Order Stage Date |

#### Classification & Categorization Fields
| API Name | Label | Type | Values |
|----------|-------|------|--------|
| `StageName` | Stage | picklist | Suspect, Prospect, Approach, Proposal, Negotiation, SDF Submission, POC, On Hold, Closed won - Pending, Order, Closed Unknown, Closed Duplicate, Closed-No decision, Closed Lost, Rejected, POC Closed, SDF Rejected |
| `Deal_Type__c` | Deal Type | picklist | Subscription, On-Premise, AMC, Onetime_Customisation, Onetime_Installation, Onetime_Normalised Base, Resident Engg, Onetime-AI |
| `Classification_Type__c` | Classification Type | picklist | New Sales, Cross sell, Up sell, Cross Sell New, AMC Renewal, RE Renewal, License Renewal, POC, Elite Support, Net-New Upsell (Cross-Sell), Net-New Upsell (New Sales) |
| `SKU__c` | SKU | picklist | Conversational AI, Enterprise CC, PF Messaging Others/SMS/Whatsapp/RCS, PF Others/TC, PF Voice/CC, Voice Streaming, CQA, Voicebot, Chatbot, VSIP |
| `Product_Type__c` | Product | multipicklist | 65 values including Enterprise_CC-*, PF_Voice-*, Digital-*, Technology-*, etc. |
| `Use_Case__c` | Use Case | picklist | Collections, Marketing campaigns, Customer support, Service delivery, Sales automation |
| `Forecast_Category__c` | Forecast-Category | picklist | Pipeline, Upside, Commit |
| `Commit_Status__c` | Commit Status | picklist | Non-Commit Deal, Commit Deal |
| `Sales_Status__c` | Sales Status | picklist | New, Hot, cold, warm, No More activity |
| `ISQL_Stage__c` | ISQL Stage | picklist | ISQL Accepted, ISQL Rejected, ISQL Pending |
| `Reversal_Type__c` | Reversal Type | picklist | Full Reversal, Partial Reversal |
| `PGTM_Classificaiton__c` | PGTM Classificaiton | picklist | |
| `PGTM_Stage__c` | PGTM Stage | picklist | |

#### Loss & Win Analysis Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Loss_Reason__c` | Loss Reason | picklist | 67 values |
| `Loss_Theme__c` | Loss Theme | picklist | Pricing and Budget Constraints, Relationship, Product Fit and Features, Internal Customer Factors, Other External Factors, Execution and Timing Issues, Lack of Value Proposition, Technical and Security Concerns |
| `Loss_Comments__c` | Loss Comments | textarea | |
| `Win_Reasons__c` | Win Reasons | picklist | 11 values incl. Strong Product differentiator, Full stack value prop, Cost differentiation |
| `Win_Theme__c` | Win Theme | picklist | Product Related, Customer Relationship, Pricing Advantage, Strong Implementation Strategy |

#### Region & Cluster Fields (on Opportunity)
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Account_Cluster__c` | Account Cluster | picklist | 22 values: Africa, Banking and Insurance, Financial Services, Marketplace, Mobility, Retail, APAC, Services, SMB, Mid Market, Technology, UAE, KSA, US, Romena, etc. |
| `Account_Region__c` | Account Region | picklist | International, Scaleup, Americas, Internal, Domestic Enterprise |
| `Region__c` | Region | string | FORMULA (derived from Account) |
| `Cluster__c` | Cluster | string | FORMULA (derived from Account) |
| `Country__c` | Country | string | |

#### People & Ownership Fields
| API Name | Label | Type | Lookup To |
|----------|-------|------|-----------|
| `OwnerId` | Owner ID | reference | User |
| `Co_owner__c` | CSM | reference | User |
| `Owner_Manager__c` | Owner Manager | reference | User |
| `Product_Specialist__c` | Pre-Sales | reference | User |
| `Partner_Account_Manager__c` | Partner Account Manager | reference | User |
| `Lead_Created_By__c` | Lead Created By | reference | User |
| `Lead_Owner__c` | Lead Owner | reference | User |
| `Primary_Budget_Owner__c` | Primary Budget Owner | reference | Contact |
| `Primary_Contact_Person__c` | Primary Contact Person | reference | Contact |
| `Lead__c` | Lead | reference | Lead |
| `Lead_Campaign__c` | Campaign | reference | Campaign |
| `Partner__c` | Partner | reference | Partner__c |
| `Opportunities__c` | Opportunity | reference | Opportunity (self-ref) |
| `ECC_KYC__c` | CCA ID | reference | Veeno_KYC__c |

#### Calculated / Formula Fields
| API Name | Label | Notes |
|----------|-------|-------|
| `Age__c` | Age | Days since creation |
| `Sales_Cycle__c` | Sales Cycle | Days in sales cycle |
| `Acceptance_Ageing__c` | Acceptance Ageing | |
| `Last_Activity_Since__c` | Last Activity Since | Days since last activity |
| `Parent_SKU__c` | Parent SKU | Derived from SKU |
| `Source_Type__c` | Source Type | Derived from LeadSource |
| `LeadSource__c` | Original Source | Derived from Lead |
| `Closure_Month__c` | Closure Month | |
| `Closure_Stage__c` | Closure Stage | |
| `Quote_Counts__c` | Quote Counts | |
| `Opportunity_Line_Item_Count__c` | Opportunity Line Item Count | |

#### Opportunity Stage Distribution (as of March 2026)
| Stage | Count | % |
|-------|-------|---|
| Order | 40,295 | 54.8% |
| Closed-No decision | 13,881 | 18.9% |
| Rejected | 7,425 | 10.1% |
| Closed Lost | 4,890 | 6.6% |
| Closed Unknown | 3,953 | 5.4% |
| Closed Duplicate | 761 | 1.0% |
| Suspect | 620 | 0.8% |
| Approach | 535 | 0.7% |
| SDF Rejected | 393 | 0.5% |
| Prospect | 365 | 0.5% |
| Proposal | 183 | 0.2% |
| Negotiation | 153 | 0.2% |
| On Hold | 54 | 0.1% |
| Closed won - Pending | 41 | 0.1% |
| POC | 19 | 0.0% |
| **Total** | **73,573** | |

---

### Account Object (214 fields total, 158 custom)

#### Key Business Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Cluster__c` | Cluster | picklist | 24 values: Africa, APAC, Banking and Insurance, Financial Services, Internal, KSA, Marketplace, Mid Market, Mobility, Partnerships, Retail, Romena, Services, SMB, Technology, UAE, US, etc. |
| `Sub_Cluster__c` | Sub Cluster | picklist | Services, Digital Natives, IT/ITeS/Tech/Telecom, Healthcare & Education, BFSI, Manufacturing & Distribution, Government, SME, SMB, ROW, UAE, Indonesia, RoAPAC, Africa, Europe, RoME |
| `Region__c` | Region | picklist | International, Scaleup, Internal, Domestic Enterprise |
| `Geography__c` | Geography | picklist | North, West, South, East |
| `Country__c` | Country | picklist | 232 countries |
| `Account_Category__c` | Account-Category | picklist | National Account, Regional Account, SME & SMB, International |
| `Account_Status__c` | Account Status | picklist | Churned |
| `Customer_Type__c` | Customer Type | picklist | Rental, On Premise |
| `Customer_Stage__c` | Customer Stage | multipicklist | None, Account Mapping, BD Activity, Opportunity Bucket, Problem Account, Deployment, Problematic Churn, Cool Off Period |
| `Business_Unit__c` | Business Unit | picklist | Enterprise North/South/West, Commercial North/South/West, East India, National Account, Africa, APAC, ME, Philippines, Americas, Europe, ISB Direct, ROW, SAARC, Unknown |
| `Product__c` | Product | picklist | Ameyo, AmeyoOnCloud, Ameyo Emerge, Ameyo Engage, Inside Sales Box |
| `Funding_Type__c` | Funding Type | picklist | Pre-Seed through Series J, Angel, Private Equity, Debt Financing |

#### Health & Retention Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `RAG__c` | RAG | picklist | RED, AMBER, GREEN |
| `RAG_Comment__c` | RAG Comment | textarea | |
| `RAG_Formula__c` | RAG Formula | double | FORMULA |
| `Customer_Health__c` | Customer Health | string | FORMULA |
| `Customer_sentiment__c` | Customer sentiment | picklist | |
| `Revenue_Growth__c` | Revenue Growth | double | |
| `GP_Growth__c` | GP Growth | double | |
| `Churned_Day__c` | Churned Days | double | FORMULA (NOT a date) |
| `Expansion_Potential__c` | Expansion Potential | double | |
| `NPS_Score__c` | NPS Score | double | |
| `CSAT__c` | CSAT | double | |
| `Last_Revenue_Date__c` | Last Revenue Date | date | |

#### Activity & Engagement Fields
| API Name | Label | Type |
|----------|-------|------|
| `Activity_Meeting_Count__c` | Activity Meeting Count | double |
| `Activity_Demo_Count__c` | Activity Demo Count | double |
| `Activity_Email_Count__c` | Activity Email Count | double |
| `Activity_call_Count__c` | Activity call Count | double |
| `Total_activity__c` | Total activity | double (FORMULA) |
| `Contact_create_this_quarter__c` | Contact create this quarter | double |
| `Contact_update_this_quarter__c` | Contact update this quarter | double |
| `Last_Activity__c` | Last Activity | date |

#### Industry & Vertical Fields
| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Nature_of_Business_Category__c` | Vertical | picklist | BPO, IT/ITES, SaaS, Consumer Internet, Healthcare, Travel & Hospitality, Financial Services, Education, Automotives, Consulting Services, Telecommunications, Other |
| `Nature_of_Business_Sub_category__c` | Sub Vertical | picklist | 65 values |
| `Cohort_Industry__c` | Cohort-Industry | string | |
| `Cohort_Size__c` | Cohort-Size | string | |
| `LinkedIn_Industry__c` | LinkedIn Industry | picklist | |

#### People & Ownership Lookups
| API Name | Label | Lookup To |
|----------|-------|-----------|
| `OwnerId` | Owner (AD) | User |
| `Account_CSM__c` | Account CSM | User |
| `Sales_Engineer__c` | Sales Engineer | User |
| `Researcher_Name__c` | Researcher Name | User |
| `ParentId` | Parent Account | Account |
| `Finance_Contact__c` | Finance | Contact |
| `Legal_contact__c` | Legal | Contact |
| `Legal_SPOC__c` | Legal SPOC | Contact |
| `Compliance_InfoSec_Contact__c` | Compliance/InfoSec | Contact |
| `IT_Operations_Contact__c` | IT & Operations | Contact |
| `Procurement_Contact__c` | Procurement | Contact |
| `Sales_and_Marketing_Contact__c` | Sales and Marketing | Contact |
| `AMC_Service_Contract__c` | AMC Service Contract | ServiceContract |

#### Account Sizing & Enrichment Fields
| API Name | Label | Type |
|----------|-------|------|
| `Annual_Revenue__c` | Annual Revenue | picklist |
| `Number_of_Employees__c` | Number of Employees | picklist |
| `LinkedIn_No_of_Employees__c` | LinkedIn No of Employees | double |
| `Total_Funding_Amount__c` | Total Funding Amount ($) | double |
| `Last_Funding_Amount__c` | Last Funding Amount ($) | double |
| `Last_Funding_Date__c` | Last Funding Date | date |
| `Is_Funded__c` | Is Funded | boolean (FORMULA) |
| `Seats_Count__c` | Seats Count | double |
| `Support_Ticket_Inflow__c` | Support Ticket Inflow | double |

#### Account Flags
| API Name | Label | Type |
|----------|-------|------|
| `Top_Customer__c` | Top Customer | boolean |
| `Is_ABM__c` | Is ABM | boolean |
| `Is_Compass_Only__c` | Is Compass Only | boolean |
| `Is_SAAS_Premium_Account__c` | Is SAAS Premium Account | boolean |
| `SAAS_Enterprise_Account__c` | SAAS Enterprise Account | boolean |
| `Strategic_Alliance__c` | Strategic Alliance | boolean |

#### Support & Operations Fields
| API Name | Label | Type |
|----------|-------|------|
| `Support_Group__c` | Support Group | picklist |
| `Cogno_Support_Group__c` | Cogno Support Group | picklist |
| `APC_Team_Type__c` | APC Team Type | picklist |
| `Hypercare_active__c` | Hypercare active | picklist |
| `Hypercare_Start_Date__c` | Hypercare Start Date | datetime |
| `Hypercare_End_Date__c` | Hypercare End Date | datetime |
| `MQA__c` | MQA | picklist |
| `Reconcile__c` | Reconcile | picklist |

#### Partner Fields
| API Name | Label | Type |
|----------|-------|------|
| `Partner_Type__c` | Partner Type | picklist |
| `Partner_Stages__c` | Partner Stages | picklist |

---

### Target__c Object (46 fields total, 33 custom)

Used for per-user GP/Revenue/OB targets. Key structure:

| API Name | Label | Type | Notes |
|----------|-------|------|-------|
| `Sale_Person_Name__c` | Sale Person Name | reference | Lookup to User |
| `Year__c` | Year | string | e.g., "2026" |
| `Quarter__c` | Quarter | double | 1-4 |
| `Quarter_FY__c` | Quarter_FY | date | |
| `Target_Type__c` | Target Type | picklist | Net New, Non recurring, Norm. Order Booking, Recurring, Revenue, Up Sell, GP |
| `Deal_Classification__c` | Deal Classification | picklist | Hunting, Farming |
| `Achievement__c` | Achievement | picklist | Recurring, Non Recurring |
| `Currency__c` | Currency | picklist | INR, USD |
| `IS_Target_Type__c` | IS Target Type | picklist | SAL, Meeting, QC, Demo |
| `BVT__c` | BVT | double | Budget/Value/Target amount |
| `GP__c` | GP | double | Gross profit target |
| `Rental_Base_M1__c` | Rental Base M1 | double | Monthly rental base (month 1 of quarter) |
| `Rental_Base_M2__c` | Rental Base M2 | double | Monthly rental base (month 2) |
| `Rental_Base_M3__c` | Rental Base M3 | double | Monthly rental base (month 3) |
| `AMC_Base_M1__c` | AMC Base M1 | double | AMC base (month 1) |
| `AMC_Base_M2__c` | AMC Base M2 | double | AMC base (month 2) |
| `AMC_Base_M3__c` | AMC Base M3 | double | AMC base (month 3) |
| `NRR_M1__c` through `NRR_M3__c` | NRR M1-M3 | double | NRR targets per month |
| `NRR__c` | NRR | double | FORMULA (sum of M1+M2+M3) |
| `Last_Year_Base__c` | Last Year Base | double | |
| `Hunting__c` | Hunting | double | FORMULA |
| `RR__c` | RR | double | FORMULA |
| `My_Targets__c` | My Targets | double | FORMULA |
| `Incentive_Bracket__c` | Incentive Bracket | double | |
| `Additional_Incentive__c` | Additional Incentive | double | |
| `Sales_Person_BU__c` | Sales Person BU | string | FORMULA |
| `Sales_Person_Cluster__c` | Sales Person Cluster | string | FORMULA |
| `Sales_Person_Profile__c` | Sales_Person_Profile | string | FORMULA |
| `Business_Unit__c` | Business Unit | string | |

---

### Case Object (Support Tickets) — 385 custom fields, 433 total

Already documented above in "Key Salesforce Objects & Fields > Case". Additional fields from full audit:

#### Approval & Workflow Fields
- `Approved_Reject_Date__c` (datetime), `Approved_Rejected_By__c` (ref->User), `Approved_Rejected_By_Name__c` (string)
- `CAB_Approval__c` (boolean), `Is_CAB_Approval_Required__c` (boolean) — Change Advisory Board
- `Commercial_Approval_for_CM__c` (boolean), `Is_Commercial_Required__c` (boolean)

#### Account & Setup Context
- `AI_Accounts__c` (ref->Account), `Account_Details__c` (ref->Account), `Parent_Account__c` (ref->Account), `Setup_Account__c` (ref->Account), `Tenant_Account__c` (ref->Account)
- `Account_SID__c` (string) — Exotel platform Account SID
- `Customer_Account_Sid__c` (string) — Customer's Account SID
- `Setup_Type__c` (picklist), `Setup__c` (multipicklist), `Setups_Name__c` (textarea)
- `Setup_AMC_Type__c`, `Setup_Product__c` — Setup-level context

#### Timing & SLA Fields
- `Assignment_Time__c`, `Classification_Time__c`, `DRI_Support_AssignTime__c`, `Digital_Voice_LP_AssignTime__c`, `Sprinklr_AssignTime__c`, `Tech_Support_AssignTime__c` — Team handoff timestamps
- `First_Response_Time__c`, `First_Resolution_Time__c`, `Resolution_Time__c`, `L4_Resolution_Date_time__c`, `Ticket_Resolution_Time__c`
- `Entitlement_Start_Date_Time__c`, `Turn_Around_Time__c`, `PS_Target_Date__c`
- `Total_Pending_min__c`, `Total_open_time__c`, `CP_Time__c`, `Working_Hours__c`
- `Ticket_Start_time__c`, `Ticket_End_time__c`, `Ticket_Close_Time__c`
- `Availability_Start_Time__c`, `Availability_End_Time__c` (with IST variants)

#### Escalation Chain
- `First_Escalation_ticket_owner__c` through `Fourth_Escalation_ticket_owner__c` (ref->User)
- `First_Escalation_time__c` through `Fourth_Escalation_time__c` (datetime)
- `Escalation_Description__c`, `Escalation_Closer_Type__c`, `Is_Escalation_Valid__c`

#### Delivery/Services Fields (for Service Delivery record type)
- `Delivery_Date__c`, `Delivery_est__c`, `Delivery_Dependency__c`, `DeliveryTicket_Age__c`
- `Deployment_Date__c`, `Deployment_Week__c`, `Deployment_Plan_Revision_Date_Time__c`
- `Deployment_Consultancy_Iteration_Count__c`, `SOW_Iteration_Count__c`, `SOW_Shared_By__c`
- `Consultancy_*_Efforts__c` (6 fields: Delivery, Task, Plan, SignOff, Sync, UAT)
- `Service_Delivery_*_Task_Efforts__c` (5 fields: Deploy, Design, Local Test, Signoff, UAT)
- `Scoping_Efforts__c`, `Scoping_Phase_completed__c`, `Scoping_Handover_Failure__c`
- `Estimated_Efforts_Hr__c`, `Estimated_Efforts__c`, `Time_Tracking_Efforts__c`
- `Engineer_Count__c`, `Patch_Version__c`, `Git_Path__c`

#### Quality & RCA Fields
- `Quality_Issue_Category__c`, `Quality_Issue_Sub_Category__c`, `Quality_RCA_Category__c`, `Quality_RCA_Issue_type__c`, `Quality_RCA_Sub_Category__c`
- `RCA_Category__c`, `RCA_Issuetype__c`, `RCA_Sub_category__c`
- `Failure_Disposition__c`, `Learning__c`, `What_was_the_issue__c`, `What_is_the_preventive_action__c`

#### Shift & Time Tracking
- `create_at_shift__c`, `Moved_at_shift__c`, `Resolved_at_shift__c`, `Update_at_shift__c`
- `On_Going_Shift__c`, `Ticket_Creation_Shift__c`, `Ticket_Closure_Shift__c`
- `Business_Hour_Range__c`

#### Jira Integration
- `Is_Jira_Escalated__c`, `JIRA_Escalated_Date__c`, `Jira_Ticket_Key__c`, `Jira_Ticket_Priority__c`
- `Jira_Issue_Type__c`, `Jira_Url__c`, `Jira_Check__c`, `Reopen_Jira_Issue__c`
- `Jira_create_log_Response__c`, `Jira_Reopen_log_Response__c`, `Source_of_Jira_Ticket__c`

#### Billing & Commercial
- `Accounts_Billing__c` (picklist), `Billing_Closure__c` (boolean)
- `Is_Chargeable__c` (boolean), `Invoice__c` (string)

#### Product/Platform Context
- `Product_Type__c` (picklist), `Product_SKU__c` (picklist), `Product_Type_AI__c` (picklist)
- `SKU__c` (multipicklist), `Console_Version__c`, `ReleaseVersion__c`
- `Environment__c` — UAT, Production
- `IVR_ID__c`, `BlasterPhoneNumber__c`
- `CRM_3rd_Party__c` (multipicklist), `PBX_Integration__c` (multipicklist)
- `ECC_Termination__c` (multipicklist) — Off-boarding actions

#### Ticket Reopening
- `Is_Re_open_Ticket__c` (boolean), `Reopen_Date__c` (datetime), `Reopen_Day__c` (string)
- `Ticket_Reopen_Count__c` (number), `Ticket_Resolved_Count__c` (number)

#### CognoAI-Specific
- `Cogno_Issue_Category__c`, `Cogno_Services__c`, `Cogno_Sub_Category__c`, `Cogno_Support_Group__c`

#### Change Management
- `CM_Phase__c` — Initiation, Planning, Scheduling, Execution, Monitoring
- `CM_Resolution_Level__c`, `CM_SLA_check__c`
- `Change_Type__c`, `Post_Change_Checks__c`, `Post_Change_Documentation__c`

#### SAAS/Platform
- `SAAS_Team_Ownership__c`, `SAAS_Team1__c`, `SAAS_Night_Ticket__c`, `SAAS_Enterprise_Account__c`
- `Is_SAAS_Parked__c`, `SAAS_Parked_Ticket_Resolution_Date__c`
- `IS_APC_Parked__c`, `APC_Parked_Ticket_Resolution_Date__c`
- `APC_TL_Owner1__c`, `APC_PO__c`, `APC_SO__c`

#### Misc
- `Calendly_UUID__c`, `ClickUp_Task_link__c`, `DCS_ID__c`, `DCS_Ticket_Number__c`
- `EPIC_ID__c` (url) — Jira EPIC link
- `Round_Robin_ID__c`, `Monitoring__c` (boolean), `Internal_Churn_assessment_Done__c` (boolean)
- `Whatsapp_templete_ID__c`, `check_for_whatsapp__c`, `whatsapp_csat__c` — WhatsApp CSAT

---

### Event Object (Meetings) — 72 custom fields, 124 total

Used for Meetings tracking in Powerplay and Mgmt Dashboard.

#### Meeting Classification
- `Meeting_Type__c` (picklist) — Demo, Discovery, QBR, Onboarding, etc.
- `Meeting_Category__c` (picklist) — External, Internal
- `Meeting_Outcome__c` (picklist, label "Opportunity Status") — Meeting outcome
- `Meeting_Attended__c` (boolean) — Whether meeting happened
- `New_Meeting__c` (boolean) — Flag for new meeting
- `Was_Expected_Outcome_Achieved__c` (picklist) — Expected Outcome Achieved?
- `Was_the_Decision_Maker_Present_on_the_Ca__c` (picklist) — Decision Maker's Presence

#### Meeting Content
- `Expected_Outcome__c` (textarea), `Achieved_Outcome__c` (textarea)
- `Briefing_Note__c` (textarea), `MOM_Notes__c` (textarea), `Note__c` (textarea)
- `Description__c` (string)

#### Account/Opportunity Context
- `Related_Account__c` (ref->Account), `Opportunity__c` (ref->Opportunity), `Related_Lead__c` (ref->Lead)
- `Decision_Maker_s_Name__c` (ref->Contact)
- `Region__c` (string), `Cluster__c` (string), `Business_Unit__c` (string)
- `B2_Account_stage__c` (string), `Task_Account_NoB__c` (string)

#### Effort Tracking
- `Actual_Efforts__c` (double), `TL_Actual_Efforts_Hr__c` (double, label "Planned Efforts")
- `TL_Updated_Actual_Efforts_Hr__c` (double)

#### Timing
- `Start_Date__c` (datetime), `Completion_Time__c` (datetime), `Due_Date_Time__c` (datetime)
- `Created_Date__c` (datetime), `Actual_Created_Date__c` (datetime), `Stage_Change_Date__c` (date)

#### Disposition (SDR/Inside Sales)
- `Call_Disposition__c` (picklist), `Call_Type__c` (picklist)
- `Disposition_Type__c` (string), `Sub_Disposition_Type__c` (string), `Sub_Disposition__c` (picklist)

#### Exotel CTI Integration (13 fields)
- `Exotel_CTI__Call_Direction__c`, `Exotel_CTI__Call_Duration__c`, `Exotel_CTI__Call_Sid__c`
- `Exotel_CTI__Call_Status__c`, `Exotel_CTI__From__c`, `Exotel_CTI__To__c`
- `Exotel_CTI__Recording_URL__c`, `Exotel_CTI__Virtual_Number__c`
- `Exotel_CTI__Start_Time__c`, `Exotel_CTI__End_Time__c`
- `Exotel_CTI__Leg1_Status__c`, `Exotel_CTI__Leg2_Status__c`, `Exotel_CTI__Test_Package__c`

#### Recording & AI
- `Recording_Link__c` (url), `recording_url__c` (url), `Transcript_Link__c` (url)

#### Review Fields
- `Review_Of__c` (ref->User), `Review_Type__c` (picklist), `Code_Rating__c` (picklist)
- `QBR_Document_Uploaded__c` (boolean)

#### Intent Data (Bombora/6sense)
- `Intent_Level__c` (string), `Engagement_Level__c` (string)
- `Latest_Intent_Level__c` (textarea), `Latest_Intent_Topics__c` (textarea), `Latest_Intent_Country__c` (string)
- `X4_Weeks_Intent_Country__c` (string)

#### SDR/Lead Context
- `Cluster_from_Lead__c` (string), `Product_Interest__c` (string), `Researcher_Name__c` (string)

#### Other
- `Status__c` (picklist), `Unique_Assignee__c` (boolean), `UserEmail__c` (string)
- `CrtObjectId__c` (string), `NAME_ID__c` (string), `Created_by_Custom_field__c` (string)
- `LID__Date_Sent__c` (datetime) — LinkedIn integration

---

### Task Object — 72 custom fields, 116 total

Task has the exact same 72 custom fields as Event (shared Activity object model in Salesforce). All fields documented under Event above apply identically to Task.

---

### Accounts_Revenue__c — 39 custom fields, 52 total

#### Revenue Fields
- `Revenue_Booked_Amount__c` (double, label "Reported Rev Amount") — PRIMARY revenue metric
- `Revenue_Booked_On__c` (date) — Revenue recognition date
- `Norm_Rev_Amount__c` (double) — Normalized revenue amount
- `Total_Rev_break_Amount__c` (currency) — Revenue break amount
- `Revenue_Classification__c` (picklist)

#### Cost & Profit Fields
- `GP__c` (double) — Gross Profit
- `Fixed_Cost__c` (double), `Variable_Cost__c` (double), `Total_Cost__c` (double)

#### Product & Classification
- `SKU__c` (picklist), `Parent_SKU__c` (picklist), `Derived_ParentSKU__c` (string)
- `Products__c` (picklist), `Product_Type__c` (picklist)
- `Classification__c` (picklist), `Revenue_Attribution__c` (picklist), `AOP_Category__c` (picklist)
- `Rev_Source__c` (picklist), `Rev_Sub_Source__c` (picklist)

#### Account & Geography
- `Account__c` (ref->Account, label "Setup-Tenant Account"), `Customer_Universal_Account__c` (ref->Account)
- `Customer_Name__c` (string), `Cluster__c` (picklist), `Region__c` (picklist)
- `Account_Region__c` (string), `Account_Geography__c` (string)
- `Universal_Acc_Cluster__c`, `Universal_Acc_AM__c`, `Universal_Acc_CSM_Name__c`, `Universal_Acc_CSM_cluster__c`

#### People
- `Account_Manager__c` (ref->User), `CSM__c` (ref->User)

#### Currency & IDs
- `Currency__c` (picklist), `Comment__c` (textarea)
- `Long_ID__c`, `Account_Revenue_Long_ID__c`, `Associated_Setup_Long_ID__c` — Dedup/integration IDs
- `ISQL_Accepted_Date__c` (date)
- `Revenue_Booked_Month_for_Tableau__c` (textarea) — Tableau integration helper

---

### Custom Objects Inventory (75 total)

#### Core Business Objects
- `Accounts_Revenue__c` — Revenue recognition records (39 custom fields)
- `Target__c` — Sales targets/quotas (33 custom fields)
- `SDF__c` — Sales Deal Form / commercial proposals (164 custom fields)
- `SDF_Line_Item__c` — SDF line items with SKU/pricing (29 custom fields)
- `Opportunity_Trend__c` — Opportunity snapshots for pipeline trending (44 custom fields)
- `Deal_Desk__c` — Deal desk approval workflow (21 custom fields)
- `Payment__c` — Payment milestones linked to SDF (11 custom fields)

#### Support & Delivery Objects
- `PreSalesCase__c` — Pre-sales technical cases (36 custom fields)
- `Solutions_architecture_case__c` — Solutions architecture requests (4 custom fields)
- `Support_Quality__c` — Quality audit scorecards for support/delivery (67 custom fields)
- `Survey__c` — Customer satisfaction surveys linked to Cases (40 custom fields)
- `Ticket_Movement__c` — Case ownership/queue movement tracking (3 custom fields)
- `Daily_Task__c` — Internal task management linked to Cases (26 custom fields)
- `Timesheet__c` — Time tracking linked to Daily_Task__c (4 custom fields)

#### Operations Objects
- `AMC__c` — Annual Maintenance Contract records (9 custom fields)
- `Legal_Tickets__c` — Legal review tickets for deals (18 custom fields)
- `Program__c` — Project/program management (12 custom fields)
- `SaaS_Daily_Usage__c` — Daily SaaS usage metrics per tenant (12 custom fields)
- `Veeno_KYC__c` — KYC document management (42 custom fields)
- `Sales_Feedback__c` — Sales feedback tied to Opportunities (12 custom fields)
- `CallDetails__c` — CTI call detail records (15 custom fields)
- `Integration_Log__c` — API integration logs (17 custom fields)
- `QBR__c` — Quarterly Business Review notes (4 custom fields)

#### Reference/Config Objects
- `Region__c`, `Country__c`, `State__c`, `City__c`, `Location__c` — Geographic hierarchy
- `Customer__c`, `Consultant__c`, `Partner__c` — Entity references
- `Package__c` — Package definitions (0 custom fields)
- `Custom_Quote__c`, `Document__c`, `Setup__c` — Document/config management
- `Org_Static_Values__c`, `Static_Values_Settings__c` — Org-wide config
- `Account_Creation_Request__c`, `Account_Related_Program__c`, `Opp_Related_Programs__c` — Junction/request objects
- `Assignment_Group__c`, `Assignment_Group_Member__c` — Case assignment rules
- `In_App_Checklist_Settings__c`, `Review_Notes__c` — UX/process objects
- `CaseComment__c`, `Agent_Type__c` — Support config

#### Managed Package Objects (not queryable for business data)
- `Exotel_CTI__*` — Exotel CTI integration
- `LID__*` — LinkedIn integration
- `lightningbuddy__*` — Lightning Buddy
- `pi__*` — Pardot/Marketing Cloud
- `replyapp__*` — Reply.io integration
- `SpotDraftManage__*` — SpotDraft contract management
- `sbaa__*`, `SBQQ__*` — Salesforce CPQ

---

### SDF__c (Sales Deal Form) — 164 custom fields

Large commercial document object. Key fields:

#### Commercial
- `Amount__c`, `Gross_Amount__c`, `Net_Amount__c`, `Total_Gross_AMount__c`, `Total_Net_Amount__c`, `Total_OB__c`
- `MRR_Amount_New__c`, `One_Time_Amount_New__c`, `Full_Pot_MRR__c`
- `OB_Attribution__c`, `RD_Net_Amount__c`, `RD_Hunting__c`, `RD_NRR__c`, `RD_RR__c`
- `Customization_Cost__c`, `Installation_Cost__c`, `Hardware__c`, `PS_Services__c`, `CPass__c`
- `AMC__c`, `AMC_Type__c`, `Advance_Amount__c`
- `Taxes__c`, `Cal_Tax__c`, `Calculate_Tax__c`, `Calculate_Tax1__c`
- `Sales_Hunting__c`, `Sales_NRR__c`, `Sales_RR__c`
- `Currency__c`, `Seats_Count__c`

#### Relationships
- `Account__c` (ref->Account), `Opportunity__c` (ref->Opportunity), `Target__c` (ref->Target__c)
- `Customer_Name__c` (ref->Customer__c), `Partner__c` (ref->Partner__c), `Location__c` (ref->Location__c)
- `Primary_Custom_Quote__c` (ref->Custom_Quote__c), `Consultants__c` (ref->Consultant__c)
- `Account_Managers__c` (ref->User), `PreSales_Person__c` (ref->User), `Solution_designer__c` (ref->User)

#### Contact Info (Commercial, Owner, Technical contacts)
- `CommercialName__c`, `CommercialEmail__c`, `CommercialMobile__c`, `Commercial_Contact__c`
- `OwnerName__c`, `OwnerEmail__c`, `OwnerMobile__c`, `Owner_Contact__c`
- `Technical_Name__c`, `TechnicalEmail__c`, `TechnicalMobile__c`, `Technical_Contact__c`

#### Status & Classification
- `Approval_Status__c` (picklist), `SDF_Status__c` (picklist)
- `Deal_Type__c` (picklist), `Component_Classification__c` (picklist), `Component_Sub_Classification__c` (picklist)
- `Revenue_Classification__c`, `Sales_Classification__c`, `Deal_Classification__c`
- `Reversal_Type__c` (picklist), `Reversal_Date__c` (date)
- `SKU__c` (picklist), `Product__c` (picklist), `Is_POC__c` (picklist)
- `SDF_Approval_Date__c`, `Business_Deal_Date__c`
- `Milestone__c`, `MSA_Signed__c`, `KYC_Done__c`, `Credit_Approval_Done__c`, `Price_Approved__c`

#### Billing Address
- Full billing + shipping address fields (Street, City, State, Country, Postal Code, GST Number)

#### Delivery
- `Expected_Go_Live_Date__c`, `Engineering_Level__c`, `Engineering_Onsite_Mandays__c`, `Engineering_Offsite_Mandays__c`
- `Project_Delivery__c`, `Project_Manager_Level__c`, `PM_Mandays__c`
- `Tech_team__c`, `Consultant__c`

---

### SDF_Line_Item__c — 29 custom fields

- `SDF__c` (ref->SDF__c) — Parent SDF
- `Product__c` (picklist), `SKU__c` (picklist), `SDF_Line_Item_SKU__c` (string)
- `Gross_Amount__c`, `Net_Amount__c`, `OB_Amount__c`, `Taxes__c`, `Cal_Tax__c`, `Consumption__c`
- `Component_Classification__c`, `Component_Sub__c`, `Solutions_Closed__c` (multipicklist)
- `Use_Case__c` (multipicklist), `Particulars__c` (textarea), `Units__c` (string)
- `Revenue_Category_One_Time__c`, `OB_Attributed__c`, `ob_attribution_multiplier__c`
- `MIS_OB__c`, `Rev_Product_Identifier__c`, `CRM_SD_Name__c`
- `License_Sub_Type__c`, `AMC_Type__c`, `SD_Line_Flag__c`
- `SDF_Cluster__c`, `sdf_Status__c`, `DCS_Ticket_Number_c__c`, `Calculate_Tax__c`

---

### Opportunity_Trend__c — 44 custom fields

Snapshot/trending object for pipeline analysis:
- `Opportunity__c` (ref->Opportunity), `Account__c` (ref->Account)
- `Trend_Date__c` (date) — Snapshot date
- `Stage__c`, `Net_New_INR__c`, `Net_New_INR_formula__c`, `Normalise_Amount_INR__c`, `Normalise_Amount__c`
- `MRR_Amount__c`, `One_Time_Amount__c`, `Count__c`
- `Classification_Type__c`, `Deal_Type__c`, `Forecast_Category__c`, `Lead_Source__c`
- `B_Deal_Date__c`, `Close_Date__c`, `Expected_Close_Date__c`
- `Region__c`, `Cluster__c`, `Account_Cluster__c`, `Account_Region__c`
- `SKU__c`, `Type__c`, `Use_Case__c`, `Reversal_Typ__c`
- `Open_Funnel_Marker__c` (boolean)
- Various Long ID and formula fields for Tableau

---

### Support_Quality__c — 67 custom fields

Quality audit scorecard for support and delivery:
- `Delivery_Ticket_Number__c` (ref->Case) — Linked support ticket
- `Call_Created_Date__c`, `Close_Date__c`, `Call_Created_Week__c`, `Call_Duration__c`, `Call_Details__c`

**Support Quality Metrics** (all picklist, typically 1-5 scale):
- Communication: `Call_Opening__c`, `Active_Listening__c`, `Proper_Questioning__c`, `Info_Gathering__c`, `Empathy__c`, `Confidence__c`, `Positive_Language__c`, `Professionalism__c`, `Proper_Closing__c`, `Proper_Sentence_Formation__c`, `Signposting__c`, `Reassurance__c`, `Interruption__c`, `Call_control__c`, `Explanation_Solution__c`
- Technical: `First_Response_Content__c`, `First_Response_Notes__c`, `FRT_SLA__c`, `Resolution_SLA__c`, `Ticket_Prioritization__c`, `Issues_Category_and_Sub_category__c`, `RCA_category_and_sub_category__c`, `Closure_Notes_RCA_format_for_critical__c`, `Documentation__c`, `Google_Sites_Updated__c`
- Delivery: `Feasibility_done_within_timelines__c`, `Deloyment_Plan_Shared_Within_Timeline__c`, `Designing_completed_on_Time__c`, `Testing_completed_within_timelines__c`, `Implementation_done_within_timelines__c`, `Feature_tested_successfully_in_first_att__c`, `GIT_checkin_done__c`, `Training_given_to_customer__c`, `UAT_completed__c`, `UAT_test_cases_shared__c`, `Test_cases_shared_with_customer__c`
- Fatal flags: `Fatal_Hold_Negligence__c`, `Fatal_Reply_after_48_hours__c`, `Fatal_Google_Site_48_Hours_Reply__c`, `Fatal_Engineer_Behaviour__c`, `Fatal_Escalation_due_to_deployment__c`, `Fatal_Scope_revision_3__c`, `Fatal_Correct_Customer_Name_in_Test_Case__c`
- SOW: `SOW_TAT_shared__c`, `SOW_TAT_within_timeline__c`, `SOW_Revision_3__c`
- Scores: `Overall_Call_Quality__c` (%), `Overall_Quality__c` (%), `APC_OverallQuality__c` (%), `Services_Overall_Quality__c` (%), `Avg_First_Interaction__c` (%), `Avg_Resolution__c` (%), `Avg_Ticket_Handling__c` (%)

---

### Survey__c — 40 custom fields

Customer satisfaction survey linked to Cases:
- `CaseNumber__c` (ref->Case), `Account_Details__c` (ref->Account), `Solutions_architecture_case__c` (ref->Solutions_architecture_case__c)
- `CaseID__c`, `CaseRecordType__c`, `Case_RecordType__c`, `Case_Created_By__c`, `Case_Resolved__c`, `Case_Resoved_By__c`
- `Case_Owner_Email__c`, `Case_Owner_Email1__c`
- **Ratings** (all double, 1-5): `Overall_Experience__c`, `Quality_of_communication__c`, `technical_support__c`, `SA_team_time_commitments__c`, `Solution_Desigining_experience__c`, `suitability_of_the_proposed_solution__c`, `experience_with_deployment_engineers__c`, `requirement_documentation_Rating__c`, `scoping_Rating__c`, `Suffecient_time_provided_Rate__c`, `resource_was_knowledgable__c`, `Delivery_Rating__c`
- **Composite scores**: `Feedback_status__c`, `Overall_feedback_Status__c`, `Delivery_feedback_status__c`, `Services_feedback_status__c` (label "Scoping feedback status"), `Delivery_or_Overall_Status__c`, `Delivery_or_Scoping_or_Overall_Status__c`, `Scoping_or_Overall__c`, `Scoping_or_Delivery_Feedback_Status__c`
- `Feedback_comment__c` (textarea), `Description__c` (textarea), `Source__c` (picklist)

---

### Other Notable Custom Objects

#### AMC__c (Annual Maintenance Contract) — 9 custom fields
- `AMC_Value__c` (currency), `AMC_Support_Type__c` (picklist), `Validity__c` (picklist)
- `Grace_Period__c` (date), `Periodically_Expiry_date__c` (date), `Renewal_Frequency__c` (string)
- `Currency__c` (picklist), `Notification_Status__c` (picklist), `Description__c` (textarea)

#### Legal_Tickets__c — 18 custom fields
- `Account__c` (ref->Account), `Opportunity__c` (ref->Opportunity)
- `Status__c` (picklist), `Completion_Date__c` (date), `Ticket_Completion_Date__c` (datetime)
- `Legal_Ticket_Closed_Age__c` (double), `Drafts_Shared__c` (picklist)
- `Expected_MRR__c` (double), `One_Time_Amount__c` (double)
- `Region__c`, `Cluster__c`, `Type_of_Customer__c`, `Use_Case__c` (multipicklist)
- `Requestor_Name__c`, `Legal_entity_name__c`, `Legal_Team_comment__c`, `Sales_Comments__c`

#### SaaS_Daily_Usage__c — 12 custom fields
- `Setup_Name__c` (ref->Account) — Tenant account
- `Log_Date__c` (date), `Login_Date__c` (datetime)
- `Total_Calls__c`, `Error_Calls__c`, `Failed_Calls__c` — Call volume metrics
- `Logged_In_Users__c`, `Configured_Users__c` — Agent utilization
- `Call_Per_Agent__c`, `Campaign_Number__c`
- `CC_Name__c`, `Setup_Host_Name__c`

#### Daily_Task__c — 26 custom fields
- `Ticket__c` (ref->Case), `Parent_Task__c` (ref->Daily_Task__c, self-referential)
- `Assign_to__c` (ref->User), `Observing_User__c` (ref->User)
- `Status__c`, `Priority__c`, `RAG_Status__c`, `Task_Category__c`, `Type__c`, `Sub_Type__c`
- `Start_Date__c`, `End_Date__c`, `Expected_Close_Date__c`, `Plan_Closer_Date__c`
- `Estimated_Hours__c` (label "Estimated Minutes"), `Actual_Hours__c` (label "Actual Minutes"), `Estimated_effort_hours__c`
- `Task_Accepeted__c` (picklist), `Team__c` (multipicklist), `Remarks__c`, `Description__c`

#### PreSalesCase__c — 36 custom fields
- `Opportunity__c` (ref->Opportunity), `Lead__c` (ref->Lead)
- `Owner1__c`, `Owner2__c` (ref->User), `Created_By__c` (ref->User)
- `Owner1_Efforts__c`, `Owner2_Efforts__c` — Effort tracking
- `Ticket_Status__c`, `Ticket_Priority__c`, `Document_Type__c`, `Industry_vertical__c`, `Region__c`
- `Product__c` (multipicklist), `Setup__c` (multipicklist), `Customer_Use_Case__c` (multipicklist)
- `Competition__c` (multipicklist), `PBX_Integration__c` (multipicklist), `CRM_3rd_Party__c` (multipicklist)
- `Number_of_Seats__c`, `Description__c`, `PreSales_Description__c`, `Sales_Description__c`

#### Deal_Desk__c — 21 custom fields
- `Opportunity__c` (ref->Opportunity), `Account_Name__c` (ref->Account)
- `Status_2__c` (picklist), `SKUs__c` (multipicklist)
- `Deal_has_commit_for__c`, `Why_Opportunity_is_raised_to_deal_desk__c`, `Proposal_is_with_slab_based_pricing__c`
- `Opportunity_Size_in_INR_Lakhs_in_MRR__c`, `Proposed_Pricing_that_needs_to_be_approv__c`

#### Ticket_Movement__c — 3 custom fields
- `Ticket__c` (ref->Case), `Movement_Date__c` (datetime), `Movement_Type__c` (picklist)

#### CallDetails__c — 15 custom fields
- `callId__c`, `campaignId__c`, `LeadId__c`, `objectId__c`, `objectType__c`, `userId__c`
- `dialedNumber__c`, `systemDisposition__c`, `dispositionClass__c`, `dispositionCode__c`
- `Call_Duration__c`, `recordingFileUrl__c`, `subject__c`, `comment__c`, `customerCRTId__c`

#### Integration_Log__c — 17 custom fields
- `Lead__c` (ref->Lead), `SDF__c` (ref->SDF__c), `SDF_Line_Item__c` (ref->SDF_Line_Item__c), `Ticket_Number__c` (ref->Case)
- `Action__c`, `Request_From__c`, `Request_Method__c`, `End_Points__c`
- `Request_Body__c`, `Response_Body__c`, `Response_Status_Code__c`, `Error_Code__c`, `Error_Message__c`
- `Is_error__c` (boolean), `Time_Out__c` (double), `Session_Id__c`, `SDF_CreatedBy__c`

#### Sales_Feedback__c — 12 custom fields
- `Opportunity__c` (ref->Opportunity), `Sales_Person__c` (ref->User), `Manager__c` (ref->User)
- `Rating__c` (double), `Feedback__c` (textarea), `Email_ID__c` (email)
- `X1st_attempt__c` through `X3rd_attempt_date__c` — Multi-attempt feedback collection

#### Program__c — 12 custom fields
- `Account__c` (ref->Account), `Assign_To__c` (ref->User), `Sponsor__c` (ref->User)
- `Parent_Program__c` (ref->Program__c, self-referential)
- `Status__c`, `Priority__c`, `Start_Date__c`, `End_Date__c`
- `Estimated_Hours__c`, `Actual_Hours__c`, `Description__c`, `Ne__c` (Comments)

#### Veeno_KYC__c — 42 custom fields
- `Opportunity__c` (ref->Opportunity), `Status__c` (picklist), `KYC_Type__c` (picklist)
- 38 document upload/ID fields for PAN, Incorporation cert, address proof, etc.
- `Rejection_Comments__c` (textarea)

---

## CRM Buddy Document Comparison (March 2026)

The CRM Buddy Document (`AI_Revenue_Controller.cls` + `CrmBuddy` LWC) uses BigQuery + Gemini for analytics. Its field-level mappings are stored dynamically in BigQuery tables (`AI_Schema_Registry`, `AI_Mapping_Dictionary`, `AI_Analytics_Rules`, etc.) — not in the document itself.

### Patterns imported from CRM Buddy into Ask Salesforce:

| # | Pattern | Source (CRM Buddy) | Status |
|---|---------|-------------------|--------|
| 1 | Personal vs org-wide detection ("my"/"I"/"me" → owner filter) | Lines 424-430, 529 | ✅ Imported to SOQL prompt |
| 2 | "No single number" mandate (always include dimensional breakdowns) | Lines 436-438 | ✅ Imported to SOQL prompt |
| 3 | Currency formatting (₹X.XX L for Lakhs, ₹X.XX Cr for Crores) | Line 544, 672-686 | ✅ Imported to Summary prompt |
| 4 | Pipeline aging thresholds (🔴>120d, 🟡60-120d, 🟢<60d) | Lines 721-731 | ✅ Imported to Summary prompt |
| 5 | Root cause analysis for "why" questions | Lines 854-871 | ✅ Imported to Summary prompt |
| 6 | Response scaling (micro vs macro questions) | Lines 546-550 | ✅ Imported to Summary prompt |
| 7 | Zero data graceful handling | Lines 566-573 | ✅ Imported to Summary prompt |
| 8 | Top/bottom performer indicators (🟢🔴) | Lines 540-541 | ✅ Imported to Summary prompt |

### Already aligned (no changes needed):

| # | Pattern | Notes |
|---|---------|-------|
| 1 | FY/Quarter rules (Apr-Mar, Q1-Q4) | Both systems use same definitions |
| 2 | Domain routing (Revenue vs Opportunity keywords) | Already in REVENUE DEFINITION section |
| 3 | Self-healing query retry | Both systems have retry loops |
| 4 | Chat history context | Both pass conversation context |
| 5 | Won stage = 'Order' | Consistent across both |

### Not imported (architectural differences):

| # | Pattern | Reason |
|---|---------|--------|
| 1 | Executive memory (stores insights in BigQuery) | Requires BigQuery infrastructure |
| 2 | Dynamic schema registry from BigQuery | We use hardcoded prompt (more reliable for SOQL) |
| 3 | Follow-up question suggestions | Requires LWC changes |
| 4 | HTML-only response format (no Markdown) | Our LWC renders Markdown correctly |
| 5 | 5-section analysis structure (☕🏆📉📊🧠) | Too prescriptive; our flexible format works better |

### Tableau Validation (March 2026)

All 10 CRM Buddy patterns above were **CONFIRMED** against actual Tableau metadata extracted via Metadata GraphQL API from 12 workbooks. The Tableau data validates:
- Revenue/GP fields match CRM Buddy's field references (Revenue_Booked_Amount__c, GP__c)
- Retention NRR/GRR calculation pattern (two-period comparison) matches Tableau Retention dashboard
- Penetration metrics (ACI/API/PPI/GPI) confirmed via Penetration Index workbook
- Target vs Actual patterns confirmed via Variance Analysis workbook (uses Accounts_Target__c, Booking_Target__c)
- 7 of 17 original dashboard mappings had deviations — now corrected with Tableau-validated sources
- 6 new SF objects discovered: Accounts_Target__c, Booking_Target__c, Program__c, Opp_Related_Programs__c, OB_to_Revenue__c, Lead_Backup__c
