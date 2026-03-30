{
  "version": 1,
  "description": "KPI execution registry. Each entry defines a deterministic KPI formula with exact SOQL templates, stage sets, date fields, and supported dimensions. Matched against Tableau Key KPIs dashboard formulas.",
  "kpis": [
    {
      "id": "WIN_RATE",
      "displayName": "Win Rate",
      "domain": "opportunity",
      "formulaType": "RATIO",
      "sourceType": "LIVE_SF_WITH_TABLEAU_SEMANTICS",
      "baseObject": "Opportunity",
      "questionTerms": ["win rate", "win %", "win percentage", "win-rate"],
      "numerator": {
        "label": "Won Deals",
        "measureField": "Amount",
        "measureFn": "SUM",
        "countField": "Id",
        "dateField": "B_Deal_Date__c",
        "stageFilter": ["Order"]
      },
      "denominator": {
        "label": "Consumed Pipeline",
        "measureField": "Amount",
        "measureFn": "SUM",
        "countField": "Id",
        "dateField": "CloseDate",
        "stageFilter": ["Order", "Negotiation", "Closed Lost", "Closed-No decision", "Closed Unknown", "Closed Duplicate", "Rejected", "SDF Rejected"]
      },
      "defaultDimension": "Account_Cluster__c",
      "supportedDimensions": {
        "cluster": "Account_Cluster__c",
        "region": "Account_Region__c",
        "owner": "Owner.Name",
        "sku": "SKU__c",
        "classification": "Classification_Type__c",
        "use case": "Use_Case__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "showBothValueAndCount": true,
      "interpretationNote": "Won uses B_Deal_Date__c (booking date). Consumed uses CloseDate. Matches Tableau Key KPIs dashboard."
    },
    {
      "id": "CONVERSION_RATE",
      "displayName": "Conversion Rate",
      "domain": "opportunity",
      "formulaType": "RATIO",
      "sourceType": "LIVE_SF_WITH_TABLEAU_SEMANTICS",
      "baseObject": "Opportunity",
      "questionTerms": ["conversion rate", "conversion ratio", "conversion %", "conversion percentage"],
      "numerator": {
        "label": "Closed/Won Deals",
        "measureField": "Amount",
        "measureFn": "SUM",
        "countField": "Id",
        "dateField": "B_Deal_Date__c",
        "stageFilter": ["Order"]
      },
      "denominator": {
        "label": "Total Opportunities",
        "measureField": "Amount",
        "measureFn": "SUM",
        "countField": "Id",
        "dateField": "CloseDate",
        "stageFilter": ["Order", "Suspect", "Approach", "Prospect", "Proposal", "Negotiation", "SDF Submission", "POC", "On Hold", "Closed won - Pending", "Closed Lost", "Closed-No decision", "Closed Unknown", "Closed Duplicate", "Rejected", "SDF Rejected", "POC Closed"]
      },
      "defaultDimension": "Account_Cluster__c",
      "supportedDimensions": {
        "cluster": "Account_Cluster__c",
        "region": "Account_Region__c",
        "owner": "Owner.Name",
        "sku": "SKU__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "showBothValueAndCount": true,
      "interpretationNote": "Conversion = Won / Total pipeline (all stages including open). Wider denominator than Win Rate."
    },
    {
      "id": "SALES_CYCLE_AVG",
      "displayName": "Average Sales Cycle",
      "domain": "opportunity",
      "formulaType": "AVERAGE",
      "sourceType": "LIVE_SF_WITH_TABLEAU_SEMANTICS",
      "baseObject": "Opportunity",
      "questionTerms": ["average sales cycle", "avg sales cycle", "mean sales cycle", "sales cycle average", "sales cycle"],
      "computation": {
        "label": "Sales Cycle (Days)",
        "startDateField": "ISQL_Accepted_Date__c",
        "endDateField": "B_Deal_Date__c",
        "stageFilter": ["Order"],
        "unit": "DAYS",
        "nullHandling": "EXCLUDE_NULL_DATES"
      },
      "defaultDimension": "Account_Cluster__c",
      "supportedDimensions": {
        "cluster": "Account_Cluster__c",
        "region": "Account_Region__c",
        "owner": "Owner.Name",
        "sku": "SKU__c",
        "classification": "Classification_Type__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "DAYS",
      "interpretationNote": "Sales Cycle = days from ISQL Accepted Date to B Deal Date. Only Order stage deals with both dates populated."
    },
    {
      "id": "SALES_CYCLE_MEDIAN",
      "displayName": "Median Sales Cycle",
      "domain": "opportunity",
      "formulaType": "MEDIAN",
      "sourceType": "LIVE_SF_WITH_TABLEAU_SEMANTICS",
      "baseObject": "Opportunity",
      "questionTerms": ["median sales cycle", "sales cycle median"],
      "computation": {
        "label": "Sales Cycle Median (Days)",
        "startDateField": "ISQL_Accepted_Date__c",
        "endDateField": "B_Deal_Date__c",
        "stageFilter": ["Order"],
        "unit": "DAYS",
        "nullHandling": "EXCLUDE_NULL_DATES",
        "maxDetailRows": 10000
      },
      "defaultDimension": "Account_Cluster__c",
      "supportedDimensions": {
        "cluster": "Account_Cluster__c",
        "region": "Account_Region__c",
        "owner": "Owner.Name"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "DAYS",
      "interpretationNote": "Median Sales Cycle = middle value when all sales cycles are sorted. More robust than average against outliers."
    },
    {
      "id": "NRR",
      "displayName": "Net Revenue Retention (NRR)",
      "domain": "revenue",
      "formulaType": "PERIOD_RATIO",
      "sourceType": "LIVE_SF",
      "baseObject": "accounts_revenue__c",
      "dateField": "Revenue_Booked_On__c",
      "measureField": "Revenue_Booked_Amount__c",
      "measureFn": "SUM",
      "questionTerms": ["nrr", "net revenue retention", "revenue retention"],
      "defaultDimension": "Customer_Universal_Account__r.Cluster__c",
      "supportedDimensions": {
        "cluster": "Customer_Universal_Account__r.Cluster__c",
        "region": "Customer_Universal_Account__r.Region__c",
        "sku": "Parent_SKU__c",
        "product": "Parent_SKU__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "interpretationNote": "NRR = Current period revenue / Previous period revenue × 100. Includes expansion/upsell. >100% = net growth, <100% = net contraction. Uses accounts_revenue__c."
    },
    {
      "id": "GRR",
      "displayName": "Gross Revenue Retention (GRR)",
      "domain": "revenue",
      "formulaType": "PERIOD_RATIO",
      "sourceType": "LIVE_SF",
      "baseObject": "accounts_revenue__c",
      "dateField": "Revenue_Booked_On__c",
      "measureField": "Revenue_Booked_Amount__c",
      "measureFn": "SUM",
      "questionTerms": ["grr", "gross revenue retention"],
      "extraFilters": "AND Revenue_Classification__c IN ('Retention2','Retention3')",
      "capNumerator": true,
      "defaultDimension": "Customer_Universal_Account__r.Cluster__c",
      "supportedDimensions": {
        "cluster": "Customer_Universal_Account__r.Cluster__c",
        "region": "Customer_Universal_Account__r.Region__c",
        "sku": "Parent_SKU__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "interpretationNote": "GRR = Current period revenue / Previous period revenue × 100, excluding expansion. Numerator capped at denominator (max 100%). Only Revenue_Classification = Retention2 or Retention3. Uses accounts_revenue__c."
    },
    {
      "id": "NRGP",
      "displayName": "Net Revenue Growth Percentage (NRGP)",
      "domain": "revenue",
      "formulaType": "PERIOD_RATIO",
      "sourceType": "LIVE_SF",
      "baseObject": "accounts_revenue__c",
      "dateField": "Revenue_Booked_On__c",
      "measureField": "GP__c",
      "measureFn": "SUM",
      "questionTerms": ["nrgp", "net revenue growth percentage", "net gp retention", "net gross profit retention", "net gpr", "gp retention"],
      "extraFilters": "AND Revenue_Classification__c IN ('Retention2','Retention3')",
      "defaultDimension": "Customer_Universal_Account__r.Cluster__c",
      "supportedDimensions": {
        "cluster": "Customer_Universal_Account__r.Cluster__c",
        "region": "Customer_Universal_Account__r.Region__c",
        "sku": "Parent_SKU__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "interpretationNote": "NRGP = Current period GP / Previous period GP × 100 (Retention2 + Retention3 only). Measures GP growth including expansion. >100% = net GP growth. Uses accounts_revenue__c GP__c field."
    },
    {
      "id": "GRGP",
      "displayName": "Gross Revenue Growth Percentage (GRGP)",
      "domain": "revenue",
      "formulaType": "PERIOD_RATIO",
      "sourceType": "LIVE_SF",
      "baseObject": "accounts_revenue__c",
      "dateField": "Revenue_Booked_On__c",
      "measureField": "GP__c",
      "measureFn": "SUM",
      "questionTerms": ["grgp", "gross revenue growth percentage", "gross gp retention", "gross gross profit retention", "gross gpr"],
      "extraFilters": "AND Revenue_Classification__c IN ('Retention2','Retention3')",
      "capNumerator": true,
      "defaultDimension": "Customer_Universal_Account__r.Cluster__c",
      "supportedDimensions": {
        "cluster": "Customer_Universal_Account__r.Cluster__c",
        "region": "Customer_Universal_Account__r.Region__c",
        "sku": "Parent_SKU__c"
      },
      "supportedTimeGrains": ["FY", "Q", "M"],
      "resultFormat": "PERCENT",
      "interpretationNote": "GRGP = Current period GP / Previous period GP × 100, excluding expansion (capped at 100%). Only Retention2 + Retention3. Uses accounts_revenue__c GP__c field."
    }
  ]
}
