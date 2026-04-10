/**
 * Main controller for the AI Sales Assistant LWC.
 * Orchestrates: User Question -> Claude (SOQL) -> Execute -> Claude (Summary) -> LWC
 */
public with sharing class AiSalesAssistantController {

    public class AssistantResponse {
        @AuraEnabled public String answer;
        @AuraEnabled public String soqlQuery;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Long executionTimeMs;
    }

    // Batch ID for stress test logging — set by StressTestRunner before calling askQuestion
    public static String currentBatchId;

    // Domain capability override for tests (same pattern as ClaudeApiService.testConfig)
    @TestVisible
    private static AskSF_Domain__mdt testDomainOverride;

    /**
     * Resolves the domain capability record for a given Salesforce object.
     * Uses AskSF_Domain__mdt custom metadata — queries are free (no SOQL limit cost).
     * Returns null if no domain is registered for this object.
     */
    @TestVisible
    private static AskSF_Domain__mdt resolveDomain(String objectName) {
        if (testDomainOverride != null) return testDomainOverride;
        if (String.isBlank(objectName)) return null;
        List<AskSF_Domain__mdt> domains = [
            SELECT DeveloperName, SourceType__c, Queryable__c, Parity__c,
                   PrimaryObject__c, ResponseMode__c, UserMessageTemplate__c,
                   AllowedMeasures__c, AllowedDimensions__c
            FROM AskSF_Domain__mdt
            WHERE PrimaryObject__c = :objectName
            ORDER BY SortOrder__c ASC NULLS LAST
            LIMIT 1
        ];
        return domains.isEmpty() ? null : domains[0];
    }

    // ── Structured Planner (revenue-only, behind feature flag) ──────────

    private static final String PLANNER_SYSTEM_PROMPT =
        'You are a query planner for Exotel/Ameyo\'s Salesforce org.\n' +
        'Your job is to convert a natural-language question into a structured JSON query plan.\n' +
        'Return ONLY valid JSON — no markdown, no explanation.\n\n' +
        '<domain_context>\n' +
        'Object: accounts_revenue__c\n' +
        'Primary date field: Revenue_Booked_On__c (Date type, format YYYY-MM-DD)\n' +
        'Allowed measures: Revenue_Booked_Amount__c, GP__c, Variable_Cost__c, Fixed_Cost__c, Total_Cost__c, Norm_Rev_Amount__c\n' +
        'Allowed dimensions: Customer_Universal_Account__r.Cluster__c, Customer_Universal_Account__r.Region__c, Parent_SKU__c, SKU__c, Product_Type__c, Classification__c, Revenue_Classification__c, Currency__c, Customer_Universal_Account__r.Name, Customer_Universal_Account__r.Owner.Name\n' +
        'Parent_SKU__c values: Voice, Contact Centre, SMS, Whatsapp, Truecaller, Gen AI — DEFAULT for "by SKU"/"by product" questions.\n' +
        'SKU__c values: PF Voice, PF Others, PF Messaging SMS, Enterprise CC, PF Messaging Whatsapp, PF Voice CC, PF Others TC, Conversational AI, Voice Streaming, Chatbot, CQA, Voicebot, PF Messaging Others, PF Messaging RCS, VSIP — only when user asks for detailed/sub-SKU.\n' +
        'Customer_Universal_Account__r.Cluster__c values: Africa, APAC, Banking and Insurance, BFSI & Strategic Large, Financial Services, FM Funded-I, FM Funded-II & Traditional-II, Internal, KSA, Marketplace, Mid Market, Mobility, Partnerships, Retail, Romena, Services, SMB, SME Funded, Technology, Traditional-I, UAE, US\n' +
        'Customer_Universal_Account__r.Region__c values: International, Scaleup, Domestic Enterprise\n' +
        'CRITICAL — Region vs Cluster disambiguation:\n' +
        '  "Scaleup"/"Scaleups"/"Scale" → filter on Customer_Universal_Account__r.Region__c = \'Scaleup\'.\n' +
        '  "Domestic"/"International" → filter on Customer_Universal_Account__r.Region__c.\n' +
        '  "BFSI"/"Retail"/"APAC"/"SME"/"Technology" etc. → filter on Customer_Universal_Account__r.Cluster__c.\n' +
        '  Region and Cluster have COMPLETELY DIFFERENT value sets. Never confuse them.\n' +
        'Revenue_Classification__c: Recurring, Non-Recurring\n' +
        'Classification__c: New Sales, Cross sell, Up sell, AMC Renewal\n' +
        'Currency__c values: INR, USD, AED\n' +
        '</domain_context>\n\n' +
        '<fiscal_rules>\n' +
        'Indian FY runs Apr-Mar. FY2025 = Apr 2025 - Mar 2026.\n' +
        'Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar.\n' +
        '"This year"/"current year" = current Indian FY (Apr 1 to today).\n' +
        'No date specified = current FY (Apr 1 to today).\n' +
        '</fiscal_rules>\n\n' +
        '<instructions>\n' +
        'Analyze the question and return a JSON plan.\n' +
        'If the question is NOT about revenue/GP/cost/margin from accounts_revenue__c, return:\n' +
        '{"domain":"not_revenue","reason":"brief explanation"}\n\n' +
        'For revenue questions, return:\n' +
        '{"domain":"revenue","intent":"aggregate|detail|ranking","object":"accounts_revenue__c",' +
        '"measures":[{"fn":"SUM","field":"...","alias":"..."}],' +
        '"dimensions":["Customer_Universal_Account__r.Cluster__c"],' +
        '"filters":[{"field":"...","op":"=|!=|>|>=|<|<=|IN|NOT IN|BETWEEN","value":"..."}],' +
        '"dateFilter":{"field":"Revenue_Booked_On__c","start":"YYYY-MM-DD","end":"YYYY-MM-DD"},' +
        '"sort":{"field":"alias_or_dimension","direction":"ASC|DESC"},' +
        '"limit":2000}\n\n' +
        'Rules:\n' +
        '- ALWAYS include dateFilter with explicit start/end dates.\n' +
        '- For "top N" questions: set intent=ranking, limit=2000 (summary truncates), sort DESC on measure alias.\n' +
        '- For customer rankings: use ONLY Customer_Universal_Account__r.Name as dimension. Do NOT add SKU, Cluster, Currency, or any other dimension — keep it simple like CRM Buddy. Add filter {"field":"Customer_Universal_Account__c","op":"!=","value":null}.\n' +
        '- Use BETWEEN op only in dateFilter; use IN op for picklist multi-value filters.\n' +
        '- detail intent is NOT allowed for accounts_revenue__c (too many rows). Use aggregate or ranking.\n' +
        '</instructions>\n\n' +
        '<examples>\n' +
        'Q: "Total revenue this year"\n' +
        '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
        '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
        '"dimensions":["Parent_SKU__c"],' +
        '"filters":[],' +
        '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-31"},' +
        '"sort":{"field":"rev","direction":"DESC"},"limit":2000}\n\n' +
        'Q: "Top customers by GP in Q3"\n' +
        '{"domain":"revenue","intent":"ranking","object":"accounts_revenue__c",' +
        '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
        '"dimensions":["Customer_Universal_Account__r.Name"],' +
        '"filters":[{"field":"Customer_Universal_Account__c","op":"!=","value":null}],' +
        '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-10-01","end":"2025-12-31"},' +
        '"sort":{"field":"gp","direction":"DESC"},"limit":2000}\n\n' +
        'Q: "How many bookings this quarter?"\n' +
        '{"domain":"not_revenue","reason":"Bookings use Opportunity object, not accounts_revenue__c"}\n' +
        '</examples>';

    // Allowed operators for plan filters
    private static final Set<String> ALLOWED_OPS = new Set<String>{
        '=', '!=', '>', '>=', '<', '<=', 'IN', 'NOT IN'
    };

    // Allowed aggregate functions
    private static final Set<String> ALLOWED_FNS = new Set<String>{
        'SUM', 'COUNT', 'AVG', 'MIN', 'MAX'
    };

    /**
     * Checks whether the structured planner feature flag is enabled.
     * Reads Use_Structured_Planner__c from AI_Assistant_Config__mdt.Claude_API.
     */
    @TestVisible
    private static Boolean testPlannerFlag;

    // ── Conversational follow-up classifier ──────────────────────────

    private static final Set<String> DATA_KEYWORDS = new Set<String>{
        'revenue', 'gp', 'gross profit', 'booking', 'pipeline', 'funnel',
        'deals', 'tickets', 'leads', 'accounts', 'customers', 'cases',
        'total', 'sum', 'count', 'average', 'how many', 'how much',
        'top', 'bottom', 'highest', 'lowest', 'best', 'worst',
        'compare', 'trend', 'growth', 'decline', 'churn',
        'win rate', 'conversion', 'sales cycle', 'margin',
        'cluster', 'region', 'sku', 'sector', 'segment',
        'order', 'won', 'lost', 'open', 'closed',
        'target', 'variance', 'achievement', 'forecast',
        'mtd', 'qtd', 'ytd', 'this year', 'this quarter', 'this month',
        'last year', 'last quarter', 'last month', 'fy', 'q1', 'q2', 'q3', 'q4'
    };

    /**
     * Returns true if the message is a pure conversational follow-up
     * with NO data intent. If ANY data keyword is found, returns false
     * so the message goes through the normal SOQL path.
     */
    @TestVisible
    private static Boolean isConversationalFollowup(String question) {
        if (String.isBlank(question)) return false;
        String lower = question.toLowerCase().trim();

        // Short acknowledgements — always conversational
        if (lower.length() <= 15) {
            Set<String> acks = new Set<String>{
                'yes', 'no', 'ok', 'okay', 'thanks', 'thank you', 'got it',
                'cool', 'great', 'perfect', 'correct', 'right', 'sure', 'hmm'
            };
            if (acks.contains(lower) || acks.contains(lower.replaceAll('[.!?]', ''))) {
                return true;
            }
        }

        // If ANY data keyword is present → NOT a follow-up (safe default)
        for (String kw : DATA_KEYWORDS) {
            if (lower.contains(kw)) {
                return false;
            }
        }

        // No data keywords found → treat as conversational follow-up
        return true;
    }

    /**
     * Answers a conversational follow-up using conversation history.
     * No SOQL generated — just Claude + context.
     */
    private static String handleConversationalFollowup(String question, String conversationContext) {
        String systemPrompt =
            'You are Ask Salesforce — a friendly, knowledgeable business assistant at Exotel.\n' +
            'The user is asking a conversational follow-up (no new data query needed).\n' +
            'Answer warmly and concisely using the conversation history. Keep it natural and helpful.\n' +
            'Indian FY runs Apr-Mar. FY2026 = Apr 2025 - Mar 2026. Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar.\n' +
            'Revenue data is from accounts_revenue__c. Bookings from Opportunity.\n' +
            'Do NOT generate SOQL queries. Just respond conversationally like a helpful colleague would.\n' +
            'If you cannot answer from context, say: "I\'d need to run a fresh query for that — go ahead and ask!"';

        String ctx = conversationContext.length() > 4000
            ? '...' + conversationContext.substring(conversationContext.length() - 4000)
            : conversationContext;

        String userMessage = '[Conversation history]\n' + ctx +
            '\n\n[Follow-up question]\n' + question;

        ClaudeApiService.ClaudeResponse response =
            ClaudeApiService.sendMessage(systemPrompt, userMessage, 2048);

        return response.content;
    }

    @TestVisible
    private static Boolean isStructuredPlannerEnabled() {
        if (testPlannerFlag != null) return testPlannerFlag;
        try {
            AI_Assistant_Config__mdt config = AI_Assistant_Config__mdt.getInstance('Claude_API');
            return config != null && config.Use_Structured_Planner__c == true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Validates a revenue query plan against domain allowlists.
     * Returns null if valid, or an error message string if invalid.
     */
    @TestVisible
    private static String validateRevenuePlan(Map<String, Object> plan, AskSF_Domain__mdt domain) {
        // Must be revenue domain
        String planDomain = (String) plan.get('domain');
        if (planDomain != 'revenue') {
            return 'Plan domain is not revenue: ' + planDomain;
        }

        // Object must be accounts_revenue__c
        String obj = (String) plan.get('object');
        if (obj != 'accounts_revenue__c') {
            return 'Invalid object: ' + obj;
        }

        // Intent must not be detail (governor limit risk)
        String intent = (String) plan.get('intent');
        if (intent == 'detail') {
            return 'Detail intent not allowed on accounts_revenue__c';
        }

        // Build allowlists from domain metadata
        Set<String> allowedMeasures = new Set<String>();
        if (String.isNotBlank(domain.AllowedMeasures__c)) {
            for (String m : domain.AllowedMeasures__c.split(',')) {
                allowedMeasures.add(m.trim().toLowerCase());
            }
        }
        Set<String> allowedDimensions = new Set<String>();
        if (String.isNotBlank(domain.AllowedDimensions__c)) {
            for (String d : domain.AllowedDimensions__c.split(',')) {
                allowedDimensions.add(d.trim().toLowerCase());
            }
        }

        // Validate measures
        List<Object> measures = (List<Object>) plan.get('measures');
        if (measures == null || measures.isEmpty()) {
            return 'No measures specified';
        }
        for (Object mObj : measures) {
            Map<String, Object> m = (Map<String, Object>) mObj;
            String fn = ((String) m.get('fn')).toUpperCase();
            String field = (String) m.get('field');
            if (!ALLOWED_FNS.contains(fn)) {
                return 'Invalid aggregate function: ' + fn;
            }
            // COUNT(Id) is always allowed
            if (fn == 'COUNT' && field != null && field.toLowerCase() == 'id') {
                continue;
            }
            if (!allowedMeasures.contains(field.toLowerCase())) {
                return 'Field not in allowed measures: ' + field;
            }
        }

        // Validate dimensions
        List<Object> dimensions = (List<Object>) plan.get('dimensions');
        if (dimensions != null) {
            for (Object dObj : dimensions) {
                String dim = (String) dObj;
                if (!allowedDimensions.contains(dim.toLowerCase())) {
                    return 'Field not in allowed dimensions: ' + dim;
                }
            }
        }

        // Validate filters
        List<Object> filters = (List<Object>) plan.get('filters');
        if (filters != null) {
            // Build combined allowlist: measures + dimensions + date field + account lookups (for null check)
            Set<String> allowedFilterFields = new Set<String>();
            allowedFilterFields.addAll(allowedMeasures);
            allowedFilterFields.addAll(allowedDimensions);
            allowedFilterFields.add('revenue_booked_on__c');
            allowedFilterFields.add('account__c');
            allowedFilterFields.add('customer_universal_account__c');

            for (Object fObj : filters) {
                Map<String, Object> f = (Map<String, Object>) fObj;
                String field = (String) f.get('field');
                String op = ((String) f.get('op')).toUpperCase();
                if (!allowedFilterFields.contains(field.toLowerCase())) {
                    return 'Filter field not allowed: ' + field;
                }
                if (!ALLOWED_OPS.contains(op)) {
                    return 'Invalid operator: ' + op;
                }
            }
        }

        // Validate dateFilter
        Map<String, Object> dateFilter = (Map<String, Object>) plan.get('dateFilter');
        if (dateFilter == null) {
            return 'dateFilter is required for revenue queries';
        }
        String dateField = (String) dateFilter.get('field');
        if (dateField != 'Revenue_Booked_On__c') {
            return 'Invalid date field: ' + dateField;
        }

        // Validate limit
        Object limitObj = plan.get('limit');
        if (limitObj != null) {
            Integer lim = limitObj instanceof Integer ? (Integer) limitObj : Integer.valueOf(String.valueOf(limitObj));
            if (lim > 2000) {
                return 'Limit exceeds maximum (2000): ' + lim;
            }
        }

        return null; // valid
    }

    /**
     * Compiles a validated revenue plan into a SOQL query string.
     */
    @TestVisible
    private static String compileSoqlFromPlan(Map<String, Object> plan) {
        List<Object> measures = (List<Object>) plan.get('measures');
        List<Object> dimensions = (List<Object>) plan.get('dimensions');
        List<Object> filters = (List<Object>) plan.get('filters');
        Map<String, Object> dateFilter = (Map<String, Object>) plan.get('dateFilter');
        Map<String, Object> sortSpec = (Map<String, Object>) plan.get('sort');
        Object limitObj = plan.get('limit');

        // SELECT clause
        List<String> selectParts = new List<String>();
        // Add dimensions first
        if (dimensions != null) {
            for (Object dObj : dimensions) {
                selectParts.add((String) dObj);
            }
        }
        // Add measures
        Map<String, String> aliasToExpr = new Map<String, String>();
        for (Object mObj : measures) {
            Map<String, Object> m = (Map<String, Object>) mObj;
            String fn = ((String) m.get('fn')).toUpperCase();
            String field = (String) m.get('field');
            String alias = (String) m.get('alias');
            String expr = fn + '(' + field + ')';
            selectParts.add(expr + (String.isNotBlank(alias) ? ' ' + alias : ''));
            if (String.isNotBlank(alias)) {
                aliasToExpr.put(alias, expr);
            }
        }

        String soql = 'SELECT ' + String.join(selectParts, ', ');
        soql += ' FROM accounts_revenue__c';

        // WHERE clause
        List<String> whereParts = new List<String>();

        // Date filter (always present after validation)
        String startDate = (String) dateFilter.get('start');
        String endDate = (String) dateFilter.get('end');
        whereParts.add('Revenue_Booked_On__c >= ' + startDate);
        whereParts.add('Revenue_Booked_On__c <= ' + endDate);

        // Additional filters
        if (filters != null) {
            for (Object fObj : filters) {
                Map<String, Object> f = (Map<String, Object>) fObj;
                String field = (String) f.get('field');
                String op = ((String) f.get('op')).toUpperCase();
                Object value = f.get('value');

                if (op == 'IN' || op == 'NOT IN') {
                    List<Object> vals = (List<Object>) value;
                    List<String> quoted = new List<String>();
                    for (Object v : vals) {
                        quoted.add('\'' + String.escapeSingleQuotes(String.valueOf(v)) + '\'');
                    }
                    whereParts.add(field + ' ' + op + ' (' + String.join(quoted, ', ') + ')');
                } else if (value == null) {
                    // null comparisons
                    if (op == '!=') {
                        whereParts.add(field + ' != null');
                    } else {
                        whereParts.add(field + ' = null');
                    }
                } else {
                    // Numeric vs string value
                    String strVal = String.valueOf(value);
                    Boolean isNumeric = strVal.isNumeric() || (strVal.contains('.') && strVal.replaceFirst('\\.', '').isNumeric());
                    if (isNumeric) {
                        whereParts.add(field + ' ' + op + ' ' + strVal);
                    } else {
                        whereParts.add(field + ' ' + op + ' \'' + String.escapeSingleQuotes(strVal) + '\'');
                    }
                }
            }
        }

        soql += ' WHERE ' + String.join(whereParts, ' AND ');

        // GROUP BY (all dimensions)
        if (dimensions != null && !dimensions.isEmpty()) {
            List<String> groupByParts = new List<String>();
            for (Object dObj : dimensions) {
                groupByParts.add((String) dObj);
            }
            soql += ' GROUP BY ' + String.join(groupByParts, ', ');
        }

        // ORDER BY
        if (sortSpec != null) {
            String sortField = (String) sortSpec.get('field');
            String sortDir = (String) sortSpec.get('direction');
            if (String.isNotBlank(sortField)) {
                // If the sort field is an alias, use the aggregate expression
                String orderExpr = aliasToExpr.containsKey(sortField) ? aliasToExpr.get(sortField) : sortField;
                soql += ' ORDER BY ' + orderExpr + (sortDir == 'ASC' ? ' ASC' : ' DESC');
            }
        }

        // LIMIT
        if (limitObj != null) {
            Integer lim = limitObj instanceof Integer ? (Integer) limitObj : Integer.valueOf(String.valueOf(limitObj));
            soql += ' LIMIT ' + lim;
        }

        return soql;
    }

    /**
     * 3-state result from the structured planner.
     * SUCCESS: compiled SOQL queries ready for execution
     * NOT_REVENUE: planner classified this as a non-revenue question (classification result, not error)
     * ERROR: planner failed (parse error, validation error, API issue) — safe to fall back
     */
    @TestVisible
    private class PlannerResult {
        String status;     // 'SUCCESS', 'NOT_REVENUE', 'ERROR'
        List<Map<String, String>> queries;
        String reason;     // for NOT_REVENUE: why; for ERROR: what failed
        String targetDomain; // for NOT_REVENUE: where it should go (e.g., 'bookings', 'pipeline')

        PlannerResult(String status) {
            this.status = status;
        }
    }

    /**
     * Runs the structured planner path for revenue questions.
     * Returns a 3-state PlannerResult:
     *   SUCCESS → compiled SOQL queries, skip the legacy prompt
     *   NOT_REVENUE → classification result (not an error), check if domain is blocked
     *   ERROR → planner failure, safe to fall back to legacy prompt
     */
    @TestVisible
    private static PlannerResult runRevenuePlanner(String enrichedQuestion, AskSF_Domain__mdt domain) {
        try {
            // Call Claude with the small planner prompt
            ClaudeApiService.ClaudeResponse planResponse =
                ClaudeApiService.sendMessage(PLANNER_SYSTEM_PROMPT, enrichedQuestion, 2048);

            // Parse JSON plan
            String planJson = planResponse.content.trim();
            // Strip markdown code fences if present
            if (planJson.startsWith('```')) {
                planJson = planJson.substringAfter('\n');
                if (planJson.contains('```')) {
                    planJson = planJson.substringBefore('```');
                }
                planJson = planJson.trim();
            }

            Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(planJson);

            // If planner says not_revenue, return classification result (NOT a fallback)
            String planDomain = (String) plan.get('domain');
            if (planDomain == 'not_revenue') {
                PlannerResult pr = new PlannerResult('NOT_REVENUE');
                pr.reason = (String) plan.get('reason');
                System.debug('Planner classified as not_revenue: ' + pr.reason);
                return pr;
            }

            // Validate the plan
            String validationError = validateRevenuePlan(plan, domain);
            if (validationError != null) {
                System.debug('Planner validation failed: ' + validationError);
                PlannerResult pr = new PlannerResult('ERROR');
                pr.reason = validationError;
                return pr;
            }

            // Apply semantic overrides BEFORE compilation
            // Extract the raw user question (strip date context and conversation history)
            String rawQuestion = enrichedQuestion;
            if (rawQuestion.contains('[Current question]')) {
                rawQuestion = rawQuestion.substringAfter('[Current question]');
            }
            List<SemanticOverride> overrides = detectOverrides(rawQuestion);
            List<String> appliedOverrides = new List<String>();
            if (!overrides.isEmpty()) {
                // Check for forbidden field violations first
                String forbiddenError = checkForbiddenFields(plan, overrides);
                if (forbiddenError != null) {
                    System.debug('Semantic override correcting forbidden field: ' + forbiddenError);
                }
                // Apply corrections to the plan
                appliedOverrides = applyOverridesToPlan(plan, overrides);
                for (String oid : appliedOverrides) {
                    System.debug('SEMANTIC_OVERRIDE_APPLIED: ' + oid + ' (planner path)');
                }
            }

            // Compile to SOQL
            String soql = compileSoqlFromPlan(plan);

            // Return as single-query list (same format as extractAllSoql output)
            PlannerResult pr = new PlannerResult('SUCCESS');
            pr.queries = new List<Map<String, String>>();
            String label = 'Revenue Query (Structured Planner)';
            if (!appliedOverrides.isEmpty()) {
                label += ' [overrides: ' + String.join(appliedOverrides, ',') + ']';
            }
            pr.queries.add(new Map<String, String>{
                'label' => label,
                'soql' => soql
            });
            return pr;

        } catch (Exception e) {
            System.debug('Planner error, falling back: ' + e.getMessage());
            PlannerResult pr = new PlannerResult('ERROR');
            pr.reason = e.getMessage();
            return pr;
        }
    }

    // ── End Structured Planner ──────────────────────────────────────────

    // ── Revenue Semantic Override Engine ─────────────────────────────────
    // Deterministic field/value correction layer. Loads a small registry of
    // high-confidence terms from a static resource and applies corrections
    // to query plans BEFORE SOQL compilation. Does not replace the planner
    // or sanitizer — it only overrides specific field→value mappings when
    // a known term is detected in the user question.

    /**
     * Represents a single semantic override result — what needs to be corrected.
     */
    public class SemanticOverride {
        public String overrideId;       // e.g. "region_scaleup"
        public String correctField;     // e.g. "Region__c"
        public Object correctValue;     // String or List<String> for multi-value (MENA→UAE,KSA)
        public Set<String> forbiddenFields; // Fields this value must NEVER appear on
        public String reason;           // Human-readable explanation for logs
        public String matchedTerm;      // The actual term that triggered the match
    }

    /**
     * Loads the registry from the RevenueSemanticRegistry static resource.
     * Cached after first load. Returns empty list on any load failure.
     */
    @TestVisible
    private static List<Map<String, Object>> testRegistryOverride;
    private static List<Map<String, Object>> cachedRegistry;

    @TestVisible
    private static List<Map<String, Object>> loadSemanticRegistry() {
        if (testRegistryOverride != null) return testRegistryOverride;
        if (cachedRegistry != null) return cachedRegistry;

        try {
            StaticResource sr = [SELECT Body FROM StaticResource
                                 WHERE Name = 'RevenueSemanticRegistry' LIMIT 1];
            String json_body = sr.Body.toString();
            Map<String, Object> registry = (Map<String, Object>) JSON.deserializeUntyped(json_body);
            cachedRegistry = (List<Map<String, Object>>)
                ((List<Object>) registry.get('overrides'));
            // Convert inner lists to typed form
            List<Map<String, Object>> typed = new List<Map<String, Object>>();
            for (Object o : (List<Object>) registry.get('overrides')) {
                typed.add((Map<String, Object>) o);
            }
            cachedRegistry = typed;
            return cachedRegistry;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SemanticRegistry load failed: ' + e.getMessage());
            cachedRegistry = new List<Map<String, Object>>();
            return cachedRegistry;
        }
    }

    /**
     * Scans the user question for known terms and returns all matching overrides.
     * Matching is case-insensitive, whole-word (bounded by spaces/punctuation/start/end).
     */
    @TestVisible
    private static List<SemanticOverride> detectOverrides(String userQuestion) {
        List<SemanticOverride> results = new List<SemanticOverride>();
        if (String.isBlank(userQuestion)) return results;

        String questionLower = userQuestion.toLowerCase();
        List<Map<String, Object>> registry = loadSemanticRegistry();

        for (Map<String, Object> entry : registry) {
            List<Object> terms = (List<Object>) entry.get('terms');
            String matched = null;

            for (Object termObj : terms) {
                String term = ((String) termObj).toLowerCase();
                // Whole-word match: check if the term appears bounded by non-alpha chars
                Integer idx = questionLower.indexOf(term);
                if (idx >= 0) {
                    Boolean leftBound = (idx == 0) ||
                        !questionLower.substring(idx - 1, idx).isAlpha();
                    Boolean rightBound = (idx + term.length() >= questionLower.length()) ||
                        !questionLower.substring(idx + term.length(), idx + term.length() + 1).isAlpha();
                    if (leftBound && rightBound) {
                        matched = (String) termObj;
                        break;
                    }
                }
            }

            if (matched != null) {
                SemanticOverride so = new SemanticOverride();
                so.overrideId = (String) entry.get('id');
                so.correctField = (String) entry.get('correctField');
                so.correctValue = entry.get('correctValue');
                so.reason = (String) entry.get('reason');
                so.matchedTerm = matched;
                so.forbiddenFields = new Set<String>();
                List<Object> forbidden = (List<Object>) entry.get('forbiddenFields');
                if (forbidden != null) {
                    for (Object f : forbidden) {
                        so.forbiddenFields.add(((String) f).toLowerCase());
                    }
                }
                results.add(so);
            }
        }
        return results;
    }

    /**
     * Applies semantic overrides to a parsed planner plan (before compilation).
     * For each override:
     *   1. Removes any filter on a forbidden field that uses the override's value
     *   2. Adds/replaces the correct field=value filter
     *   3. Swaps forbidden dimensions with correct dimension
     * Returns list of applied override IDs for logging.
     */
    @TestVisible
    private static List<String> applyOverridesToPlan(Map<String, Object> plan,
                                                      List<SemanticOverride> overrides) {
        List<String> applied = new List<String>();
        if (overrides == null || overrides.isEmpty()) return applied;

        List<Object> filters = (List<Object>) plan.get('filters');
        if (filters == null) {
            filters = new List<Object>();
            plan.put('filters', filters);
        }
        List<Object> dimensions = (List<Object>) plan.get('dimensions');

        for (SemanticOverride so : overrides) {
            Boolean didApply = false;

            // 1. Remove any filter on a forbidden field that matches this override's value
            List<Object> cleanedFilters = new List<Object>();
            for (Object fObj : filters) {
                Map<String, Object> f = (Map<String, Object>) fObj;
                String fField = (String) f.get('field');
                if (so.forbiddenFields.contains(fField.toLowerCase())) {
                    // Remove this filter — it's on the wrong field
                    didApply = true;
                    continue;
                }
                cleanedFilters.add(fObj);
            }
            filters = cleanedFilters;

            // 2. Check if correct filter already exists; if not, add it
            Boolean hasCorrectFilter = false;
            for (Object fObj : filters) {
                Map<String, Object> f = (Map<String, Object>) fObj;
                if (((String) f.get('field')).equalsIgnoreCase(so.correctField)) {
                    hasCorrectFilter = true;
                    break;
                }
            }
            if (!hasCorrectFilter) {
                Map<String, Object> newFilter = new Map<String, Object>();
                newFilter.put('field', so.correctField);
                if (so.correctValue instanceof List<Object>) {
                    newFilter.put('op', 'IN');
                    newFilter.put('value', so.correctValue);
                } else {
                    newFilter.put('op', '=');
                    newFilter.put('value', so.correctValue);
                }
                filters.add(newFilter);
                didApply = true;
            }

            // 3. Swap forbidden dimensions with correct dimension
            if (dimensions != null) {
                for (Integer i = 0; i < dimensions.size(); i++) {
                    String dim = (String) dimensions[i];
                    if (so.forbiddenFields.contains(dim.toLowerCase())) {
                        dimensions[i] = so.correctField;
                        didApply = true;
                    }
                }
            }

            plan.put('filters', filters);
            if (didApply) {
                applied.add(so.overrideId);
            }
        }
        return applied;
    }

    /**
     * Applies semantic overrides to raw SOQL (for legacy prompt path).
     * Replaces forbidden field references with correct field references.
     * Returns the corrected SOQL and list of applied override IDs.
     */
    @TestVisible
    private static Map<String, Object> applyOverridesToSoql(String soql,
                                                             List<SemanticOverride> overrides) {
        List<String> applied = new List<String>();
        String correctedSoql = soql;

        for (SemanticOverride so : overrides) {
            for (String forbidden : so.forbiddenFields) {
                // Build the wrong filter pattern and replace with correct
                // e.g. Cluster__c = 'Scaleup' → Region__c = 'Scaleup'
                String correctVal = (so.correctValue instanceof List<Object>)
                    ? String.valueOf(so.correctValue) : (String) so.correctValue;

                // Case-insensitive replacement of field name in filter context
                // Match: forbidden_field (with optional spaces) = 'value'
                String originalField = forbidden.contains('__c')
                    ? forbidden : forbidden;
                // Get the actual casing from SOQL by searching case-insensitively
                String soqlLower = correctedSoql.toLowerCase();
                Integer fieldIdx = soqlLower.indexOf(forbidden);
                if (fieldIdx >= 0) {
                    // Found the forbidden field — extract actual casing from SOQL
                    String actualField = correctedSoql.substring(fieldIdx, fieldIdx + forbidden.length());
                    // Replace field name with correct field
                    correctedSoql = correctedSoql.replace(actualField, so.correctField);
                    applied.add(so.overrideId);
                }
            }
        }

        return new Map<String, Object>{
            'soql' => correctedSoql,
            'applied' => applied
        };
    }

    /**
     * Checks a planner plan for forbidden field violations.
     * Returns an error string if any filter uses a forbidden field for a detected override,
     * or null if the plan is clean.
     */
    @TestVisible
    private static String checkForbiddenFields(Map<String, Object> plan,
                                                List<SemanticOverride> overrides) {
        if (overrides == null || overrides.isEmpty()) return null;

        List<Object> filters = (List<Object>) plan.get('filters');
        if (filters == null) return null;

        for (Object fObj : filters) {
            Map<String, Object> f = (Map<String, Object>) fObj;
            String fField = ((String) f.get('field')).toLowerCase();
            for (SemanticOverride so : overrides) {
                if (so.forbiddenFields.contains(fField)) {
                    return 'Forbidden field ' + f.get('field') + ' used for term "' +
                        so.matchedTerm + '". Must use ' + so.correctField +
                        '. (' + so.reason + ')';
                }
            }
        }

        // Also check dimensions
        List<Object> dimensions = (List<Object>) plan.get('dimensions');
        if (dimensions != null) {
            for (Object dObj : dimensions) {
                String dim = ((String) dObj).toLowerCase();
                for (SemanticOverride so : overrides) {
                    if (so.forbiddenFields.contains(dim)) {
                        return 'Forbidden dimension ' + dObj + ' for term "' +
                            so.matchedTerm + '". Must use ' + so.correctField +
                            '. (' + so.reason + ')';
                    }
                }
            }
        }
        return null;
    }

    // ── End Revenue Semantic Override Engine ─────────────────────────────

    // ── KPI Deterministic Engine ──────────────────────────────────────────
    // Executes known KPIs (Win Rate, Conversion Rate, Sales Cycle) using
    // deterministic Apex-compiled queries + formulas. No Claude involvement
    // for query generation — Claude only explains the pre-computed results.
    // Registry is loaded from KpiRegistry static resource.

    /**
     * Result of KPI engine execution.
     */
    public class KpiResult {
        public String kpiId;
        public String kpiLabel;
        public String dimension;          // actual SF field used for grouping
        public String timeRange;          // e.g. "FY2025 (Apr 2025 - Mar 2026)"
        public List<String> soqlQueries;  // deterministic queries executed
        public String resultsJson;        // pre-formatted JSON for Claude summary
        public Integer totalRecords;
    }

    /**
     * A single row of KPI output for a grouped dimension.
     */
    private class KpiRow {
        String groupValue;
        Decimal numerator;
        Decimal denominator;
        Integer numeratorCount;
        Integer denominatorCount;
        Decimal value;       // computed ratio or avg
        Decimal valueByCount; // count-based ratio (for win rate)
    }

    // KPI summary prompt — focused: explain pre-computed results, do NOT recompute
    private static final String KPI_SUMMARY_PROMPT =
        'You are a business analyst at Exotel/Ameyo presenting KPI results to leadership.\n' +
        'The KPI values below were computed deterministically (Tableau-validated formulas). DO NOT recompute them.\n\n' +
        'RULES:\n' +
        '- Use the EXACT numbers provided. Never divide, multiply, or re-derive.\n' +
        '- Format currency: below ₹100L use Lakhs (₹XX.XX L), above ₹100L use Crores (₹X.XX Cr).\n' +
        '- Highlight top 3 performers with 🟢 and bottom 3 with 🔴.\n' +
        '- For win/conversion rates: explain what the gap between value-based and count-based rates reveals.\n' +
        '  Large gap (value < count) = winning small deals, losing large ones.\n' +
        '  Small gap or reversed = deal sizes are balanced or winning large deals.\n' +
        '- For sales cycle: below 30 days is fast, 30-60 is normal, 60-90 is slow, above 90 is concerning.\n' +
        '- Present the overall summary table first, then the dimensional breakdown, then key insights.\n' +
        '- Keep insights concise and actionable (max 5 bullet points).\n' +
        '- Use markdown tables for the breakdown.\n' +
        'QUARTER DEFINITIONS: Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar. FY runs April to March.\n';

    // Cached KPI registry
    @TestVisible
    private static List<Map<String, Object>> testKpiRegistryOverride;
    private static List<Map<String, Object>> cachedKpiRegistry;

    /**
     * Loads the KPI registry from KpiRegistry static resource. Cached after first load.
     */
    @TestVisible
    private static List<Map<String, Object>> loadKpiRegistry() {
        if (testKpiRegistryOverride != null) return testKpiRegistryOverride;
        if (cachedKpiRegistry != null) return cachedKpiRegistry;
        try {
            StaticResource sr = [SELECT Body FROM StaticResource
                                 WHERE Name = 'KpiRegistry' LIMIT 1];
            Map<String, Object> registry = (Map<String, Object>) JSON.deserializeUntyped(sr.Body.toString());
            cachedKpiRegistry = new List<Map<String, Object>>();
            for (Object o : (List<Object>) registry.get('kpis')) {
                cachedKpiRegistry.add((Map<String, Object>) o);
            }
            return cachedKpiRegistry;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'KpiRegistry load failed: ' + e.getMessage());
            cachedKpiRegistry = new List<Map<String, Object>>();
            return cachedKpiRegistry;
        }
    }

    /**
     * Detects if the user question matches a known KPI.
     * Uses whole-word matching (same pattern as semantic override detection).
     * Returns the KPI definition map, or null if no match.
     */
    @TestVisible
    private static Map<String, Object> detectKpiIntent(String userQuestion) {
        if (String.isBlank(userQuestion)) return null;
        String lower = userQuestion.toLowerCase();
        List<Map<String, Object>> registry = loadKpiRegistry();

        Map<String, Object> bestMatch = null;
        Integer bestTermLength = 0;

        for (Map<String, Object> kpi : registry) {
            List<Object> terms = (List<Object>) kpi.get('questionTerms');
            for (Object termObj : terms) {
                String term = ((String) termObj).toLowerCase();
                // Whole-word boundary match (same approach as semantic override detection)
                Integer idx = lower.indexOf(term);
                if (idx >= 0) {
                    Boolean leftBound = (idx == 0) ||
                        !lower.substring(idx - 1, idx).isAlpha();
                    Boolean rightBound = (idx + term.length() >= lower.length()) ||
                        !lower.substring(idx + term.length(), idx + term.length() + 1).isAlpha();
                    if (leftBound && rightBound) {
                        // Prefer longest matching term (more specific)
                        if (term.length() > bestTermLength) {
                            bestTermLength = term.length();
                            bestMatch = kpi;
                        }
                    }
                }
            }
        }
        return bestMatch;
    }

    /**
     * Extracts the grouping dimension from the user question.
     * Matches against supportedDimensions keys from the KPI definition.
     * Returns the SF field name, or the defaultDimension if no match.
     */
    @TestVisible
    private static String extractKpiGrouping(String userQuestion, Map<String, Object> kpiDef) {
        String lower = userQuestion.toLowerCase();
        String defaultDim = (String) kpiDef.get('defaultDimension');
        Map<String, Object> supported = (Map<String, Object>) kpiDef.get('supportedDimensions');
        if (supported == null) return defaultDim;

        // Check each dimension keyword (longest match first)
        String bestField = null;
        Integer bestLen = 0;
        for (String keyword : supported.keySet()) {
            if (lower.contains(keyword.toLowerCase()) && keyword.length() > bestLen) {
                bestField = (String) supported.get(keyword);
                bestLen = keyword.length();
            }
        }
        return bestField != null ? bestField : defaultDim;
    }

    /**
     * Extracts time range from user question. Returns {start, end, label}.
     * Handles: FY, quarter, month, and explicit date references.
     */
    @TestVisible
    private static Map<String, Object> extractKpiTimeRange(String userQuestion, Date today) {
        String lower = userQuestion.toLowerCase();
        Integer fyStartYear = today.month() >= 4 ? today.year() : today.year() - 1;
        Date fyStart = Date.newInstance(fyStartYear, 4, 1);

        Map<String, Object> result = new Map<String, Object>();

        // Check for "last quarter" / "previous quarter"
        if (lower.contains('last quarter') || lower.contains('previous quarter') || lower.contains('prev quarter')) {
            // Go back one quarter from current
            Integer currentQ;
            if (today.month() >= 4 && today.month() <= 6) currentQ = 1;
            else if (today.month() >= 7 && today.month() <= 9) currentQ = 2;
            else if (today.month() >= 10 && today.month() <= 12) currentQ = 3;
            else currentQ = 4;

            Integer prevQ = currentQ == 1 ? 4 : currentQ - 1;
            Integer prevYear = (currentQ == 1) ? fyStartYear - 1 : fyStartYear;
            Date qStart;
            Date qEnd;
            if (prevQ == 1) { qStart = Date.newInstance(prevYear, 4, 1); qEnd = Date.newInstance(prevYear, 6, 30); }
            else if (prevQ == 2) { qStart = Date.newInstance(prevYear, 7, 1); qEnd = Date.newInstance(prevYear, 9, 30); }
            else if (prevQ == 3) { qStart = Date.newInstance(prevYear, 10, 1); qEnd = Date.newInstance(prevYear, 12, 31); }
            else { qStart = Date.newInstance(prevYear + 1, 1, 1); qEnd = Date.newInstance(prevYear + 1, 3, 31); }

            result.put('start', qStart);
            result.put('end', qEnd);
            result.put('label', 'Q' + prevQ + ' FY' + prevYear);
            return result;
        }

        // Check for specific quarter: "Q1", "Q2", "Q3", "Q4", "this quarter"
        if (lower.contains('this quarter') || lower.contains('current quarter')) {
            Integer currentQ;
            if (today.month() >= 4 && today.month() <= 6) currentQ = 1;
            else if (today.month() >= 7 && today.month() <= 9) currentQ = 2;
            else if (today.month() >= 10 && today.month() <= 12) currentQ = 3;
            else currentQ = 4;

            Date qStart;
            Date qEnd;
            if (currentQ == 1) { qStart = Date.newInstance(fyStartYear, 4, 1); qEnd = Date.newInstance(fyStartYear, 6, 30); }
            else if (currentQ == 2) { qStart = Date.newInstance(fyStartYear, 7, 1); qEnd = Date.newInstance(fyStartYear, 9, 30); }
            else if (currentQ == 3) { qStart = Date.newInstance(fyStartYear, 10, 1); qEnd = Date.newInstance(fyStartYear, 12, 31); }
            else { qStart = Date.newInstance(fyStartYear + 1, 1, 1); qEnd = Date.newInstance(fyStartYear + 1, 3, 31); }

            result.put('start', qStart);
            result.put('end', qEnd);
            result.put('label', 'Q' + currentQ + ' FY' + fyStartYear);
            return result;
        }

        // Check for "this month" / "current month"
        if (lower.contains('this month') || lower.contains('current month')) {
            Date mStart = Date.newInstance(today.year(), today.month(), 1);
            result.put('start', mStart);
            result.put('end', today);
            result.put('label', mStart.format().substring(0, 7));
            return result;
        }

        // Check for "last month" / "previous month"
        if (lower.contains('last month') || lower.contains('previous month')) {
            Date prevMonthStart = Date.newInstance(today.year(), today.month(), 1).addMonths(-1);
            Date prevMonthEnd = Date.newInstance(today.year(), today.month(), 1).addDays(-1);
            result.put('start', prevMonthStart);
            result.put('end', prevMonthEnd);
            result.put('label', prevMonthStart.format().substring(0, 7));
            return result;
        }

        // Default: current FY — use full FY end (Mar 31), NOT today.
        // Tableau/CRM Buddy use complete FY boundaries. Consumed pipeline includes
        // deals with future CloseDate within FY. Won (B_Deal_Date) won't have future dates,
        // so extending to Mar 31 doesn't inflate the numerator.
        Date fyEnd = Date.newInstance(fyStartYear + 1, 3, 31);
        result.put('start', fyStart);
        result.put('end', fyEnd);
        result.put('label', 'FY' + fyStartYear + ' (Apr ' + fyStartYear + ' - Mar ' + (fyStartYear + 1) + ')');
        return result;
    }

    /**
     * Builds a deterministic aggregate SOQL query from KPI spec.
     */
    private static String buildKpiAggregateQuery(
        Map<String, Object> spec, String dimension, Date startDate, Date endDate
    ) {
        String measureField = (String) spec.get('measureField');
        String measureFn = (String) spec.get('measureFn');
        String countField = (String) spec.get('countField');
        String dateField = (String) spec.get('dateField');
        List<Object> stageFilter = (List<Object>) spec.get('stageFilter');

        // Build stage IN clause
        List<String> stageStrs = new List<String>();
        for (Object s : stageFilter) {
            stageStrs.add('\'' + String.escapeSingleQuotes((String) s) + '\'');
        }

        // No Amount > 0 filter — let SUM handle nulls naturally.
        // Including zero/negative amounts (reversals) matches Tableau's denominator.
        String soql = 'SELECT ' + dimension + ', ' +
            measureFn + '(' + measureField + ') val, COUNT(' + countField + ') cnt' +
            ' FROM Opportunity WHERE StageName IN (' + String.join(stageStrs, ',') + ')' +
            ' AND ' + dateField + ' >= ' + String.valueOf(startDate) +
            ' AND ' + dateField + ' <= ' + String.valueOf(endDate) +
            ' GROUP BY ' + dimension +
            ' ORDER BY ' + measureFn + '(' + measureField + ') DESC' +
            ' LIMIT 2000';
        return soql;
    }

    /**
     * Builds a detail query for sales cycle computation (avg or median).
     */
    private static String buildSalesCycleDetailQuery(
        Map<String, Object> computation, String dimension, Date startDate, Date endDate, Integer rowLimit
    ) {
        String startDateField = (String) computation.get('startDateField');
        String endDateField = (String) computation.get('endDateField');
        List<Object> stageFilter = (List<Object>) computation.get('stageFilter');

        List<String> stageStrs = new List<String>();
        for (Object s : stageFilter) {
            stageStrs.add('\'' + String.escapeSingleQuotes((String) s) + '\'');
        }

        String soql = 'SELECT ' + dimension + ', ' + startDateField + ', ' + endDateField +
            ' FROM Opportunity WHERE StageName IN (' + String.join(stageStrs, ',') + ')' +
            ' AND ' + startDateField + ' != null' +
            ' AND ' + endDateField + ' != null' +
            ' AND ' + endDateField + ' >= ' + String.valueOf(startDate) +
            ' AND ' + endDateField + ' <= ' + String.valueOf(endDate) +
            ' ORDER BY ' + dimension +
            ' LIMIT ' + rowLimit;
        return soql;
    }

    /**
     * Main KPI orchestrator. Detects KPI, compiles queries, executes, computes formula.
     * Returns null if no KPI detected (fall through to existing flow).
     */
    @TestVisible
    private static KpiResult runKpiEngine(String userQuestion, Date today) {
        // Step 1: Detect KPI intent
        Map<String, Object> kpiDef = detectKpiIntent(userQuestion);
        if (kpiDef == null) return null;

        String kpiId = (String) kpiDef.get('id');
        String displayName = (String) kpiDef.get('displayName');
        String formulaType = (String) kpiDef.get('formulaType');

        System.debug('KPI_ENGINE: Detected ' + kpiId + ' (' + displayName + ')');

        // Step 2: Extract grouping and time range
        String dimension = extractKpiGrouping(userQuestion, kpiDef);
        Map<String, Object> timeRange = extractKpiTimeRange(userQuestion, today);
        Date startDate = (Date) timeRange.get('start');
        Date endDate = (Date) timeRange.get('end');
        String timeLabel = (String) timeRange.get('label');

        System.debug('KPI_ENGINE: dimension=' + dimension + ' timeRange=' + timeLabel);

        KpiResult result = new KpiResult();
        result.kpiId = kpiId;
        result.kpiLabel = displayName + ' — ' + timeLabel;
        result.dimension = dimension;
        result.timeRange = timeLabel;
        result.soqlQueries = new List<String>();

        if (formulaType == 'RATIO') {
            // WIN_RATE or CONVERSION_RATE: two-query ratio
            Map<String, Object> numSpec = (Map<String, Object>) kpiDef.get('numerator');
            Map<String, Object> denSpec = (Map<String, Object>) kpiDef.get('denominator');

            String numSoql = buildKpiAggregateQuery(numSpec, dimension, startDate, endDate);
            String denSoql = buildKpiAggregateQuery(denSpec, dimension, startDate, endDate);
            result.soqlQueries.add(numSoql);
            result.soqlQueries.add(denSoql);

            System.debug('KPI_ENGINE: numerator SOQL = ' + numSoql);
            System.debug('KPI_ENGINE: denominator SOQL = ' + denSoql);

            // Execute both queries
            List<SObject> numRecords = Database.query(numSoql);
            List<SObject> denRecords = Database.query(denSoql);
            result.totalRecords = numRecords.size() + denRecords.size();

            // Build maps by dimension
            Map<String, Decimal> numValMap = new Map<String, Decimal>();
            Map<String, Integer> numCntMap = new Map<String, Integer>();
            for (SObject rec : numRecords) {
                String dimVal = String.valueOf(rec.get(dimension));
                numValMap.put(dimVal, (Decimal) rec.get('val'));
                numCntMap.put(dimVal, (Integer) rec.get('cnt'));
            }

            Map<String, Decimal> denValMap = new Map<String, Decimal>();
            Map<String, Integer> denCntMap = new Map<String, Integer>();
            for (SObject rec : denRecords) {
                String dimVal = String.valueOf(rec.get(dimension));
                denValMap.put(dimVal, (Decimal) rec.get('val'));
                denCntMap.put(dimVal, (Integer) rec.get('cnt'));
            }

            // Compute ratios per dimension
            List<KpiRow> rows = new List<KpiRow>();
            Decimal grandNum = 0, grandDen = 0;
            Integer grandNumCnt = 0, grandDenCnt = 0;
            Set<String> allDims = new Set<String>();
            allDims.addAll(numValMap.keySet());
            allDims.addAll(denValMap.keySet());

            for (String dimVal : allDims) {
                KpiRow row = new KpiRow();
                row.groupValue = dimVal;
                row.numerator = numValMap.containsKey(dimVal) ? numValMap.get(dimVal) : 0;
                row.denominator = denValMap.containsKey(dimVal) ? denValMap.get(dimVal) : 0;
                row.numeratorCount = numCntMap.containsKey(dimVal) ? numCntMap.get(dimVal) : 0;
                row.denominatorCount = denCntMap.containsKey(dimVal) ? denCntMap.get(dimVal) : 0;
                row.value = row.denominator > 0 ?
                    (row.numerator / row.denominator * 100).setScale(1, RoundingMode.HALF_UP) : 0;
                row.valueByCount = row.denominatorCount > 0 ?
                    (Decimal.valueOf(row.numeratorCount) / Decimal.valueOf(row.denominatorCount) * 100).setScale(1, RoundingMode.HALF_UP) : 0;
                rows.add(row);
                grandNum += row.numerator;
                grandDen += row.denominator;
                grandNumCnt += row.numeratorCount;
                grandDenCnt += row.denominatorCount;
            }

            Decimal overallValue = grandDen > 0 ?
                (grandNum / grandDen * 100).setScale(2, RoundingMode.HALF_UP) : 0;
            Decimal overallCount = grandDenCnt > 0 ?
                (Decimal.valueOf(grandNumCnt) / Decimal.valueOf(grandDenCnt) * 100).setScale(2, RoundingMode.HALF_UP) : 0;

            // Sort rows by denominator value DESC (largest pipeline first)
            // Simple insertion sort (OK for <50 rows)
            for (Integer i = 1; i < rows.size(); i++) {
                KpiRow key = rows[i];
                Integer j = i - 1;
                while (j >= 0 && rows[j].denominator < key.denominator) {
                    rows[j + 1] = rows[j];
                    j--;
                }
                rows[j + 1] = key;
            }

            // Build results JSON
            Boolean showBoth = kpiDef.get('showBothValueAndCount') == true;
            String note = (String) kpiDef.get('interpretationNote');
            result.resultsJson = buildRatioResultsJson(
                kpiId, displayName, timeLabel, dimension, note,
                rows, overallValue, overallCount, grandNum, grandDen, grandNumCnt, grandDenCnt, showBoth);

        } else if (formulaType == 'AVERAGE' || formulaType == 'MEDIAN') {
            // SALES_CYCLE_AVG or SALES_CYCLE_MEDIAN
            Map<String, Object> computation = (Map<String, Object>) kpiDef.get('computation');
            String startDateField = (String) computation.get('startDateField');
            String endDateField = (String) computation.get('endDateField');
            Integer maxRows = computation.get('maxDetailRows') != null ?
                ((Integer) computation.get('maxDetailRows')) : 10000;

            String detailSoql = buildSalesCycleDetailQuery(
                computation, dimension, startDate, endDate, maxRows);
            result.soqlQueries.add(detailSoql);

            System.debug('KPI_ENGINE: detail SOQL = ' + detailSoql);

            // Execute detail query
            List<SObject> records = Database.query(detailSoql);
            result.totalRecords = records.size();

            // Group by dimension, compute days
            Map<String, List<Integer>> daysByDim = new Map<String, List<Integer>>();
            for (SObject rec : records) {
                String dimVal = String.valueOf(rec.get(dimension));
                Date sDate = (Date) rec.get(startDateField);
                Date eDate = (Date) rec.get(endDateField);
                if (sDate == null || eDate == null) continue;
                Integer days = sDate.daysBetween(eDate);
                if (days < 0) continue; // skip invalid
                if (!daysByDim.containsKey(dimVal)) {
                    daysByDim.put(dimVal, new List<Integer>());
                }
                daysByDim.get(dimVal).add(days);
            }

            // Compute avg or median per dimension
            List<KpiRow> rows = new List<KpiRow>();
            List<Integer> allDays = new List<Integer>();
            for (String dimVal : daysByDim.keySet()) {
                List<Integer> vals = daysByDim.get(dimVal);
                vals.sort();
                allDays.addAll(vals);

                KpiRow row = new KpiRow();
                row.groupValue = dimVal;
                row.denominatorCount = vals.size();

                if (formulaType == 'AVERAGE') {
                    Decimal sum = 0;
                    for (Integer d : vals) sum += d;
                    row.value = vals.size() > 0 ? (sum / vals.size()).setScale(1, RoundingMode.HALF_UP) : 0;
                } else {
                    // MEDIAN
                    row.value = computeMedian(vals);
                }
                rows.add(row);
            }

            // Sort by value ASC (fastest first)
            for (Integer i = 1; i < rows.size(); i++) {
                KpiRow key = rows[i];
                Integer j = i - 1;
                while (j >= 0 && rows[j].value > key.value) {
                    rows[j + 1] = rows[j];
                    j--;
                }
                rows[j + 1] = key;
            }

            // Overall
            allDays.sort();
            Decimal overallValue;
            if (formulaType == 'AVERAGE') {
                Decimal totalSum = 0;
                for (Integer d : allDays) totalSum += d;
                overallValue = allDays.size() > 0 ? (totalSum / allDays.size()).setScale(1, RoundingMode.HALF_UP) : 0;
            } else {
                overallValue = computeMedian(allDays);
            }

            String note = (String) kpiDef.get('interpretationNote');
            result.resultsJson = buildCycleResultsJson(
                kpiId, displayName, formulaType, timeLabel, dimension, note,
                rows, overallValue, allDays.size());
        }

        System.debug('KPI_ENGINE: execution complete for ' + kpiId);
        return result;
    }

    /**
     * Computes median from a pre-sorted list of integers.
     */
    @TestVisible
    private static Decimal computeMedian(List<Integer> sortedVals) {
        if (sortedVals == null || sortedVals.isEmpty()) return 0;
        Integer n = sortedVals.size();
        if (Math.mod(n, 2) == 1) {
            return Decimal.valueOf(sortedVals[n / 2]);
        } else {
            return (Decimal.valueOf(sortedVals[n / 2 - 1]) + Decimal.valueOf(sortedVals[n / 2])) / 2;
        }
    }

    /**
     * Computes simple ratio, handling divide-by-zero.
     */
    @TestVisible
    private static Decimal computeRatio(Decimal numerator, Decimal denominator) {
        if (denominator == null || denominator == 0) return 0;
        return (numerator / denominator * 100).setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Builds results JSON for ratio KPIs (Win Rate, Conversion Rate).
     */
    private static String buildRatioResultsJson(
        String kpiId, String displayName, String timeLabel, String dimension, String note,
        List<KpiRow> rows, Decimal overallValue, Decimal overallCount,
        Decimal grandNum, Decimal grandDen, Integer grandNumCnt, Integer grandDenCnt,
        Boolean showBoth
    ) {
        // Build JSON manually for control over structure
        String json = '{"kpi":"' + kpiId + '","displayName":"' + displayName + '",' +
            '"period":"' + timeLabel + '","dimension":"' + dimension + '",' +
            '"interpretationNote":"' + (note != null ? note : '') + '",' +
            '"overall":{' +
                '"rateByValue":' + overallValue + ',' +
                '"rateByCount":' + overallCount + ',' +
                '"numeratorValue":' + grandNum + ',' +
                '"numeratorValue_display":"' + formatAsLakhs(grandNum) + '",' +
                '"denominatorValue":' + grandDen + ',' +
                '"denominatorValue_display":"' + formatAsLakhs(grandDen) + '",' +
                '"numeratorCount":' + grandNumCnt + ',' +
                '"denominatorCount":' + grandDenCnt +
            '},"rows":[';

        List<String> rowJsons = new List<String>();
        for (KpiRow row : rows) {
            String rj = '{"group":"' + (row.groupValue != null ? String.escapeSingleQuotes(row.groupValue) : 'null') + '",' +
                '"numeratorValue":' + row.numerator + ',' +
                '"numeratorValue_display":"' + formatAsLakhs(row.numerator) + '",' +
                '"denominatorValue":' + row.denominator + ',' +
                '"denominatorValue_display":"' + formatAsLakhs(row.denominator) + '",' +
                '"rateByValue":' + row.value + ',' +
                '"numeratorCount":' + row.numeratorCount + ',' +
                '"denominatorCount":' + row.denominatorCount + ',' +
                '"rateByCount":' + row.valueByCount + '}';
            rowJsons.add(rj);
        }
        json += String.join(rowJsons, ',') + ']}';
        return json;
    }

    /**
     * Builds results JSON for sales cycle KPIs.
     */
    private static String buildCycleResultsJson(
        String kpiId, String displayName, String formulaType, String timeLabel,
        String dimension, String note,
        List<KpiRow> rows, Decimal overallValue, Integer totalDeals
    ) {
        String json = '{"kpi":"' + kpiId + '","displayName":"' + displayName + '",' +
            '"formulaType":"' + formulaType + '",' +
            '"period":"' + timeLabel + '","dimension":"' + dimension + '",' +
            '"interpretationNote":"' + (note != null ? note : '') + '",' +
            '"overall":{"value":' + overallValue + ',"unit":"days","totalDeals":' + totalDeals + '},' +
            '"rows":[';

        List<String> rowJsons = new List<String>();
        for (KpiRow row : rows) {
            String rj = '{"group":"' + (row.groupValue != null ? String.escapeSingleQuotes(row.groupValue) : 'null') + '",' +
                '"value":' + row.value + ',"dealCount":' + row.denominatorCount + '}';
            rowJsons.add(rj);
        }
        json += String.join(rowJsons, ',') + ']}';
        return json;
    }

    // ── End KPI Deterministic Engine ──────────────────────────────────────

    private static final String SOQL_SYSTEM_PROMPT =
        'You are a Salesforce SOQL generator for Exotel/Ameyo\'s org. Convert natural language to SOQL.\n\n' +
        '=== RULES ===\n' +
        '1. Return ONLY a SOQL query in ```soql ``` code blocks.\n' +
        '2. Always LIMIT (max 2000) EXCEPT aggregate queries without GROUP BY (e.g. SELECT COUNT(Id) FROM X — NO LIMIT allowed). 3. No DML. 4. Use aggregates for totals/summaries.\n' +
        '5. NEVER invent field names. ONLY use fields listed here or standard SF fields.\n' +
        '6. DateTime vs Date: CloseDate and fields ending _Date__c (Date type) use YYYY-MM-DD.\n' +
        '   ALL DateTime fields (CreatedDate, LastModifiedDate, LastStageChangeDate, *_time__c, *_DateTime__c) use YYYY-MM-DDT00:00:00Z.\n' +
        '7. Formula fields CANNOT be used in GROUP BY, aggregate WHERE, or ORDER BY in aggregates.\n' +
        '8. Multi-picklist: MUST use INCLUDES/EXCLUDES infix, NEVER as function. NEVER use LIKE on multi-picklist.\n\n' +
        '=== QUERY PHILOSOPHY ===\n' +
        '- DEFAULT TIME: No date specified → current FY (April 1 to today). Leads/Cases use CreatedDate.\n' +
        '  e.g. March 2026 → CloseDate >= 2025-04-01; June 2026 → CloseDate >= 2026-04-01\n' +
        '- Specified range: add 30-day buffer both sides.\n' +
        '- Prefer >= for thresholds ("above 2 lakhs" = >= 200000).\n' +
        '- Rankings/leaderboards → GROUP BY + COUNT/SUM, ORDER BY aggregate DESC, LIMIT 2000.\n' +
        '- Deal lists/details → individual records with Name, Account.Name, Owner.Name, etc.\n' +
        '- Losses/wins: include Loss_Reason__c, Competition__c, Account_Region__c, Product_Type__c, Owner.Name.\n\n' +
        '=== FISCAL YEAR & QUARTERS ===\n' +
        'Indian FY (Apr-Mar): Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar.\n' +
        'FY2025=Apr 2025-Mar 2026, FY2026=Apr 2026-Mar 2027.\n' +
        'ALWAYS use explicit date ranges for FY/quarters, NEVER SOQL fiscal literals. LAST_N_DAYS is OK.\n' +
        '"This year"/"this FY"/"current year" → ALWAYS means current Indian FY (Apr 1 to today).\n' +
        '  In March 2026 → FY2025 = CloseDate >= 2025-04-01 AND CloseDate <= 2026-03-31.\n' +
        '  NEVER interpret "this year" as calendar year (Jan-Dec). India runs on fiscal year.\n\n' +
        '=== COMPUTED METRICS (require specific SOQL patterns) ===\n' +
        'WIN RATE: "win rate"/"conversion rate"/"success rate" across any dimension.\n' +
        '  Definition (Tableau-validated, Key KPIs dashboard): Won value / Total consumed value.\n' +
        '  Won stage: StageName = \'Order\'\n' +
        '  Won date field: B_Deal_Date__c (booking date, NOT CloseDate)\n' +
        '  Consumed stages: Terminal stages PLUS Negotiation (deals that reached pricing/terms stage):\n' +
        '    StageName IN (\'Order\',\'Negotiation\',\'Closed Lost\',\'Closed-No decision\',\'Closed Unknown\',\'Closed Duplicate\',\'Rejected\',\'SDF Rejected\')\n' +
        '  Consumed date field: CloseDate\n' +
        '  Value field: Amount for BOTH won and consumed. NOT Net_New_INR__c (it is 0 for lost deals).\n' +
        '  CRITICAL: You MUST include StageName in both SELECT and GROUP BY so the summary can split won vs total.\n' +
        '  CRITICAL: Generate TWO queries — one for won (filtered by B_Deal_Date__c), one for all consumed (filtered by CloseDate).\n' +
        '    Query 1 (Won): SELECT Account_Cluster__c, SUM(Amount) wonVal, COUNT(Id) wonCnt\n' +
        '      FROM Opportunity WHERE StageName = \'Order\' AND B_Deal_Date__c >= 2025-04-01 AND B_Deal_Date__c <= 2026-03-31\n' +
        '      GROUP BY Account_Cluster__c ORDER BY SUM(Amount) DESC LIMIT 2000\n' +
        '    Query 2 (Consumed): SELECT Account_Cluster__c, StageName, SUM(Amount) consVal, COUNT(Id) consCnt\n' +
        '      FROM Opportunity WHERE StageName IN (\'Order\',\'Negotiation\',\'Closed Lost\',\'Closed-No decision\',\'Closed Unknown\',\'Closed Duplicate\',\'Rejected\',\'SDF Rejected\')\n' +
        '      AND CloseDate >= 2025-04-01 AND CloseDate <= 2026-03-31\n' +
        '      GROUP BY Account_Cluster__c, StageName ORDER BY Account_Cluster__c LIMIT 2000\n' +
        '  The summary step will then: per cluster, win rate by value = wonVal / sum(consVal), win rate by count = wonCnt / sum(consCnt).\n' +
        '  ALWAYS show BOTH win rate by value AND win rate by count. The gap between them reveals deal-size patterns.\n' +
        'PIPELINE / FUNNEL STAGE MAPPING (CRM Buddy Mapping Dictionary, Tableau-validated):\n' +
        '  These are the EXACT stage sets. Use the concept the user mentions:\n' +
        '  "pipeline" → StageName IN (\'Prospect\',\'Approach\',\'Proposal\',\'Negotiation\',\'SDF Submission\',\'On Hold\',\'Closed won - Pending\',\'Order\',\'Closed Unknown\',\'Closed Duplicate\',\'Closed-No decision\',\'Closed Lost\',\'POC Closed\')\n' +
        '    Pipeline = full lifecycle. Includes open + won + lost. Excludes Suspect, Rejected, SDF Rejected.\n' +
        '  "funnel" / "total funnel" → StageName IN (\'Prospect\',\'Approach\',\'Proposal\',\'Negotiation\',\'SDF Submission\',\'On Hold\',\'Closed won - Pending\',\'POC\',\'Order\',\'Closed Unknown\',\'Closed Duplicate\',\'Closed-No decision\',\'Closed Lost\')\n' +
        '    Same as Pipeline but with POC instead of POC Closed.\n' +
        '  "open funnel" / "open pipeline" / "active deals" / "active opportunities" → StageName IN (\'Prospect\',\'Approach\',\'Proposal\',\'Negotiation\',\'SDF Submission\',\'On Hold\',\'Closed won - Pending\')\n' +
        '    Only deals not yet won or lost.\n' +
        '  "closed funnel" / "closed deals" / "lost deals" → StageName IN (\'Closed Unknown\',\'Closed Duplicate\',\'Closed-No decision\',\'Closed Lost\',\'POC Closed\')\n' +
        '  "order" / "booking" / "won deals" → StageName IN (\'POC\',\'Order\')\n' +
        '  NOTE: Suspect is NOT in any concept above. Only include if user explicitly asks for "suspects" or "all stages".\n' +
        '  NEVER use IsClosed = false (SF IsClosed flag is inconsistent with these mappings).\n' +
        '  VALUE FIELD: Use Normalize_Amount_INR__c (formula, already INR-normalized — matches Tableau dashboard).\n' +
        '    Normalize_Amount_INR__c CAN be used in SUM() with GROUP BY. It just cannot be in the GROUP BY clause itself.\n' +
        '    DO NOT use Amount for pipeline totals (it inflates multi-currency deals). DO NOT use Net_New_INR__c (zero for non-won).\n' +
        '    For MRR-based pipeline, use MRR_Amount__c.\n' +
        '  DATE FILTER FOR PIPELINE: Pipeline/funnel = CURRENT STATE of deals. Do NOT add date filters by default.\n' +
        '    "Total pipeline" / "current pipeline" / "pipeline this year" = all currently open deals, NO date filter.\n' +
        '    Pipeline is a SNAPSHOT, not a historical query. A deal in Negotiation IS this year\'s pipeline regardless of when it was created.\n' +
        '    ONLY add a date filter if user explicitly asks WHEN deals were created: "pipeline created this quarter" → filter by CreatedDate.\n' +
        '    NEVER use ISQL_Accepted_Date__c as a date filter for general pipeline queries.\n' +
        '  FORECAST CATEGORY: Forecast_Category__c has values: Pipeline, Upside, Commit\n' +
        '    "forecast pipeline" / "forecasted deals" / "total forecast pipeline" → Forecast_Category__c = \'Upside\' + open funnel stages, NO date filter.\n' +
        '      This is the subset of open pipeline that sales leadership considers likely to close. Matches CRM Buddy Booking Forecast.\n' +
        '    "commit deals" / "committed pipeline" → Forecast_Category__c = \'Commit\' + open funnel stages\n' +
        '    "upside" / "upside pipeline" → Forecast_Category__c = \'Upside\' + open funnel stages\n' +
        '    "weighted pipeline" → Forecast_Category__c IN (\'Upside\',\'Commit\') + open funnel stages\n' +
        '  Group by: StageName, Account_Cluster__c, Account_Region__c, Forecast_Category__c, Owner.Name, SKU__c\n' +
        '  Example: SELECT Account_Cluster__c, StageName, COUNT(Id) cnt, SUM(Normalize_Amount_INR__c) pipelineValue\n' +
        '    FROM Opportunity WHERE StageName IN (\'Prospect\',\'Approach\',\'Proposal\',\'Negotiation\',\'SDF Submission\',\'On Hold\',\'Closed won - Pending\')\n' +
        '    GROUP BY Account_Cluster__c, StageName ORDER BY SUM(Normalize_Amount_INR__c) DESC LIMIT 2000\n' +
        '  ACCEPTED PIPELINE / OPPORTUNITY ANALYSIS (Tableau "Accepted" view):\n' +
        '    Triggered when user says "accepted pipeline", "opportunity analysis", "accepted deals", or "ISQL accepted".\n' +
        '    Uses the CRM Buddy Calculated_ISQL_Date logic (CASE by ISQL_Stage__c):\n' +
        '      ISQL Accepted → date = ISQL_Accepted_Date__c\n' +
        '      ISQL Pending → date = Created_Date__c (formula: COALESCE of Actual_Created_Date, CreatedDate)\n' +
        '      ISQL Rejected → date = ISQL_Rejected_Date__c\n' +
        '    For "accepted pipeline this FY": filter by ISQL_Accepted_Date__c in FY, use Pipeline stages (excl Suspect/Rejected/SDF Rejected).\n' +
        '    NOT for general pipeline queries.\n' +
        '\n' +
        'SLANG / ABBREVIATION MAPPINGS (CRM Buddy Mapping Dictionary — AUTHORITATIVE SOURCE):\n' +
        '  === OPPORTUNITY DOMAIN ===\n' +
        '  Region: "Dom"/"Domestic" → Domestic Enterprise, "Int" → International, "Scaleup" → Scaleup, "Internal" → Internal\n' +
        '  Cluster: "BI" → Banking and Insurance, "FS" → Financial Services, "Tech" → Technology,\n' +
        '    "Marketplace" → Marketplace, "Mobility" → Mobility, "Partnerships" → Partnerships,\n' +
        '    "Retail" → Retail, "Services" → Services, "Africa" → Africa, "Romena" → Romena,\n' +
        '    "APAC" → APAC, "UAE" → UAE, "US" → US, "KSA" → KSA, "SMB" → SMB, "Mid Market" → Mid Market, "Internal" → Internal\n' +
        '  Parent SKU: "AI" → Gen AI, "ECC" → Contact Centre (or Contact Center)\n' +
        '  Deal Category: "Subscription"/"Subs"/"Sub" → Subscription, "OT" → One Time\n' +
        '  Voice Commit: "Commit Deal"/"Commit Deals"/"Commit" → Voice Commit Deals, "Non Commit" → Voice Non-Commit Deals\n' +
        '  Reversal: "Reversals"/"Reversal" → includes both Partial Reversal AND Reversal Reversal\n' +
        '  === REVENUE DOMAIN (accounts_revenue__c) ===\n' +
        '  Region: "Domestic"/"Dom" → Domestic Enterprise, "Int" → International, "Scaleup" → Scaleup\n' +
        '  Cluster: "BI" → Banking and Insurance, "FS" → Financial Services, "Marketplace" → Marketplace, "Tech" → Technology\n' +
        '  Parent SKU: "Contact Centre"/"Contact Center" → Contact Centre / Contact Center, "Voice" → Voice, "AI"/"Gen AI" → Gen AI\n' +
        '  SKU: "ECC" → Enterprise CC, "PF Voice" → PF Voice\n' +
        '  Revenue Classification: "Net New" → Revenue_Classification__c IN (Scaleup1, Scaleup2, Retention1, Retention2), "Organic" → Retention3\n' +
        '  Churn: "Churn"/"Churned" → Account.Account_Status__c = \'Churned\'\n' +
        '  At Risk: "At Risk"/"Likely to churn" → Account.RAG__c = \'RED\'\n' +
        '  Math rules (compute in summary, NOT in SOQL):\n' +
        '    "GP Margin"/"Margin" = SUM(GP__c) / SUM(Revenue_Booked_Amount__c)\n' +
        '    "MTD Margin" = SUM(MTD GP) / SUM(MTD Revenue), same pattern for LM/R3M/R6M/R12M\n' +
        '  Time-period slang (translate to Revenue_Booked_On__c date ranges):\n' +
        '    "MTD" = Month-to-Date, "QTD" = Quarter-to-Date, "LM" = Last Month,\n' +
        '    "L3M" = prior 3 months, "L6M" = prior 6 months,\n' +
        '    "R3M"/"Rolling 3 Months" = trailing 3 months incl current, "R6M" = trailing 6, "R12M" = trailing 12\n\n' +
        'AVERAGE DEAL SIZE: SUM(Normalize_Amount_INR__c)/COUNT(Id) for pipeline, SUM(Net_New_INR__c)/COUNT(Id) for bookings — compute in summary, not in SOQL.\n' +
        'SALES CYCLE: AVG of (CloseDate - CreatedDate) — SOQL cannot do date arithmetic. Fetch both dates, compute in summary.\n\n' +
        '=== MULTI-QUERY ANALYTICS ===\n' +
        'For computed metrics (ratios, rates, growth, comparisons), generate MULTIPLE queries.\n' +
        'Each query goes in its own ```soql block with a -- comment label above it.\n' +
        'The summary step will join results across queries and compute the metric.\n\n' +
        'WHEN to use multiple queries:\n' +
        '- Win/conversion rate: Q1=won deals, Q2=all consumed deals\n' +
        '- Period comparison: Q1=current period, Q2=previous period\n' +
        '- Segment benchmark: Q1=specific segment, Q2=overall\n' +
        '- Any metric that is a RATIO of two different filtered datasets\n' +
        '- Cross-object analytics: Q1=Opportunity data, Q2=accounts_revenue__c data\n\n' +
        'WHEN single query is sufficient:\n' +
        '- Data fetch (deal lists, account details)\n' +
        '- Simple aggregation (total revenue, count by status)\n' +
        '- Single GROUP BY that captures all needed dimensions\n' +
        '- Win rate where StageName is in both SELECT and GROUP BY (single-query pattern above)\n\n' +
        'Example — Win rate by cluster (FY2025) using multi-query:\n' +
        '-- Query 1: Won deals by cluster\n' +
        '```soql\n' +
        'SELECT Account_Cluster__c, SUM(Amount) wonValue, COUNT(Id) wonCount\n' +
        'FROM Opportunity WHERE StageName = \'Order\'\n' +
        'AND CloseDate >= 2025-04-01 AND CloseDate <= 2026-03-31\n' +
        'GROUP BY Account_Cluster__c LIMIT 2000\n' +
        '```\n\n' +
        '-- Query 2: All consumed deals by cluster\n' +
        '```soql\n' +
        'SELECT Account_Cluster__c, SUM(Amount) totalValue, COUNT(Id) totalCount\n' +
        'FROM Opportunity WHERE StageName IN (\'Order\',\'Closed Lost\',\'Closed-No decision\',\'Closed Unknown\',\'Closed Duplicate\',\'Rejected\',\'SDF Rejected\')\n' +
        'AND CloseDate >= 2025-04-01 AND CloseDate <= 2026-03-31\n' +
        'GROUP BY Account_Cluster__c LIMIT 2000\n' +
        '```\n\n' +
        'Example — YoY growth comparison:\n' +
        '-- Query 1: Current FY revenue\n' +
        '```soql\n' +
        'SELECT Customer_Universal_Account__r.Cluster__c cluster, SUM(Revenue_Booked_Amount__c) currentRev\n' +
        'FROM accounts_revenue__c WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-31\n' +
        'GROUP BY Customer_Universal_Account__r.Cluster__c LIMIT 2000\n' +
        '```\n\n' +
        '-- Query 2: Previous FY revenue\n' +
        '```soql\n' +
        'SELECT Customer_Universal_Account__r.Cluster__c cluster, SUM(Revenue_Booked_Amount__c) prevRev\n' +
        'FROM accounts_revenue__c WHERE Revenue_Booked_On__c >= 2024-04-01 AND Revenue_Booked_On__c <= 2025-03-31\n' +
        'AND Customer_Universal_Account__c != null\n' +
        'GROUP BY Customer_Universal_Account__r.Cluster__c LIMIT 2000\n' +
        '```\n\n' +
        '=== CURRENCY ===\n' +
        'Net_New_INR__c on Opportunity is ALREADY normalized to INR — BUT only populated for WON deals (Stage=Order).\n' +
        '  USE Net_New_INR__c for: bookings, order value, won deal rankings, revenue from Opportunity.\n' +
        '  DO NOT use Net_New_INR__c for: pipeline value, win rate denominators, lost deal analysis (it will be 0).\n' +
        '  For pipeline/open deals: use Amount (auto-converted by SF multi-currency) or MRR_Amount__c.\n' +
        '  NEVER filter by CurrencyIsoCode and NEVER GROUP BY CurrencyIsoCode for rankings.\n' +
        '  ALWAYS include ALL regions (Domestic + International + ME + Africa) by default.\n' +
        '  Only add CurrencyIsoCode to SELECT for deal-level detail views.\n' +
        '  Only GROUP BY CurrencyIsoCode when user EXPLICITLY asks to split by currency.\n' +
        'Amount/Net_New__c are in NATIVE currency — only use for single-currency queries.\n' +
        'Conversion rates vary by context:\n' +
        '  Tableau Booking dashboard: 1 USD=85 INR, 1 AED=22 INR\n' +
        '  Tableau Revenue dashboard (Actual): 1 USD=80 INR\n' +
        '  Tableau Revenue dashboard (Normalized): 1 USD=75 INR\n' +
        '  For Ask SF summary display: use 1 USD=83 INR, 1 AED=23 INR as working average.\n\n' +
        '=== REVENUE DEFINITION (TWO SOURCES) ===\n' +
        '** SOURCE 1 - REPORTED REVENUE (DEFAULT for "revenue" questions): **\n' +
        '  Object: accounts_revenue__c\n' +
        '  Value Field: Revenue_Booked_Amount__c (Label: Reported Rev Amount)\n' +
        '  ⚠️ GOVERNOR LIMIT (CRITICAL): ~8,000 records/month, 100K+/year. Apex limit = 50K rows/transaction.\n' +
        '    RULE: Apex AUTO-SPLITS queries spanning >6 months into H1/H2 chunks.\n' +
        '    You can write a SINGLE full-year query — Apex handles the split automatically.\n' +
        '    Example for "revenue this year" (FY2026 = Apr 2025 - Mar 2026):\n' +
        '    ```soql\n' +
        '    SELECT Customer_Universal_Account__r.Cluster__c cluster, SUM(Revenue_Booked_Amount__c) rev\n' +
        '    FROM accounts_revenue__c\n' +
        '    WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-31\n' +
        '    AND Customer_Universal_Account__c != null\n' +
        '    GROUP BY Customer_Universal_Account__r.Cluster__c\n' +
        '    ```\n' +
        '    Apex auto-splits this into H1 (Apr-Sep) + H2 (Oct-Mar) and merges results.\n' +
        '    ALWAYS use GROUP BY with SUM/COUNT aggregates.\n' +
        '    NEVER write detail-level SELECT — it WILL crash.\n' +
        '    ⚠️ DATE FILTER RULE: Use EXACTLY ONE date range pair: Revenue_Booked_On__c >= start AND Revenue_Booked_On__c <= end.\n' +
        '    NEVER add a second/redundant Revenue_Booked_On__c filter. The FY range is sufficient — no extra lookback needed.\n' +
        '    ⚠️ THIS RULE APPLIES TO ALL VALUE FIELDS: Revenue_Booked_Amount__c, GP__c, Variable_Cost__c, Fixed_Cost__c, Total_Cost__c.\n' +
        '  CURRENCY NOTE: Revenue_Booked_Amount__c AND GP__c are in NATIVE currency (INR for domestic, USD for intl).\n' +
        '    Tableau converts USD×80 for "Actual" view. For cross-region totals, ALWAYS include Currency__c in SELECT\n' +
        '    and let the summary step apply conversion (1 USD=83 INR, 1 AED=23 INR).\n' +
        '  CUSTOMER RANKING: For "top customers" queries, use Customer_Universal_Account__r.Name (NOT Account__r.Name, NOT Customer_Name__c).\n' +
        '    ⚠️ CRITICAL: Account__c is the Setup/Tenant account (7,887 records). Customer_Universal_Account__c is the\n' +
        '    Universal Customer Account (6,231 records) that properly rolls up multiple setups/tenants into one customer.\n' +
        '    ALWAYS use Customer_Universal_Account__r.Name for customer-level aggregation.\n' +
        '    Add "Customer_Universal_Account__c != null" in WHERE to exclude orphan records.\n' +
        '    ⚠️ KEEP IT SIMPLE: GROUP BY ONLY Customer_Universal_Account__r.Name. Do NOT add SKU, Cluster, Currency, or any other dimension.\n' +
        '    Adding extra dimensions splits each customer into multiple rows and produces WRONG totals.\n' +
        '    Only add extra dimensions if user explicitly asks (e.g., "top customers by SKU").\n' +
        '    Example — "top 10 customers by revenue":\n' +
        '    ```soql\n' +
        '    SELECT Customer_Universal_Account__r.Name acctName, SUM(Revenue_Booked_Amount__c) rev\n' +
        '    FROM accounts_revenue__c\n' +
        '    WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-31\n' +
        '    AND Customer_Universal_Account__c != null\n' +
        '    GROUP BY Customer_Universal_Account__r.Name\n' +
        '    ORDER BY SUM(Revenue_Booked_Amount__c) DESC LIMIT 10\n' +
        '    ```\n' +
        '  Date Field: Revenue_Booked_On__c\n' +
        '  Cluster/Sector: Customer_Universal_Account__r.Cluster__c (from Universal Account — matches Tableau)\n' +
        '    ⚠️ NEVER use Cluster__c or Region__c directly on accounts_revenue__c for grouping/filtering — they do not match Tableau.\n' +
        '    ALWAYS use Customer_Universal_Account__r.Cluster__c and Customer_Universal_Account__r.Region__c.\n' +
        '    ALWAYS add Customer_Universal_Account__c != null in WHERE when using Universal Account fields.\n' +
        '  Other fields: SKU__c, Products__c, Region__c, Classification__c,\n' +
        '    Revenue_Classification__c, Account__c(Setup/Tenant lookup), Customer_Universal_Account__c(Universal Customer lookup — USE THIS for customer rollups),\n' +
        '    Customer_Name__c(string — often NULL, avoid), CSM__c(lookup — often System Admin, unreliable),\n' +
        '    Account_Manager__c(lookup — ⚠️ JUNK DATA: populated with "System Admin" for nearly all records. NEVER use for AM queries),\n' +
        '    Norm_Rev_Amount__c,\n' +
        '  ACCOUNT MANAGER / ACCOUNT OWNER: For "account manager", "AM", "AD", "account director", "portfolio owner" queries:\n' +
        '    Use Customer_Universal_Account__r.Owner.Name (the Account Owner on the Universal Account).\n' +
        '    ⚠️ NEVER use Account_Manager__c on accounts_revenue__c — it contains "System Admin" and is useless.\n' +
        '    Example — "top AMs by revenue":\n' +
        '    ```soql\n' +
        '    SELECT Customer_Universal_Account__r.Owner.Name am, SUM(Revenue_Booked_Amount__c) rev\n' +
        '    FROM accounts_revenue__c\n' +
        '    WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-31\n' +
        '    AND Customer_Universal_Account__c != null\n' +
        '    GROUP BY Customer_Universal_Account__r.Owner.Name\n' +
        '    ORDER BY SUM(Revenue_Booked_Amount__c) DESC LIMIT 10\n' +
        '    ```\n' +
        '    Product_Type__c, AOP_Category__c, Revenue_Attribution__c,\n' +
        '    Variable_Cost__c, Fixed_Cost__c, Total_Cost__c, GP__c,\n' +
        '    Parent_SKU__c, Rev_Source__c, Rev_Sub_Source__c, Currency__c\n' +
        '  Parent_SKU__c VALUES (use EXACT match, NEVER LIKE): Voice, Contact Centre, SMS, Whatsapp, Truecaller, Gen AI\n' +
        '    "voice revenue" → Parent_SKU__c = \'Voice\' (NOT LIKE — LIKE catches Voice Streaming, Voicebot etc.)\n' +
        '    "CC revenue"/"contact centre" → Parent_SKU__c = \'Contact Centre\'\n' +
        '    "SMS revenue"/"messaging" → Parent_SKU__c = \'SMS\'\n' +
        '    "WhatsApp revenue" → Parent_SKU__c = \'Whatsapp\'\n' +
        '    "AI revenue"/"gen AI" → Parent_SKU__c = \'Gen AI\'\n' +
        '  SKU__c VALUES (finer grain): PF Voice, PF Others, PF Messaging SMS, Enterprise CC,\n' +
        '    PF Messaging Whatsapp, PF Voice CC, PF Others TC, Conversational AI,\n' +
        '    Voice Streaming, Chatbot, CQA, Voicebot, PF Messaging Others, PF Messaging RCS, VSIP\n' +
        '    DEFAULT: Always use Parent_SKU__c when user says "by SKU", "SKU view", "product breakdown", "by product".\n' +
        '    Parent_SKU__c is the standard dashboard grouping (Voice, Contact Centre, SMS, Whatsapp, Truecaller, Gen AI).\n' +
        '    Only use SKU__c if user explicitly says "detailed SKU", "sub-SKU", or names a specific SKU like "PF Voice" or "Enterprise CC".\n' +
        '  IMPORTANT: For product filtering, ALWAYS use = (exact match) on Parent_SKU__c.\n' +
        '    NEVER use LIKE with wildcards for SKU/Parent_SKU — values are exact picklist entries.\n' +
        '  Formula fields (NO GROUP BY): Account_Region__c, Universal_Acc_Cluster__c,\n' +
        '    Universal_Acc_AM__c, Account_Geography__c, Total_Rev_break_Amount__c\n\n' +
        '** SOURCE 2 - ORDER BOOKINGS (for "bookings", "deals won", "order value"): **\n' +
        '  Object: Opportunity\n' +
        '  Stage Filter: StageName IN (\'Order\',\'POC\')\n' +
        '  Date Field: B_Deal_Date__c (NOT CloseDate)\n' +
        '  Value Field: Net_New_INR__c (formula, already in INR)\n' +
        '  ⚠️ DO NOT exclude negative values: NEVER add "AND Net_New_INR__c >= 0". Negative values (reversals) are part of the booking total.\n' +
        '  ⚠️ DO NOT include Opportunity_Line_Item_Count__c. No dedup needed — SUM(Net_New_INR__c) gives the correct total directly.\n' +
        '  KEEP IT SIMPLE: Just SUM(Net_New_INR__c) with the stage and date filters. No extra filters, no dedup.\n\n' +
        'DEFAULT: Use accounts_revenue__c for revenue questions unless user\n' +
        '  specifically asks about deals/bookings/pipeline/opportunities.\n' +
        'SECTOR queries: Use Customer_Universal_Account__r.Cluster__c on accounts_revenue__c, or Account_Cluster__c on Opportunity.\n' +
        '⚠️ REGION vs CLUSTER DISAMBIGUATION (critical — gets confused often):\n' +
        '  On accounts_revenue__c: use Customer_Universal_Account__r.Region__c (3 values) and Customer_Universal_Account__r.Cluster__c (22 values).\n' +
        '  On Opportunity: use Account_Region__c and Account_Cluster__c.\n' +
        '  "Scaleup"/"Scaleups"/"Scale" → Region = \'Scaleup\'.\n' +
        '  "Domestic"/"Dom" → Region = \'Domestic Enterprise\'.\n' +
        '  "International"/"Intl" → Region = \'International\'.\n' +
        '  "BFSI"/"Retail"/"APAC"/"SME"/"Technology"/etc. → Cluster.\n' +
        '  RULE: On accounts_revenue__c, use Customer_Universal_Account__r.Region__c / Customer_Universal_Account__r.Cluster__c.\n' +
        '  On Opportunity, use Account_Region__c / Account_Cluster__c. Never use bare Cluster__c or Region__c on revenue.\n' +
        '  REGION CONSOLIDATION (Opportunity): Account_Region__c has 4 standard values: Domestic Enterprise, International, Scaleup, Internal.\n' +
        '    "Americas" → treat as International. In summary, merge Americas deals into International.\n' +
        '    NULL/blank region → attribute to the closest region based on Account_Cluster__c, or show as "Untagged" only if significant.\n' +
        '    Tableau only shows 4 regions — our output should match.\n\n' +
        '=== OPPORTUNITY (341 fields) ===\n' +
        'Standard: Id, Name, AccountId, OwnerId, StageName, Amount, CloseDate, CreatedDate,\n' +
        '  LastModifiedDate, IsClosed, IsWon, Probability, Type, LeadSource, Description,\n' +
        '  ForecastCategoryName, LastStageChangeDate(DateTime!), LastActivityDate, NextStep,\n' +
        '  CampaignId, CurrencyIsoCode, HasOpportunityLineItem, RecordTypeId\n\n' +
        'Custom Number: MRR_Amount__c(MRR,NUMBER not Currency,88% filled), One_Time_Value__c(100% filled),\n' +
        '  Net_New__c, Full_Potential_Value__c(39% filled — use with caution),\n' +
        '  Opportunity_Line_Item_Count__c(rollup count — DO NOT use for dedup, not needed)\n' +
        'UNRELIABLE Opp fields (<5% fill — NEVER use for ranking/aggregation):\n' +
        '  Committed_Booking_Value__c(5%), Channels_Count__c(3%), DID_Count__c(3%),\n' +
        '  Number_of_seats__c(0%), Seats_Count__c(does not exist on Opp)\n' +
        'Custom Picklist: Deal_Type__c(Subscription|On-Premise|Onetime_Customisation|AMC),\n' +
        '  Classification_Type__c(New Sales|Up sell|Cross sell|AMC Renewal|etc),\n' +
        '  Account_Region__c(Scaleup|Domestic Enterprise|International),\n' +
        '  Account_Cluster__c, Loss_Reason__c, Loss_Theme__c, Win_Reasons__c, Win_Theme__c,\n' +
        '  CH_Forecast__c, Commit_Status__c, Deal_Category__c, Deal_Circle__c,\n' +
        '  Deal_Request_Type__c, Existing_Customer_or_Not__c, Forecast_Category__c,\n' +
        '  SKU__c, Product_Dimension__c, Sub_Stage__c, Telephony__c, Telephony_Provided__c,\n' +
        '  Use_Case__c, Sales_Status__c, ISQL_Stage__c, Reversal_Type__c, Lead_Campaign_Type__c\n' +
        'Multi-Picklist (MUST use INCLUDES): Product_Type__c, Type_of_Solution__c, Competition__c,\n' +
        '  CRM_3rd_Party__c, PBX_Integration__c, Custom_use_cases__c, Pricing_Model__c,\n' +
        '  Setups__c, Lead_Products__c\n' +
        'Date: B_Deal_Date__c(Booking date - USE FOR REVENUE QUERIES), Deployment_Date__c,\n' +
        '  Expected_Close_Date__c, Actual_Closed_Date__c, Order_Stage_Date__c,\n' +
        '  Negotiation_Stage_Date__c, Proposal_Stage_Date__c, Prospect_Stage_Date__c,\n' +
        '  Approach_Stage_Date__c, POC_Stage_Date__c\n' +
        'Text: Country__c, Tenant_Name__c, Partner_Name__c\n' +
        'Checkbox: Is_From_Lead_Conversion__c, Converted_Opportunity__c, Decision_Maker_Identified__c,\n' +
        '  Discovery_Completed__c, Executive_Engagement__c, ROI_Analysis_Completed__c,\n' +
        '  Veeno__c, Is_Short_Rental__c\n' +
        'Lookup: Product_Specialist__c(User/Pre-Sales), Co_owner__c(User/CSM), Lead__c(Lead),\n' +
        '  Lead_Created_By__c(User), Owner_Manager__c(User)\n' +
        'Formula(read-only,NO GROUP BY): Net_New_INR__c(Net New INR - ONLY for WON deals/bookings, ZERO for pipeline/lost),\n' +
        '  Opportunity_Line_Item_Count__c(line item count — NOT needed for booking queries),\n' +
        '  Amount_INR__c, Amount_USD__c, Norm_MRR__c, Total_Amount__c,\n' +
        '  Sales_Cycle__c, Business_Unit__c, Cluster__c, Region__c, Stage_Name__c,\n' +
        '  Source_Type__c, Age__c, Last_Activity_Since__c\n\n' +
        'STAGE VALUES & GROUPINGS (aligned with CRM Buddy definitions):\n' +
        '  Pre-qualification: Suspect (NOT pipeline — pre-qualification only).\n' +
        '  Pipeline/Funnel (active): Approach, Prospect, Proposal, Negotiation, SDF Submission, POC, On Hold, Closed won - Pending.\n' +
        '  Booking/Won: Order (NOT "Closed Won"). POC also maps to Booking stage in CRM Buddy.\n' +
        '  Lost: Closed Lost, Closed-No decision, Closed Unknown, Closed Duplicate, Rejected, SDF Rejected, POC Closed.\n' +
        '  Total Funnel: Pipeline + Booking + Lost — everything except Suspect.\n' +
        'RecordTypes: Amendment Type, CPQ Existing Customer Type, CPQ New Customer Type,\n' +
        '  Existing Customer Type, New Customer Type, New Prospect, Renewal Type\n\n' +
        'SALES REP RANKINGS: When ranking "sales reps" or "top performers", ALWAYS exclude non-sales roles:\n' +
        '  ADD: AND Owner.UserRole.Name != \'Super User\' AND Owner.Profile.Name != \'System Administrator\'\n' +
        '  "Super User" / "System Administrator" are admin accounts — their deals are data artifacts, not real sales.\n' +
        '  Sales roles contain: Sales_, AM (e.g. SME Funded AM, APAC AM, ROW AM, UAE AM), Inside Sales.\n' +
        '  CX/CSM roles (CX_, CSM) are Customer Success — include ONLY if user asks about CX/CSM performance.\n\n' +
        '=== CASE (557 fields) — Support Tickets ===\n' +
        'NATURAL LANGUAGE → QUERY MAPPING (users may say ANY of these):\n' +
        '  "Ameyo Care"/"ECC tickets"/"contact center tickets"/"Ameyo tickets"/"CC tickets"\n' +
        '    → RecordType.Name IN (\'Normal Support\',\'Change Management\',\'RCA\',\'Release Upgrade\')\n' +
        '  DISAMBIGUATION: "ECC revenue"/"ECC bookings" → Opportunity/accounts_revenue__c with Parent_SKU__c=\'Contact Centre\' (NOT Case).\n' +
        '    "ECC tickets"/"ECC support" → Case object. Context determines which object to query.\n' +
        '  "Platform tickets"/"voice tickets"/"Exotel tickets"/"exolite"/"platform issues"\n' +
        '    → RecordType.Name = \'Platform Support\'\n' +
        '  "AI tickets"/"Cogno tickets"/"chatbot tickets"/"bot issues"/"Cogno AI"/"conversational AI tickets"\n' +
        '    → RecordType.Name = \'CognoAI\'\n' +
        '  "support tickets"/"customer issues"/"cases"/"complaints"/"bugs"/"issues" (generic)\n' +
        '    → ALL active ticket record types (no RecordType filter, or broad filter)\n' +
        '  "escalated tickets"/"escalations" → Is_Jira_Escalated__c = true OR RecordType.Name = \'Escalation\'\n' +
        '  "Jira tickets"/"Jira escalated" → Is_Jira_Escalated__c = true\n' +
        '  "SLA breached"/"SLA violated"/"missed SLA" → SLA_Violated__c = true OR Overall_SLA__c = \'Not_Met\'\n' +
        '  "new tickets" → Status = \'New\'\n' +
        '  "open tickets"/"active tickets"/"unresolved" → Status IN (\'New\',\'Open\',\'Note_added\',\'Re-Open\',\'Pending\')\n' +
        '  "pending tickets"/"waiting"/"blocked" → Status = \'Pending\'\n' +
        '  "resolved tickets"/"fixed"/"done" → Status = \'Resolved\'\n' +
        '  "closed tickets"/"completed" → Status IN (\'Close_successful\',\'Close_unsuccessful\')\n' +
        '  "critical tickets"/"P1"/"urgent"/"high priority" → Priority IN (\'Critical\',\'P1\',\'Urgent\')\n' +
        '  "FLR tickets"/"first level" → Owner.Name LIKE \'%FLR%\' OR SAAS_Team_Ownership__c = \'SAAS FLR\'\n' +
        '  "TNR tickets"/"second level" → Owner.Name LIKE \'%TNR%\' OR SAAS_Team_Ownership__c = \'SAAS TNR\'\n' +
        '  "L3 tickets"/"third level"/"engineering" → Owner.Name LIKE \'%L3%\'\n' +
        '  "ticket age"/"aging"/"old tickets"/"stale" → use Age_in_min__c for calculations\n' +
        '  "resolution time"/"MTTR"/"time to resolve" → use Resolution_Time_Minutes__c\n' +
        '  "customer pending"/"waiting on customer" → Status = \'Waiting on Customer (New)\' or Customer_pending_hours__c\n' +
        '  "ticket volume"/"inflow"/"created" → COUNT + GROUP BY CreatedDate (use CALENDAR_MONTH/CALENDAR_YEAR)\n' +
        '  "resolved rate"/"closure rate" → compare resolved vs created counts\n' +
        '  "top accounts by tickets"/"noisiest customers" → GROUP BY Account.Name ORDER BY COUNT(Id) DESC\n' +
        '  Do NOT add test-account exclusion filters — the data is already clean enough.\n\n' +
        '  "Ticket Number"=CaseNumber, "Ticket Status"=Status, "Ticket Owner"=Owner.Name.\n\n' +
        'Standard: Id, CaseNumber, Subject, Status, Priority, Origin, Type, Reason, CreatedDate,\n' +
        '  ClosedDate, IsClosed, IsEscalated, IsStopped, StopStartDate(DateTime), AccountId,\n' +
        '  ContactId, OwnerId, ParentId, Description, RecordTypeId\n\n' +
        'Custom Text: Queue__c(Queue picklist), Jira_Ticket_Key__c, Support_Group__c(String),\n' +
        '  AMC_Type__c, Customer_Name__c, Account_SID__c\n' +
        'Custom Number: Customer_pending_hours__c(100% filled), Escalation_Level__c(1-4),\n' +
        '  Incident_duration__c(Min), Actual_Efforts__c, Age_in_min__c(formula-USE FOR AGE CALCS)\n' +
        'DEAD FIELD: Priority_Score__c(0% fill — NEVER query).\n' +
        'Custom Currency: Approved_MRR__c, Approved_OTC__c, Quoted_MRR__c, Quoted_OTC__c\n' +
        'Custom DateTime: First_Escalation_time__c, Second_Escalation_time__c,\n' +
        '  Third_Escalation_time__c, Fourth_Escalation_time__c, Ticket_Start_time__c,\n' +
        '  Ticket_End_time__c, Date_Resolved__c(WHEN RESOLVED), Ticket_Resolution_Time__c(DateTime),\n' +
        '  First_Resolution_Time__c, L4_Resolution_Date_time__c, JIRA_Escalated_Date__c\n' +
        'Custom Date: Delivery_Date__c, Deployment_Date__c, Deployment_Start__c, Deployment_End__c,\n' +
        '  APC_Parked_Ticket_Resolution_Date__c\n' +
        'Checkbox: Is_Jira_Escalated__c, Is_escalated__c, SLA_Violated__c, Activity__c\n' +
        'Picklist: Jira_Issue_Type__c, Jira_Ticket_Priority__c, Escalation_Closer_Type__c,\n' +
        '  Is_Escalation_Valid__c, Category__c,\n' +
        '  Issue_Category__c(82 vals: ACP Issue|Agent UI/Functionality issue|Application Issue|\n' +
        '    Calling issue|Change Request|DNC India|Enquiry|Fusion|HA Issues|IVR|License Issue|\n' +
        '    Maintenance Issues|Product Functionality Issue|Report Issue|Others...),\n' +
        '  Issue_Sub_category__c(300+ vals), Issue_type__c(Technical Issue|Product Usage|\n' +
        '    Billing and Account related|Downtime|Escalation|GP Queries|Churn Request),\n' +
        '  Customer_Issue_Category__c, Customer_Issue_Sub_category__c,\n' +
        '  Cogno_Issue_Category__c, Cogno_Sub_Category__c,\n' +
        '  Product_Type__c(Picklist NOT multi: Enterprise CC|Platform),\n' +
        '  Product_SKU__c(Voice|Campaign|Exolite|Chat|Phone|Messaging|Whatsapp|Streaming|etc),\n' +
        '  Product_Type_AI__c(Chatbot|LiveChat|Campaigns|Cobrowse|All),\n' +
        '  Impact__c, Overall_SLA__c(Met|Not_Met),\n' +
        '  SLA_Violation_Reason__c(Product Delay|Process Gap|Engineer\'s Delay|Resources Capacity Issue|Customer Delay|Third Party Delay),\n' +
        '  First_Contact_resolution__c, Ticket_resolution_team__c(L1 Team|L2 Team|L3 Team),\n' +
        '  Resolution_expected_from__c(Exotel|Client),\n' +
        '  SAAS_Team_Ownership__c(SAAS FLR|SAAS TNR),\n' +
        '  Accounts_Billing__c, Delivery_Type__c, Change_Type__c,\n' +
        '  CM_Phase__c(Initiation|Planning|Scheduling|Execution|Monitoring),\n' +
        '  Downtime_Type__c(Customer End|Issue End|Maintenance|No Downtime),\n' +
        '  Environment__c(UAT|Production),\n' +
        '  RCA_Issuetype__c(Software|Support/Setup|Usability|Environment|Hardware|IT Issue|etc),\n' +
        '  RCA_Category__c(45 vals), RCA_Sub_category__c(182 vals),\n' +
        '  Cogno_Services__c, Source_of_Jira_Ticket__c\n' +
        'Multi-Picklist(INCLUDES): ECC_Termination__c(Cloud Termination|Call Server|DID|Cross Connect|Telephony),\n' +
        '  CRM_3rd_Party__c, Competition__c\n' +
        'Lookup: First_Escalation_ticket_owner__c(User), Second_Escalation_ticket_owner__c(User),\n' +
        '  Third_Escalation_ticket_owner__c(User), Fourth_Escalation_ticket_owner__c(User),\n' +
        '  FLR_User__c(User), Agent__c(User), Manager__c(User), Resolved_By__c(User)\n' +
        'Formula(NO GROUP BY/agg WHERE): Resolution_Time_Minutes__c(Number-USE FOR MTTR),\n' +
        '  Resolution_Time__c(DateTime), CM_Resolution_Level__c(Text), Total_Time__c(Text-no AVG),\n' +
        '  SLA__c(Text), Age_in_min__c(Number), Account_CSM__c, Account_Manager_Name__c, Acc_Setup_Type__c\n\n' +
        'MTTR: Use Resolution_Time_Minutes__c. "Without start/stop"→IsStopped=false. "With"→IsStopped=true.\n' +
        '  NO field MTTR__c or MTTR_Without_Start_Stop__c exists.\n' +
        'Status: New, Open, Pending, Note_added, Re-Open, Resolved, Resolved - RCA Pending,\n' +
        '  Close_successful, Close_unsuccessful, Approval Pending, In Progress,\n' +
        '  Waiting on Customer (New), Waiting on DRI (New), Waiting on Third party,\n' +
        '  Closed - No Response, Close - Not Approved, Closed, Closed from DRI,\n' +
        '  SUA Approved, Delivery - In Progress, Details Pending, Pending - FD\n' +
        'Origin: Email, Portal, Phone, Web, Platform-Chat, Platform-Voice, True Caller Email\n' +
        'Priority: Critical, Major, Minor (Ameyo Care primary); also Low, Medium, High, Urgent, P1, P2, P3\n\n' +
        'QUEUE FIELD: Queue__c picklist values: L1, L2, L3-Escalation, Classification, Hardware,\n' +
        '  License, Release Upgrade, Change-Mgmt, Customer Pending, Resolved Queue, Monitoring,\n' +
        '  Services Issues, DACX Support, Product Specialist Group, Documentation, etc.\n' +
        'OWNER QUEUE NAMES (filter via Owner.Name for team analysis):\n' +
        '  FLR: "FLR Support Queue", "SAAS FLR Queue"\n' +
        '  TNR: "TNR - Critical Queue", "TNR - Major Queue", "TNR - Minor Queue",\n' +
        '    "SAAS TNR Queue", "SAAS TNR Premium Critical/Major/Minor Queue",\n' +
        '    "SAAS TNR Standard Critical/Major/Minor Queue"\n' +
        '  L3: "L3 Support Queue", "L3 Escalation - Support"\n' +
        '  Other: "APC/AOC(Support)", "Classification/Helpdesk(Support)",\n' +
        '    "Change Management Queue", "Release Upgrade Queue", "Philippines Support",\n' +
        '    "Premium Support Queue", "Compass Queue"\n\n' +
        'RecordTypes: AOC Alerts, APC Alert, BIU, Change Management, CoC Tickets, Cogno Delivery,\n' +
        '  CognoAI, Compass, Consultancy, Conversation, Escalation, Feedback, GDPR,\n' +
        '  GP & Churn Request, Normal Support, Philippines Support, Platform Support,\n' +
        '  Premium Platform Support, Problem Management, Project Issues, PSG, RCA,\n' +
        '  Release Upgrade, SaaS Alerts, Service, Service Delivery, Service Issue,\n' +
        '  Service Project Delivery, Solutions Consultancy, SUAM, SUAM Exotel, Support,\n' +
        '  TrueCaller, TTSL\n\n' +
        'TICKET TYPE MAPPING (3 major product lines):\n' +
        '  "Ameyo Care"/"ECC tickets"/"contact center tickets" → RecordType IN (\'Normal Support\',\'Change Management\',\'RCA\',\'Release Upgrade\')\n' +
        '    Fields: Issue_Category__c, Issue_Sub_category__c, Queue__c, Priority(Critical/Major/Minor)\n' +
        '    YTD ~5000 tickets. Tracked in Ameyo Care dashboard.\n' +
        '  "Platform tickets"/"Voice tickets"/"Exotel tickets" → RecordType = \'Platform Support\'\n' +
        '    LARGEST volume (~19K YTD). Origin: Email(85%), Platform-Voice(10%), Platform-Chat(3%)\n' +
        '    Issue_Category__c: Phone, Cogno chat, SMS template, Voice over request\n' +
        '    Priority: Low(most), High, Medium. Product_SKU__c: Voice, Messaging, etc. (sparse fill)\n' +
        '  "AI tickets"/"Cogno tickets"/"chatbot tickets" → RecordType = \'CognoAI\'\n' +
        '    ~960 YTD. Use Cogno-specific fields:\n' +
        '    Cogno_Issue_Category__c: Incident(64%), Service Request(12%), Project Alerts(9%)\n' +
        '    Cogno_Services__c: Cogno ChatBot(37%), Cogno Campaigns Dashboard(16%), Cogno LiveChat(12%),\n' +
        '      Cogno WhatsApp Bot(5%), Cogno Campaigns API(3%), Cogno CoBrowse(2%)\n' +
        '    Cogno_Sub_Category__c: OTP Related Issues, Template Related Issue, Livechat Concurrency Issue, etc.\n' +
        '  Other record types: Service(703), SUAM(292), Service Delivery(224), Escalation(48), Support(1952)\n\n' +
        'AMEYO CARE DASHBOARD PATTERNS:\n' +
        '  New tickets: Status=\'New\', RecordType IN (\'Normal Support\',\'Change Management\',\'RCA\')\n' +
        '  Open tickets: Status IN (\'Open\',\'Note_added\',\'Re-Open\')\n' +
        '  Pending tickets: Status=\'Pending\'\n' +
        '  Resolved tickets: Status=\'Resolved\'\n' +
        '  FLR/TNR team tickets: RecordType=\'Normal Support\', Status NOT IN (\'Close Unsuccessful\',\'Close Successful\')\n' +
        '  L3 team tickets: RecordType IN (\'Change Management\',\'Normal Support\',\'Project Issues\',\'RCA\',\'Release Upgrade\')\n' +
        '  Created weekly: GROUP BY CreatedDate week + Priority, LAST 3 MONTHS\n' +
        '  Resolved weekly: GROUP BY Date_Resolved__c week + Priority\n' +
        '  Issue category breakdown: GROUP BY Account.Name + Issue_Category__c\n' +
        '  SLA analysis: Overall_SLA__c, SLA_Violated__c, SLA_Violation_Reason__c\n\n' +
        '=== ACCOUNT (249 fields) ===\n' +
        '⚠️ MANDATORY RULE: When user asks about "accounts", "customers", "customer details", ALWAYS filter by\n' +
        '  RecordType.Name = \'Customer Account\'. This is the ONLY record type that represents actual customers.\n' +
        '  Other record types (Setup Account, Tenant Account, PF Account, Group Account, Prospect Account, AI Account,\n' +
        '  Partnership Account) are internal/operational records and must NOT be shown unless user explicitly requests them.\n' +
        '  If no Customer Account exists for a query, tell the user: "I couldn\'t find a Customer Account for this."\n\n' +
        'Standard: Id, Name, Type, Industry, OwnerId, ParentId, Website, Phone, CreatedDate,\n' +
        '  LastModifiedDate, CurrencyIsoCode, RecordTypeId, AnnualRevenue, NumberOfEmployees,\n' +
        '  Description, BillingCity, BillingState, BillingCountry\n\n' +
        'Picklist: Business_Unit__c(Commercial South/North|Africa|APAC|ME|Europe|etc),\n' +
        '  Account_Category__c, Account_Status__c, Customer_Type__c, Customer_sentiment__c,\n' +
        '  Customer_Service_Type__c, Cluster__c, Sub_Cluster__c, Region__c, Geography__c,\n' +
        '  Country__c, Nature_of_Business_Category__c(Vertical), Nature_of_Business_Sub_category__c(Sub Vertical),\n' +
        '  Product__c, Setup_Type__c, Status__c, RAG__c(Red/Amber/Green), Support_Group__c,\n' +
        '  Cogno_Support_Group__c, Funding_Type__c, Partner_Type__c, Partner_Stages__c,\n' +
        '  Hypercare_active__c, Release_Version__c\n' +
        'Multi-Picklist(INCLUDES): Customer_Stage__c, Product_UseCase__c\n' +
        'Number: Support_Ticket_Inflow__c, Seats_Count__c\n' +
        'DEAD FIELDS (0% fill — NEVER query): Revenue_Growth__c, CSAT__c, NPS_Score__c.\n' +
        '  Expansion_Potential__c(1% fill). If user asks about CSAT/NPS, explain data is not tracked in Salesforce.\n' +
        'Date: Go_Live_Date__c, B_Deal_Date__c, Last_Revenue_Date__c, AMC_Expiry_Date__c\n' +
        'DateTime: Hypercare_Start_Date__c, Hypercare_End_Date__c\n' +
        'Checkbox: Is_ABM__c, Is_SAAS_Premium_Account__c, Top_Customer__c, SAAS_Enterprise_Account__c\n' +
        'Lookup: Account_CSM__c(User), APC_Primary_Owner__c(User), APC_Secondary_Owner__c(User),\n' +
        '  APC_TL_Owner__c(User), Universal_Account__c(Account)\n' +
        'Formula(NO GROUP BY): Churned_Day__c(Number NOT date)\n' +
        'RecordTypes: AI Account, Customer Account, Group Account, Partnership Account,\n' +
        '  PF Account, Prospect Account, Setup Account, Tenant Account\n\n' +
        '=== LEAD (307 fields) ===\n' +
        'Standard: Id, Name, FirstName, LastName, Company, Status, LeadSource, OwnerId,\n' +
        '  CreatedDate, LastModifiedDate, IsConverted, ConvertedDate, ConvertedAccountId,\n' +
        '  ConvertedContactId, ConvertedOpportunityId, Email, Phone, Industry, CurrencyIsoCode, RecordTypeId\n\n' +
        'Picklist: Lead_Type__c, Lead_Cluster__c, Geography__c, Campaign_Type__c, Deal_Circle__c,\n' +
        '  Deal_Status__c, Sales_Stage__c, Department__c, Persona__c, Seniority__c,\n' +
        '  Call_Status__c, Lead_Forecast_Category__c, Qualified_Deal__c, Reason_For_Dead__c,\n' +
        '  Nurture_Required__c, Current_CRM__c, CRM_Requested__c, Authority_c__c\n' +
        'Multi-Picklist(INCLUDES): Product__c, Customer_Use_Case__c, Competition__c,\n' +
        '  Type_of_Solution__c, PBX_Integration__c, Formfilling_Product__c\n' +
        'Number: MRR_Amount__c(1% fill-UNRELIABLE), One_Time_Amount__c(2% fill-UNRELIABLE),\n' +
        '  Budget_Amount__c(1% fill-UNRELIABLE), Number_of_seats__c\n' +
        'Date: Lead_Closure_Date__c, Future_Action_Date__c\n' +
        'Text: UTM_Campaign__c, UTM_Source__c, UTM_Medium__c, UTM_Content__c, UTM_Term__c,\n' +
        '  Lead_Number__c(AutoNumber)\n' +
        'Lookup: Campaign__c(Campaign), Account_Name__c(Account), Lead_Co_Owner__c(User),\n' +
        '  Product_Sale_Specialist__c(User)\n' +
        'SDR leads: Owner.UserRole.Name LIKE \'%SDR%\'\n' +
        'SDR-generated opps: LeadSource = \'IS Generated\'\n' +
        'ChatGPT leads: LeadSource = \'Answer Engine\', UTM_Campaign__c = \'chatgpt.com\'\n' +
        'RecordTypes: Inbound IS, InsideSales/Mkt, Sales\n' +
        'SDR PERFORMANCE: Do NOT rank SDRs by SUM(MRR_Amount__c) on Lead — fill rate is <10% org-wide.\n' +
        '  Instead measure SDR revenue contribution via downstream won Opportunities:\n' +
        '  Query: SELECT Lead_Created_By__c, Lead_Created_By__r.Name, COUNT(Id) deals,\n' +
        '    SUM(Net_New_INR__c) revenue FROM Opportunity\n' +
        '    WHERE LeadSource = \'IS Generated\' AND StageName IN (\'Order\',\'POC\')\n' +
        '    AND B_Deal_Date__c >= [date] GROUP BY Lead_Created_By__c, Lead_Created_By__r.Name\n' +
        '    ORDER BY SUM(Net_New_INR__c) DESC\n' +
        '  For lead volume/conversion: COUNT(Id) FROM Lead WHERE Owner.UserRole.Name LIKE \'%SDR%\'\n' +
        '    AND IsConverted=true GROUP BY OwnerId, Owner.Name.\n' +
        '  UNRELIABLE FIELDS on Lead: MRR_Amount__c(<10% filled), One_Time_Amount__c(<5% filled),\n' +
        '    Budget_Amount__c(<5% filled) — NEVER use these for ranking or performance metrics.\n\n' +
        '=== EVENT (Meetings/Activities) ===\n' +
        'Standard: Id, Subject(combobox), OwnerId, WhoId, WhatId, AccountId, ActivityDate(Date),\n' +
        '  StartDateTime(DateTime), EndDateTime(DateTime), DurationInMinutes, IsAllDayEvent,\n' +
        '  Location, Type, CreatedDate, LastModifiedDate, IsRecurrence, CurrencyIsoCode\n\n' +
        'Picklist: Meeting_Category__c, Meeting_Type__c, Meeting_Outcome__c(Opp Status),\n' +
        '  Call_Disposition__c, Sub_Disposition__c, Call_Type__c, Review_Type__c,\n' +
        '  Was_Expected_Outcome_Achieved__c, Was_the_Decision_Maker_Present_on_the_Ca__c, Status__c\n' +
        'Checkbox: Meeting_Attended__c(=productive meeting), New_Meeting__c, QBR_Document_Uploaded__c\n' +
        'Text: Region__c, Cluster__c, Business_Unit__c, Product_Interest__c\n' +
        'Number: Actual_Efforts__c\n' +
        'Lookup: Opportunity__c(Opportunity), Related_Account__c(Account), Related_Lead__c(Lead),\n' +
        '  Decision_Maker_s_Name__c(Contact), Review_Of__c\n' +
        'Notes(textarea): MOM_Notes__c, Briefing_Note__c, Expected_Outcome__c, Achieved_Outcome__c\n' +
        'MEETINGS: Count from Event. "Productive meetings"=Meeting_Attended__c=true.\n' +
        '  Filter by: Owner.Name(AD/CSM), Meeting_Category__c, Meeting_Type__c, Region__c, Cluster__c.\n' +
        '  Link to Account via AccountId or Related_Account__c.\n\n' +
        '=== USER ROLES (for team filtering via Owner.UserRole.Name) ===\n' +
        'Sales: Sales Head, Sales_BFSI/DNa/GSI/MRE/R&D/T&L/Technology + Manager variants\n' +
        'CX: CX_BFSI/DNa/GSI/MRE/R&D/T&L/Technology + Managers. CSM: CSM Head/Manager/User/Africa/ME/ROW/Indonesia/UAE\n' +
        'SDR: Domestic SDR, International SDR, Sales Development Head, Domestic/International SD Manager\n' +
        'Support: SAAS Engineer/Manager/TL, Ameyo Care Engineer/Manager/TL, APC AOC Support Engineer/TL/Manager\n' +
        'Presales: ECC Presales + FM&SME/Govt&IT/INT&Central/Strategic Large/Traditional&BFSI\n' +
        'International: International Sales Head/ME/Africa/APAC Phil/ROAPAC, ME/Africa Sales TL/User\n' +
        'Others: AI GTM Head/Manager/User, Platform GTM, Cogno Head/Manager/Cogno_Sales, CRO, Super User\n\n' +
        '=== PRODUCT NAME DICTIONARY ===\n' +
        'Product_Type__c(Opp) is multi-picklist. Map casual names to EXACT values using INCLUDES:\n' +
        '"voicebot"→INCLUDES(\'Conversational_AI-Voicebot\',\'Technology-Cogno_Voicebot\')\n' +
        '"chatbot"→INCLUDES(\'Conversational_AI-Chatbot\',\'Technology-Cogno_Chatbot\',\'AI - Chat Bot\')\n' +
        '"contact center"/"CC"/"Ameyo"→INCLUDES(\'Enterprise_CC-Ameyo\',\'Enterprise_CC-Ameyo_On_Cloud\',\n' +
        '  \'Enterprise_CC-Ameyo_Fusion_CX\',\'ECC_Ameyo_Emerge\',\'ECC_Ameyo_Engage\',\'ECC_Ameyo_Omni\',\n' +
        '  \'ECC_Ameyo_Fusion_CX\',\'CC - Ameyo On Cloud\')\n' +
        '"Emerge"→INCLUDES(\'ECC_Ameyo_Emerge\',\'Enterprise_CC-Ameyo Emerge\')\n' +
        '"XPress"→(\'Technology-Ameyo_XPress\'),"XPrime"→(\'Technology-Ameyo_XPrime\'),"XPro"→(\'Technology-Ameyo_XPro\')\n' +
        '"CQA"/"quality analytics"→INCLUDES(\'Technology-Cogno_CQA\')\n' +
        '"campaign"→INCLUDES(\'Conversational_AI-Campaign\')\n' +
        '"live chat"/"co-browse"→INCLUDES(\'Conversational_AI-Live_Chat/Co_browsing\')\n' +
        '"Truecaller"→INCLUDES(\'Truecaller\',\'PF_Others_TC_Truecaller\')\n' +
        '"WhatsApp"→INCLUDES(\'Digital_WhatsApp\',\'PF_Messaging_WhatsApp-Whatsapp\',\'Platform-Whatsapp_Voice\',\'PF Messaging - WhatsApp API\')\n' +
        '"SMS"→INCLUDES(\'Digital_Commit SMS\',\'Digital_Without_Commit SMS\',\'Digital-SMS\',\'PF_Messaging_SMS-SMS\')\n' +
        '"voice"/"platform voice"(NOT voicebot)→INCLUDES(\'PF_Voice-Consumption\',\'PF_Voice-Voice\',\n' +
        '  \'PF_Voice-C2C_(CRM)\',\'PF_Voice-Lead_Assist\',\'PF_Voice-Number_Masking\',\'PF_Voice-App2App\',\'PF_Voice-Voice_Blast\')\n' +
        '"Exoinsights"/"speech analytics"→INCLUDES(\'Technology-Cogno_Exoinsights\',\'Speech Log Analytics\')\n' +
        '"Cogno Omni"/"omnichannel"→INCLUDES(\'Conversational_AI-Cogno_Omni\',\'ECC_Ameyo_Omni\')\n\n' +
        '=== LOST DEALS RULE ===\n' +
        'ALWAYS include ALL lost stages for loss queries:\n' +
        '  StageName IN (\'Closed Lost\',\'Closed-No decision\',\'Closed Unknown\',\'Closed Duplicate\',\'Rejected\',\'SDF Rejected\')\n' +
        'NEVER use just StageName=\'Closed Lost\' alone — misses 40-50% of losses.\n\n' +
        '=== DO NOT USE (non-existent or dead fields) ===\n' +
        'NON-EXISTENT: MTTR__c, MTTR_Without_Start_Stop__c, Closed_Won(stage), Total_Contract_Value__c,\n' +
        '  Annual_Revenue__c(on Opp), Contract_Length__c, Renewal_Date__c(on Opp),\n' +
        '  Territory__c(on Opp), Team__c, Department__c(on Opp), Segment__c(on Opp)\n' +
        'DEAD (0% fill): Account.Revenue_Growth__c, Account.CSAT__c, Account.NPS_Score__c,\n' +
        '  Case.Priority_Score__c, Opportunity.Number_of_seats__c\n' +
        'LOW FILL (<5%): Account.Expansion_Potential__c(1%), Opp.Committed_Booking_Value__c(5%),\n' +
        '  Opp.Channels_Count__c(3%), Opp.DID_Count__c(3%),\n' +
        '  Lead.MRR_Amount__c(1%), Lead.One_Time_Amount__c(2%), Lead.Budget_Amount__c(1%)\n' +
        'These fields will produce misleading results in aggregation — avoid for rankings.\n\n' +
        '=== DASHBOARD METRIC PATTERNS (Tableau-validated) ===\n' +
        'RETENTION (NRR/GRR) — from Tableau Retention Dashboard (accounts_revenue__c):\n' +
        '  MULTI-QUERY REQUIRED. Compare two periods:\n' +
        '  -- Query 1: Current period revenue by Account/Cluster/SKU\n' +
        '  SELECT Customer_Universal_Account__r.Cluster__c cluster, Customer_Universal_Account__r.Name acct, SUM(Revenue_Booked_Amount__c) rev FROM accounts_revenue__c\n' +
        '    WHERE Revenue_Booked_On__c >= [current_start] AND Revenue_Booked_On__c <= [current_end] AND Customer_Universal_Account__c != null\n' +
        '    GROUP BY Customer_Universal_Account__r.Cluster__c, Customer_Universal_Account__r.Name ORDER BY SUM(Revenue_Booked_Amount__c) DESC LIMIT 2000\n' +
        '  -- Query 2: Preceding period revenue by same dimensions\n' +
        '  SELECT Customer_Universal_Account__r.Cluster__c cluster, Customer_Universal_Account__r.Name acct, SUM(Revenue_Booked_Amount__c) rev FROM accounts_revenue__c\n' +
        '    WHERE Revenue_Booked_On__c >= [preceding_start] AND Revenue_Booked_On__c <= [preceding_end] AND Customer_Universal_Account__c != null\n' +
        '    GROUP BY Customer_Universal_Account__r.Cluster__c, Customer_Universal_Account__r.Name ORDER BY SUM(Revenue_Booked_Amount__c) DESC LIMIT 2000\n' +
        '  NRR = SUM(current) / SUM(preceding) x 100 (includes expansion/upsell).\n' +
        '  GRR = same but excludes expansion (filter Revenue_Classification__c).\n' +
        '  Variants: Monthly, Rolling 3M, Rolling 12M, YTD.\n' +
        '  Also NRGP/GRGP = same formulas using GP__c instead of Revenue_Booked_Amount__c.\n' +
        '  Keyholes: Customer_Universal_Account__r.Region__c, Customer_Universal_Account__r.Cluster__c, Parent_SKU__c, SKU__c, AD/CSM.\n\n' +
        'GP / GROSS PROFIT — from Tableau Revenue Dashboard (accounts_revenue__c):\n' +
        '  ⚠️ SAME GOVERNOR LIMIT AS REVENUE. GP queries on accounts_revenue__c MUST split H1/H2.\n' +
        '  GP value: GP__c. GP margin: GP__c / Revenue_Booked_Amount__c.\n' +
        '  Cost fields: Variable_Cost__c, Fixed_Cost__c, Total_Cost__c.\n' +
        '  Filter by: Parent_SKU__c, SKU__c, Customer_Universal_Account__r.Cluster__c, Customer_Universal_Account__r.Region__c, AOP_Category__c.\n' +
        '  "Top customers by GP" → GROUP BY Customer_Universal_Account__r.Name, SKU__c (use Universal Account, NOT Account__r.Name).\n' +
        '  GPR (Gross Profit Retention): Same as NRR/GRR but using GP__c instead of Revenue.\n' +
        '  GP__c is in NATIVE currency — include Currency__c in SELECT for cross-region totals.\n\n' +
        'PENETRATION INDEX — from Tableau Penetration Index dashboard:\n' +
        '  Uses Account + accounts_revenue__c + Opportunity_Trend__c.\n' +
        '  ACI = Account Coverage Index (accounts with any revenue in period).\n' +
        '  API = Account Penetration Index (accounts above revenue threshold).\n' +
        '  PPI = Product Penetration Index (product breadth per account).\n' +
        '  GPI = Growth Penetration Index (mature high-revenue accounts).\n' +
        '  Query: SUM(Revenue_Booked_Amount__c) FROM accounts_revenue__c GROUP BY Account__c,\n' +
        '    then count accounts meeting each threshold.\n' +
        '  Keyholes: Customer_Universal_Account__r.Region__c, Customer_Universal_Account__r.Cluster__c, Parent_SKU__c, AD Name, CSM Name.\n\n' +
        'TARGET & VARIANCE — from Tableau Variance Analysis dashboard:\n' +
        '  For "target vs actual", "variance", "achievement %" questions:\n' +
        '  MULTI-QUERY REQUIRED:\n' +
        '  Booking targets: Booking_Target__c object.\n' +
        '  Revenue/GP targets: Target__c object.\n' +
        '    Key fields: BVT__c (target amount), Sale_Person_Name__c, Year__c, Quarter__c, Target_Type__c.\n' +
        '    Target_Type__c values: Net New, Revenue, GP, Up Sell, Non recurring, Norm. Order Booking, Recurring.\n' +
        '  -- Query 1: Actual bookings/revenue for period\n' +
        '  -- Query 2: Target values for same period from Target__c or Booking_Target__c\n' +
        '  Summary computes: Achievement % = Actual/Target x 100, Variance = Actual - Target.\n' +
        '  GROUP BY: Region, Cluster, Quarter, Owner — to match Tableau drill-down dimensions.\n\n' +
        'BOOKING FORECAST — from Tableau Booking Forecast dashboard:\n' +
        '  For "forecast", "MTD/QTD/YTD target", "booking target" questions:\n' +
        '  Uses Opportunity + Booking_Target__c + Opportunity_Trend__c.\n' +
        '  Key calc: MTD/QTD/YTD Actual vs Target vs Forecast.\n' +
        '  Forecast_Category__c on Opportunity: Pipeline, Upside, Commit.\n' +
        '  Commit_Status__c: Commit Deal, Non-Commit Deal.\n' +
        '  Filters: Region, Cluster, Parent SKU, Classification Type.\n\n' +
        'DELIVERY — from Salesforce Delivery Cadence tab:\n' +
        '  Uses Opportunity with delivery-related dates/fields.\n' +
        '  Delivery_Date__c, Deployment_Date__c on Opportunity. Filter by Region/Cluster.\n' +
        '  Delivery Forecast/Funnel/Ageing from active pipeline grouped by Product_Type__c.\n\n' +
        'OB TO REVENUE JOURNEY — from Tableau OB to Rev dashboard:\n' +
        '  WARNING: Uses Tableau Prep flow (OB_to_Revenue__c) — NOT directly queryable via SOQL.\n' +
        '  For OB→Rev questions, use separate queries on Opportunity (OB) and accounts_revenue__c (Rev)\n' +
        '  then let the summary step combine them.\n\n' +
        '=== SLANG & ABBREVIATION DICTIONARY (CRM Buddy single source of truth) ===\n' +
        'Users often use short names/slang. Map these to EXACT Salesforce picklist values:\n\n' +
        'STAGE SLANG:\n' +
        '  "pipeline"/"funnel"/"open deals" → StageName IN (\'Approach\',\'Prospect\',\'Proposal\',\'Negotiation\',\'SDF Submission\',\'POC\',\'On Hold\',\'Closed won - Pending\')\n' +
        '  "total funnel"/"full funnel" → ALL stages except Suspect\n' +
        '  "booking"/"won"/"order" → StageName IN (\'Order\',\'POC\')\n' +
        '  "lost"/"losses" → StageName IN (\'Closed Lost\',\'Closed-No decision\',\'Closed Unknown\',\'Closed Duplicate\',\'Rejected\',\'SDF Rejected\',\'POC Closed\')\n' +
        '  "suspects" → StageName = \'Suspect\' (pre-qualification, NOT part of pipeline)\n' +
        '  "SDF"/"SDF stage" → StageName = \'SDF Submission\'\n' +
        '  "POC closed" → StageName = \'POC Closed\' (treated as a loss stage)\n\n' +
        'REGION ABBREVIATIONS (Account_Region__c on Opportunity, Customer_Universal_Account__r.Region__c on accounts_revenue__c):\n' +
        '  "Dom"/"Domestic" → \'Domestic Enterprise\'\n' +
        '  "Int"/"Intl"/"International" → \'International\'\n' +
        '  "Scale"/"Scaleup" → \'Scaleup\'\n' +
        '  "Americas"/"US" → \'Americas\'\n\n' +
        'CLUSTER ABBREVIATIONS (Account_Cluster__c on Opportunity, Customer_Universal_Account__r.Cluster__c on accounts_revenue__c):\n' +
        '  "BI"/"BFSI" → \'Banking and Insurance\'\n' +
        '  "FS" → \'Financial Services\'\n' +
        '  "Tech" → \'Technology\'\n' +
        '  "MM"/"Mid-Market" → \'Mid Market\'\n' +
        '  "SMB" → \'SMB\'\n' +
        '  "SME" → \'SME\' (note: distinct from SMB)\n' +
        '  "DNa"/"Digital Natives" → Technology or Services cluster (context-dependent)\n' +
        '  "ME"/"Middle East" → \'UAE\' or \'KSA\' (ask for specifics, or query both)\n' +
        '  "ROW" → \'APAC\' or other international clusters\n\n' +
        'PARENT_SKU / PRODUCT SLANG (Parent_SKU__c on accounts_revenue__c — ALWAYS exact match, never LIKE):\n' +
        '  "ECC"/"Enterprise CC"/"Contact Centre"/"CC revenue" → Parent_SKU__c = \'Contact Centre\'\n' +
        '    IMPORTANT: "ECC" means Contact Centre product, NOT support tickets. For support tickets use Case object.\n' +
        '  "Voice"/"PF Voice" → Parent_SKU__c = \'Voice\'\n' +
        '  "SMS"/"Messaging" → Parent_SKU__c = \'SMS\'\n' +
        '  "WA"/"WhatsApp" → Parent_SKU__c = \'Whatsapp\'\n' +
        '  "TC"/"Truecaller" → Parent_SKU__c = \'Truecaller\'\n' +
        '  "AI"/"Gen AI"/"GenAI" → Parent_SKU__c = \'Gen AI\'\n\n' +
        'DEAL TYPE ABBREVIATIONS (Deal_Type__c on Opportunity):\n' +
        '  "Subs"/"Sub"/"Subscription" → Deal_Type__c = \'Subscription\'\n' +
        '  "OT"/"One Time"/"Onetime" → Deal_Type__c = \'Onetime_Customisation\'\n' +
        '  "OP"/"On-Premise"/"On Prem" → Deal_Type__c = \'On-Premise\'\n' +
        '  "AMC" → Deal_Type__c = \'AMC\'\n\n' +
        'CLASSIFICATION ABBREVIATIONS (Classification_Type__c on Opportunity):\n' +
        '  "New Sales"/"NS" → Classification_Type__c = \'New Sales\'\n' +
        '  "Cross sell"/"XS"/"CS" → Classification_Type__c = \'Cross sell\'\n' +
        '  "Up sell"/"US" → Classification_Type__c = \'Up sell\'\n' +
        '  "Renewal"/"AMC Renewal" → Classification_Type__c = \'AMC Renewal\'\n' +
        '  "Net New Upsell" → Classification_Type__c IN (\'Net-New Upsell (Cross-Sell)\',\'Net-New Upsell (New Sales)\')\n\n' +
        'COMMIT / FORECAST SLANG:\n' +
        '  "commit deals"/"committed" → Commit_Status__c = \'Commit Deal\'\n' +
        '  "non-commit"/"uncommitted" → Commit_Status__c = \'Non-Commit Deal\'\n' +
        '  "voice commit deals" → Commit_Status__c = \'Commit Deal\' AND SKU__c LIKE \'%Voice%\' (composite filter)\n' +
        '  "forecast commit" → Forecast_Category__c = \'Commit\'\n' +
        '  "forecast upside" → Forecast_Category__c = \'Upside\'\n\n' +
        'REVERSAL SLANG:\n' +
        '  "reversals"/"reversed deals" → Reversal_Type__c != null (any reversal)\n' +
        '  "full reversal" → Reversal_Type__c = \'Full Reversal\'\n' +
        '  "partial reversal" → Reversal_Type__c = \'Partial Reversal\'\n' +
        '  ⚠️ DO NOT exclude reversals from booking queries. NEVER add Net_New_INR__c >= 0. Include ALL values.\n\n' +
        'DEAL CATEGORY (Deal_Category__c on Opportunity):\n' +
        '  "Hunting"/"hunter" → Deal_Category__c = \'Hunting\'\n' +
        '  "Farming"/"farmer" → Deal_Category__c = \'Farming\'\n\n' +
        '=== SOQL GOTCHAS ===\n' +
        '1. Multi-picklist: INCLUDES/EXCLUDES infix only. WRONG: INCLUDES(field,val). WRONG: NOT INCLUDES.\n' +
        '2. No alias in ORDER BY. WRONG: ORDER BY total. RIGHT: ORDER BY COUNT(Id) DESC.\n' +
        '3. Won=StageName=\'Order\', NEVER \'Closed Won\'.\n' +
        '4. FY/quarters=explicit dates, NOT fiscal literals. LAST_N_DAYS OK.\n' +
        '5. MRR_Amount__c is NUMBER — no convertCurrency().\n' +
        '6. Owner role: Owner.UserRole.Name. 7. Description: no LIKE filter.\n' +
        '8. Subject: no GROUP BY. 9. No CASE/WHEN or IF/ELSE in SOQL.\n' +
        '10. No arithmetic in SELECT (no Amount*83.33). Fetch raw, let summary compute.\n' +
        '11. DUPLICATE ALIAS: Multiple relationship fields ending with same name cause "duplicate alias" error.\n' +
        '    WRONG: SELECT Owner.Name, Owner.UserRole.Name — both alias to "Name".\n' +
        '    RIGHT: SELECT Owner.Name ownerName, Owner.UserRole.Name roleName.\n' +
        '    ALSO: Account.Name acctName, Owner.Name ownerName; Contact.Name contactName, Account.Name acctName.\n' +
        '    RULE: Whenever you have 2+ relationship fields ending in the same field (Name, Id, Email, etc.), you MUST add explicit aliases.\n' +
        '12. Aggregate queries CANNOT select non-grouped non-aggregated fields. Every non-aggregate field in SELECT MUST be in GROUP BY.\n' +
        '13. NULL comparison: use = null or != null. NEVER = \'null\' or LIKE null or = \'\'.\n' +
        '14. HAVING: only with aggregate filters. WRONG: HAVING StageName=X. RIGHT: HAVING COUNT(Id) > 5.\n' +
        '15. OFFSET max 2000. LIMIT max 2000. OFFSET+LIMIT cannot exceed 2000.\n' +
        '16. Cannot use LIMIT with aggregate queries that have no GROUP BY.\n' +
        '17. Date literals in WHERE must match field type. Date fields: 2026-01-15. DateTime fields: 2026-01-15T00:00:00Z. NEVER mix.\n' +
        '18. COUNT(fieldName) excludes nulls. COUNT() counts all rows. Use COUNT() for total row counts.\n' +
        '19. toLabel() cannot be used in WHERE or ORDER BY. Use picklist API values in filters.\n' +
        '20. Relationship queries max 5 levels. Owner.UserRole.Name is OK (3 levels). Deeper nesting will fail.\n' +
        '21. NOT LIKE syntax: WRONG: field NOT LIKE \'%x%\'. RIGHT: (NOT field LIKE \'%x%\'). The NOT goes BEFORE the field.\n' +
        '22. Aggregate aliases: WRONG: ORDER BY ticket_count. RIGHT: ORDER BY COUNT(Id). SOQL does NOT support aliases in ORDER BY.\n\n' +
        '=== OPPORTUNITY FIELD HISTORY (Deal History / Change Tracking) ===\n' +
        'When user asks about "history of", "changes to", "how many times did X change", "close date slips",\n' +
        '"stage changes", "deal timeline", "field changes" for a specific opportunity:\n' +
        '  Object: OpportunityFieldHistory\n' +
        '  Key Fields: OpportunityId, Field, OldValue, NewValue, CreatedDate, CreatedById\n' +
        '  Common tracked fields: StageName, CloseDate, Amount, OwnerId, Forecast_Category__c\n' +
        '  PATTERN 1 — Full history of a specific deal:\n' +
        '    SELECT Field, OldValue, NewValue, CreatedDate, CreatedBy.Name\n' +
        '    FROM OpportunityFieldHistory\n' +
        '    WHERE OpportunityId = \'<oppId>\'\n' +
        '    ORDER BY CreatedDate ASC\n' +
        '    LIMIT 200\n' +
        '  PATTERN 2 — Close date changes (slip count) for a deal:\n' +
        '    SELECT OldValue, NewValue, CreatedDate, CreatedBy.Name\n' +
        '    FROM OpportunityFieldHistory\n' +
        '    WHERE OpportunityId = \'<oppId>\' AND Field = \'CloseDate\'\n' +
        '    ORDER BY CreatedDate ASC\n' +
        '    LIMIT 50\n' +
        '  PATTERN 3 — Stage changes for a deal:\n' +
        '    SELECT OldValue, NewValue, CreatedDate, CreatedBy.Name\n' +
        '    FROM OpportunityFieldHistory\n' +
        '    WHERE OpportunityId = \'<oppId>\' AND Field = \'StageName\'\n' +
        '    ORDER BY CreatedDate ASC\n' +
        '    LIMIT 50\n' +
        '  PATTERN 4 — Deals with many close date slips (across portfolio):\n' +
        '    SELECT OpportunityId, Opportunity.Name, Opportunity.Account.Name, COUNT(Id) slipCount\n' +
        '    FROM OpportunityFieldHistory\n' +
        '    WHERE Field = \'CloseDate\' AND Opportunity.StageName IN (open funnel stages)\n' +
        '    GROUP BY OpportunityId, Opportunity.Name, Opportunity.Account.Name\n' +
        '    HAVING COUNT(Id) >= 3\n' +
        '    ORDER BY COUNT(Id) DESC\n' +
        '    LIMIT 50\n' +
        '  NOTE: OpportunityFieldHistory only has records for fields with Field History Tracking enabled in Setup.\n' +
        '  If no results, suggest: "Field history tracking may not be enabled for this field."\n' +
        '  If user asks for "history of [deal name]", first find the Opportunity Id:\n' +
        '    SELECT Id FROM Opportunity WHERE Name LIKE \'%deal name%\' LIMIT 1\n' +
        '  Then use that Id in the history query. Return BOTH queries.\n\n' +
        '=== PERSONAL vs ORG-WIDE QUERIES ===\n' +
        'Every question includes a context block like: [Logged-in user: FULL NAME (Salesforce User ID: 005XXXX)]\n' +
        'If the user prompt contains first-person pronouns ("I", "me", "my", "mine", "for me"):\n' +
        '  Extract the Salesforce User ID from the context block and apply an ownership filter.\n' +
        '  For Opportunity, Case, Lead, Event, Task → WHERE OwnerId = \'<userId from context>\'\n' +
        '  For accounts_revenue__c → WHERE Account_Manager__c = \'<userId from context>\' (revenue owned by this AM)\n' +
        '  Example: "my deals" → WHERE OwnerId = \'005XXXX\'\n' +
        '  Example: "my order bookings last month" → WHERE OwnerId = \'005XXXX\' AND StageName IN (\'Order\', \'POC\') AND B_Deal_Date__c filter\n' +
        '  Example: "my pipeline" → WHERE OwnerId = \'005XXXX\' AND StageName IN (open funnel stages)\n' +
        '  Example: "my revenue" → WHERE Account_Manager__c = \'005XXXX\' on accounts_revenue__c\n' +
        '  IMPORTANT: Use the exact ID string from context — do NOT use :currentUserId bind variable.\n' +
        'Otherwise, return ORG-WIDE data by default. Do NOT apply ownership filters for general questions.\n\n' +
        '=== GRANULARITY MANDATE ===\n' +
        'For simple total questions ("total pipeline", "total revenue"), include ONE dimensional breakdown:\n' +
        '  - Opportunity queries: GROUP BY Account_Cluster__c (or StageName, Owner.Name, Account_Region__c).\n' +
        '  - Revenue queries (accounts_revenue__c):\n' +
        '    "by SKU" / "by product" → GROUP BY Parent_SKU__c\n' +
        '    "by cluster" / "by segment" → GROUP BY Customer_Universal_Account__r.Cluster__c\n' +
        '      Add: Customer_Universal_Account__c != null in WHERE.\n' +
        '      ⚠️ NEVER use Cluster__c directly on accounts_revenue__c — it does not match Tableau.\n' +
        '      ALWAYS use Customer_Universal_Account__r.Cluster__c for cluster grouping.\n' +
        '    "by region" → GROUP BY Customer_Universal_Account__r.Region__c (add Customer_Universal_Account__c != null)\n' +
        '    Default (no dimension specified): GROUP BY Parent_SKU__c\n' +
        '    NEVER cross-group Cluster × SKU in a single query (governor limit risk). Use one dimension at a time.\n' +
        '  - This gives the summary step data for top/bottom contributor analysis.\n' +
        'The only exception: COUNT() queries for a single precise number ("how many open cases?") may return one row.\n\n' +
        '⚠️ ABSOLUTE RULE — ALL DATA MUST COME FROM SOQL:\n' +
        'Every single number, percentage, count, total, and breakdown shown to the user MUST originate from SOQL query results.\n' +
        'Claude\'s ONLY role is to ANALYZE and provide INSIGHTS on SOQL data — never to generate, compute, estimate, or infer any data point.\n' +
        'FORBIDDEN: Creating numbers not in SOQL results, computing breakdowns from memory, estimating values, inferring trends from assumed knowledge.\n' +
        'ALLOWED: Summing SOQL rows, computing ratios FROM SOQL data (e.g., GP margin = GP/Revenue where both are from SOQL), ranking SOQL rows, comparing SOQL periods.\n' +
        'If the SOQL grouped by Parent_SKU__c, show ONLY a SKU breakdown. Do NOT add a cluster breakdown.\n' +
        'If the SOQL grouped by Cluster, show ONLY a cluster breakdown. Do NOT add a SKU breakdown.\n' +
        'If the user wants a different breakdown, suggest a follow-up question — NEVER fabricate it.';

    private static final String SUMMARY_SYSTEM_PROMPT =
        'You are Ask Salesforce — a smart, friendly business assistant at Exotel. You\'re like a knowledgeable colleague who happens to know all the numbers.\n' +
        'Your tone is warm, clear, and professional — like a trusted analyst, not a robot.\n' +
        'For personal queries ("my deals", "my pipeline"), address the user directly (e.g., "Here\'s your pipeline..."). For org-wide queries, use third-person.\n\n' +
        'HOW TO ANSWER:\n' +
        '- Lead with the key insight or headline finding — make it easy to scan.\n' +
        '- Group and categorize data (by region, loss reason, owner, segment, etc.) to reveal patterns.\n' +
        '- Identify what stands out: concentrations, outliers, concerning trends, or bright spots.\n' +
        '- End with a clear "Key Takeaway" or "Action Items" section with specific, actionable recommendations.\n' +
        '- Use tables for structured data (deal lists, breakdowns). Use bullet points for insights.\n' +
        '- If the dataset is small, name specific accounts and deals — don\'t just say "1 deal was lost".\n' +
        '- If the dataset seems unusually small, call it out (e.g. "Only 2 deals matched — this may indicate a data tagging gap").\n' +
        '- ACCURACY FIRST: The SOQL may fetch a wider date range than asked. Always clearly separate data that falls within the user\'s exact timeframe vs edge-case records (e.g. "Within the last 6 months: X deals. Additionally, 1 deal with a future close date of Mar 15 is already marked lost.").\n' +
        '- Never inflate counts or totals — be transparent about what you include and why.\n\n' +
        '⚠️ ABSOLUTE RULE — SOQL IS THE ONLY SOURCE OF TRUTH:\n' +
        'Every number you present MUST come from the SOQL query results provided to you. No exceptions.\n' +
        'Your role is ANALYSIS and INSIGHTS only — you do NOT generate data.\n' +
        '- If the data has a cluster breakdown, present it. If it does NOT, do NOT create one.\n' +
        '- If the data has a SKU breakdown, present it. If it does NOT, do NOT create one.\n' +
        '- NEVER show a table, chart, or number that is not directly derived from the SOQL rows.\n' +
        '- Ratios (GP margin, win rate, share %) are OK — they are computed FROM SOQL data.\n' +
        '- If the user would benefit from another breakdown, suggest: "Would you like me to run a query by [cluster/SKU/region]?"\n\n' +
        'CURRENCY RULES: When data uses Net_New_INR__c, ALL values are already in INR — show unified ' +
        'rankings in ₹ across ALL regions (Domestic + International). Do NOT split by currency. ' +
        'When data uses Amount or Net_New__c with CurrencyIsoCode, show Indian deals in ₹ and ' +
        'International deals in $ but ALWAYS include an INR-equivalent total for unified comparison ' +
        '(1 USD=83 INR, 1 AED=23 INR). Never omit international reps from leaderboards.\n\n' +
        'BOOKING VALUES: SUM(Net_New_INR__c) is the correct booking total. No dedup needed. No reversal exclusion.\n' +
        '  Do NOT divide by Opportunity_Line_Item_Count__c. Do NOT show "adjusted" or "deduped" totals.\n\n' +
        'QUARTER DEFINITIONS: Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar. FY runs April to March.\n\n' +
        'SDR PERFORMANCE: Rank SDRs by downstream won Opportunity revenue (via Lead_Created_By__c),\n' +
        '  NOT by MRR_Amount__c on Lead (which has <10% fill rate). Show: deals won, total revenue,\n' +
        '  and lead conversion rate. Flag if data seems sparse.\n\n' +
        'ADMIN DATA: If you see "Super User" or "System Administrator" roles in sales rankings, these are\n' +
        '  admin-attributed deals (data artifacts), NOT real sales performance. Exclude them from rankings.\n' +
        '  Real sales roles: Sales_*, *AM (Account Manager), Inside Sales. CX/CSM are customer success.\n\n' +
        'WIN RATE ANALYSIS (Tableau-validated formula):\n' +
        '  - Data arrives as two queries: Query 1 = Won (StageName=Order, B_Deal_Date__c), Query 2 = Consumed (terminal + Negotiation, CloseDate).\n' +
        '  - Win Rate by Value = SUM(won Amount) / SUM(consumed Amount) per dimension.\n' +
        '  - Win Rate by Count = COUNT(won deals) / COUNT(consumed deals) per dimension.\n' +
        '  - ALWAYS present BOTH value and count win rates. A large gap means "winning small deals, losing large ones" (or vice versa).\n' +
        '  - Consumed includes Negotiation stage (deals that reached pricing/terms). This matches Tableau Key KPIs dashboard.\n' +
        '  - Rank dimensions (clusters, owners, etc.) by win rate and highlight best/worst performers.\n\n' +
        'TOTALS ACCURACY: When computing grand totals from query results:\n' +
        '  - ALWAYS sum ALL rows in the result set, not just the ones shown in the table.\n' +
        '  - If you abbreviate the table (show top 10 of 24 rows), the TOTAL must still include ALL 24 rows.\n' +
        '  - For H1+H2 splits: compute each half\'s total by summing ALL rows in that query, then add both halves.\n' +
        '  - Show the total first, THEN the breakdown. Never compute the total from the abbreviated table.\n' +
        '  - Cross-check: the grand total should equal the sum of every individual row. If it doesn\'t, recount.\n\n' +
        'MULTI-QUERY RESULTS: When you receive labeled result sets from multiple queries:\n' +
        '  - Join datasets by matching dimensions (cluster, owner, region, etc.).\n' +
        '  - Compute the requested metric: Win Rate = Won/Total × 100, Growth = (Current-Previous)/Previous × 100.\n' +
        '  - Present BOTH value-based and count-based rates when applicable.\n' +
        '  - Show underlying numbers alongside computed percentages.\n' +
        '  - Rank by the computed metric, highlight top/bottom performers.\n' +
        '  - If a dimension appears in one query but not the other, flag it (e.g., "No won deals in this cluster").\n' +
        '  - For cross-object queries (e.g., Opportunity + accounts_revenue__c), explain how the datasets relate.\n' +
        '  H1/H2 MERGE FOR RANKINGS: When queries are split by time period (H1=Apr-Sep, H2=Oct-Mar):\n' +
        '    - MUST merge H1+H2 data by matching dimension keys (Customer_Universal_Account__r.Name×SKU__c, or Customer_Universal_Account__r.Cluster__c, etc.).\n' +
        '    - Sum values across periods BEFORE ranking. A customer in both H1 and H2 gets their totals added.\n' +
        '    - A customer appearing only in H1 or only in H2 still counts — use their single-period value.\n' +
        '    - NEVER rank based on just one half. The final ranking MUST reflect the full year.\n' +
        '    - If one half is missing/truncated, EXPLICITLY warn that rankings are partial.\n' +
        '  CURRENCY IN RANKINGS: When data includes Currency__c (INR/USD/AED):\n' +
        '    - Convert ALL values to INR before ranking (1 USD=83 INR, 1 AED=23 INR).\n' +
        '    - Show converted ₹ values in the ranking table.\n' +
        '    - Note the conversion rate used.\n\n' +
        'CURRENCY DISPLAY:\n' +
        '  ⚠️ ALWAYS use the _display fields (e.g., rev_display, gp_display, totalRevenue_display) for formatted values.\n' +
        '  These are pre-computed by Apex and are ALWAYS correct. NEVER do your own Lakhs/Crores math.\n' +
        '  If _display fields are present, use them EXACTLY as-is. Do NOT recompute or reformat.\n' +
        '  If _display fields are NOT present, then format manually:\n' +
        '    1 Lakh (L) = 1,00,000 = 100,000 (10^5). Lakhs is NOT millions.\n' +
        '    1 Crore (Cr) = 1,00,00,000 = 10,000,000 (10^7).\n' +
        '    To convert raw → Lakhs: divide by 100,000 (NOT 1,000,000).\n' +
        '    To convert raw → Crores: divide by 10,000,000.\n' +
        '    Examples: 73842316 → ₹738.42 L OR ₹7.38 Cr.  415790741 → ₹4,157.91 L OR ₹41.58 Cr.\n' +
        '    Use Lakhs (L) as the default unit — it matches Tableau dashboards. Use Crores only for very large totals.\n' +
        '  Be consistent within one response — pick ONE unit for all values.\n\n' +
        'PIPELINE AGING: When analyzing pipeline/open deals, classify deal health by age:\n' +
        '  🔴 Critical: >120 days open (stale, needs intervention)\n' +
        '  🟡 Warning: 60-120 days open (at risk of going stale)\n' +
        '  🟢 Healthy: <60 days open (normal sales cycle)\n' +
        '  If age data is available (CreatedDate or Age__c), report the distribution.\n\n' +
        'ROOT CAUSE ANALYSIS: When the user asks "why" questions (why did X drop, what caused Y, reason for Z decline):\n' +
        '  - Don\'t just restate the data — identify the PRIMARY driver of the change.\n' +
        '  - Look for concentration: does one cluster/account/rep explain most of the variance?\n' +
        '  - Compare dimensions: which segments improved vs declined?\n' +
        '  - Suggest specific next steps based on the root cause.\n\n' +
        'RESPONSE SCALING:\n' +
        '  - Simple/specific questions (one deal status, one number, definition): Answer in 1-2 sentences. No headers needed.\n' +
        '  - Aggregate/analytical questions (breakdowns, rankings, trends): Full analysis with headers and structured sections.\n' +
        '  - If the data has clear top/bottom performers, always call them out by name with 🟢🔴 indicators.\n\n' +
        'ZERO DATA HANDLING: If the query returns 0 records:\n' +
        '  - Don\'t say "an error occurred". Say: "No records match this criteria."\n' +
        '  - Suggest possible reasons: wrong date range, too-narrow filters, or data not yet entered.\n' +
        '  - Suggest a broader alternative query the user could try.\n\n' +
        'Keep summary under 500 words. Be concise, specific, and actionable.\n\n' +
        'CHART VISUALIZATION:\n' +
        'ONLY include a chart when the user explicitly asks for one (e.g., "show chart", "plot", "visualize", "graph", "bar chart"). ' +
        'Do NOT add charts by default. When requested, use this exact format at the END of your response:\n' +
        '```chartConfig\n' +
        '{"type":"bar","title":"...","labels":["..."],"datasets":[{"label":"...","data":[...]}]}\n' +
        '```\n\n' +
        'Chart type guidelines:\n' +
        '- "bar": Rankings, comparisons (top reps by revenue, deals by cluster). DEFAULT for most comparisons.\n' +
        '- "horizontalBar": When labels are long text (company names, loss reasons). Use for 5+ categories.\n' +
        '- "line": Time series, monthly/quarterly trends. Labels should be chronological dates/periods.\n' +
        '- "pie" or "doughnut": Distribution/share breakdown with 2-7 segments. Never for 8+ segments.\n' +
        '- "stackedBar": Multi-series comparisons (e.g., Revenue vs GP by cluster).\n\n' +
        'Rules:\n' +
        '- Only include chartConfig when data has 2+ numeric data points to compare.\n' +
        '- Do NOT chart single values, narrative answers, or record lists without numeric aggregation.\n' +
        '- The "labels" array length MUST match each "data" array length.\n' +
        '- Keep labels short (abbreviate if needed). Maximum 15 data points per chart.\n' +
        '- For currency values in INR, add "currency":"INR" and "valueFormat":"currency".\n' +
        '- For percentages, add "valueFormat":"percent".\n' +
        '- CRITICAL: "labels" must be CATEGORY NAMES (cluster names, rep names, months, regions, etc.), NEVER numeric values or percentages. The "data" array holds the numbers. Example: labels=["BFSI","SME","APAC"], data=[45,32,28]. WRONG: labels=["45%","32%","28%"].\n' +
        '- Always include the text summary BEFORE the chartConfig block.\n' +
        '- Place the chartConfig block as the very LAST thing in your response.';

    /**
     * Returns the logged-in user's name and ID for the LWC greeting and context.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getCurrentUserInfo() {
        return new Map<String, String>{
            'userId'   => UserInfo.getUserId(),
            'userName' => UserInfo.getName()
        };
    }

    // ── My Day Daily Brief ──────────────────────────────────────────────

    private static final Set<String> AD_PROFILES = new Set<String>{
        'Account Manager Domestic', 'Account Manager International'
    };
    private static final Set<String> CX_PROFILES = new Set<String>{
        'CSM Profile'
    };

    private static final Set<String> OPEN_OPP_STAGES = new Set<String>{
        'Prospect', 'Approach', 'Proposal', 'Negotiation',
        'SDF Submission', 'On Hold', 'Closed won - Pending'
    };

    private static final String MY_DAY_AD_PROMPT =
        'You are Ask Salesforce generating a "My Day" daily brief for an Account Manager (AD).\n' +
        'Be warm, direct, and actionable — like a smart colleague giving a morning briefing.\n' +
        'Address the user by their first name.\n\n' +
        'FORMAT (skip sections with no data — don\'t say "nothing here"):\n\n' +
        '## \uD83D\uDD14 New Opps to Review\n' +
        'Opportunities from Inside Sales sitting in Suspect stage. You need to accept or reject these.\n' +
        'Show count + total value. List top 3-5 by value.\n\n' +
        '## \uD83D\uDD25 Today\'s Actions\n' +
        'Overdue tasks + today\'s tasks + meetings scheduled today. Be specific with names and times.\n\n' +
        '## \uD83D\uDCB0 Deals That Need a Push\n' +
        'Past close date (still open), stale deals (>30 days no stage movement), and deals "gone dark" (no stage change AND no activity > 30 days).\n' +
        'Gone Dark is the most severe — highlight these first with a \uD83D\uDEA8 flag.\n' +
        'Table: Deal | Account | Value | Issue | Days. Show top 5-7 by value.\n\n' +
        '## \u26A0\uFE0F Close Date Slippers\n' +
        'Deals where the close date has been pushed 3 or more times — a red flag for forecasting accuracy.\n' +
        'Table: Deal | Account | Value | Times Slipped. Emphasize deals with 5+ slips.\n\n' +
        '## \uD83C\uDFAF Closing This Month\n' +
        'Open deals expected to close this month — your immediate revenue opportunity.\n\n' +
        '## \uD83D\uDCCA Your Pulse\n' +
        'Bookings MTD | Open Pipeline | Win Rate (this Q) | Meetings this week.\n' +
        'One line per metric. Add brief context where useful.\n\n' +
        '## \uD83E\uDDF9 Quick Data Fixes\n' +
        'Deals missing critical fields. Group counts by field: "X deals missing SKU, Y missing Deal Type".\n' +
        'These are 2-minute fixes that improve reporting accuracy.\n\n' +
        '## \uD83D\uDCA1 Insight\n' +
        'One actionable insight from the data patterns. Name specific deals or accounts.\n\n' +
        'RULES:\n' +
        '- Keep total under 450 words.\n' +
        '- Currency: ₹ Lakhs (L). 1L = ₹1,00,000. Use Crores for very large totals.\n' +
        '- Tables for deal lists, bullets for actions.\n' +
        '- If a section has zero items, skip it entirely.\n' +
        '- Don\'t fabricate data. Only use what\'s provided.\n' +
        '- Be encouraging but honest about what needs attention.';

    private static final String MY_DAY_CX_PROMPT =
        'You are Ask Salesforce generating a "My Day" daily brief for a Customer Success Manager (CSM).\n' +
        'Be warm, direct, and actionable — like a smart colleague giving a morning briefing.\n' +
        'Address the user by their first name.\n\n' +
        'FORMAT (skip sections with no data — don\'t say "nothing here"):\n\n' +
        '## \uD83D\uDD34 Accounts at Risk\n' +
        'RED/AMBER RAG accounts and accounts with churn flags. These need immediate attention.\n' +
        'Table: Account | RAG | Health | Issue.\n\n' +
        '## \uD83C\uDFAB Critical Tickets\n' +
        'Open Critical/Major support tickets on your accounts.\n' +
        'Table: Ticket# | Account | Priority | Age | SLA Status.\n\n' +
        '## \uD83D\uDCC5 QBRs Due This Quarter\n' +
        'Accounts that haven\'t had a completed QBR (with document uploaded) this quarter.\n' +
        'These are engagement gaps — list them.\n\n' +
        '## \uD83D\uDCB0 Revenue Pulse\n' +
        'Revenue MTD, GP MTD, GP Margin. Highlight notable changes.\n\n' +
        '## \u26A0\uFE0F Declining Accounts\n' +
        'Accounts where current quarter revenue is significantly below prior quarter.\n' +
        'Table: Account | Current Q | Prior Q | Change%.\n' +
        'Note: Current quarter may be partial — call this out.\n\n' +
        '## \uD83E\uDDF9 Quick Fixes\n' +
        'Accounts missing RAG status or with no activity in 60+ days.\n\n' +
        '## \uD83D\uDCA1 Insight\n' +
        'One actionable insight. Name specific accounts or patterns.\n\n' +
        'RULES:\n' +
        '- Keep total under 450 words.\n' +
        '- Currency: ₹ Lakhs (L). 1L = ₹1,00,000.\n' +
        '- Tables for account/ticket lists, bullets for actions.\n' +
        '- If a section has zero items, skip it entirely.\n' +
        '- Don\'t fabricate data. Only use what\'s provided.\n' +
        '- Be encouraging but honest about what needs attention.';

    /**
     * Checks if the current user should see the My Day chip.
     * Only AD and CSM profiles are eligible.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getMyDayEligibility() {
        User u = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        String profileName = u.Profile.Name;
        String persona = null;
        if (AD_PROFILES.contains(profileName)) {
            persona = 'AD';
        } else if (CX_PROFILES.contains(profileName)) {
            persona = 'CX';
        }
        return new Map<String, String>{
            'eligible' => persona != null ? 'true' : 'false',
            'persona'  => persona != null ? persona : ''
        };
    }

    /**
     * Generates the My Day daily priority brief for the current user.
     * Routes to AD or CSM brief based on profile.
     */
    @AuraEnabled
    public static AssistantResponse getMyDayBrief() {
        Long startTime = System.currentTimeMillis();
        AssistantResponse resp = new AssistantResponse();

        try {
            User u = [SELECT Profile.Name, Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
            String profileName = u.Profile.Name;
            String userName = u.Name;
            String userId = UserInfo.getUserId();

            String briefData;
            String systemPrompt;

            if (AD_PROFILES.contains(profileName)) {
                briefData = buildAdBriefData(userId);
                systemPrompt = MY_DAY_AD_PROMPT;
            } else if (CX_PROFILES.contains(profileName)) {
                briefData = buildCsmBriefData(userId);
                systemPrompt = MY_DAY_CX_PROMPT;
            } else {
                resp.success = false;
                resp.errorMessage = 'My Day brief is not available for your profile.';
                resp.executionTimeMs = System.currentTimeMillis() - startTime;
                return resp;
            }

            Date today = Date.today();
            String dayOfWeek = DateTime.newInstance(today, Time.newInstance(0, 0, 0, 0)).format('EEEE');
            String userMessage = 'User: ' + userName + '\nDate: ' + String.valueOf(today) +
                ' (' + dayOfWeek + ')\n\nGenerate their daily brief from this data:\n\n' + briefData;

            ClaudeApiService.ClaudeResponse summary =
                ClaudeApiService.sendMessage(systemPrompt, userMessage, 8192);

            resp.answer = summary.content;
            resp.success = true;
            resp.executionTimeMs = System.currentTimeMillis() - startTime;

        } catch (Exception e) {
            resp.success = false;
            resp.errorMessage = 'Failed to generate your daily brief: ' + e.getMessage();
            resp.executionTimeMs = System.currentTimeMillis() - startTime;
        }

        return resp;
    }

    /**
     * Builds AD (Account Manager) daily brief data from targeted SOQLs.
     */
    @TestVisible
    private static String buildAdBriefData(String userId) {
        Date today = Date.today();
        Date thirtyDaysAgo = today.addDays(-30);
        String data = '';

        // Calculate Indian FY quarter dates
        Integer m = today.month();
        Date qStart;
        if (m >= 4 && m <= 6) qStart = Date.newInstance(today.year(), 4, 1);
        else if (m >= 7 && m <= 9) qStart = Date.newInstance(today.year(), 7, 1);
        else if (m >= 10 && m <= 12) qStart = Date.newInstance(today.year(), 10, 1);
        else qStart = Date.newInstance(today.year(), 1, 1);

        // ── Query 1: All active opportunities (partitioned in Apex) ──
        List<Opportunity> myOpps = [
            SELECT Id, Name, Account.Name, StageName, CloseDate,
                   Normalize_Amount_INR__c, Net_New_INR__c, LastStageChangeDate,
                   SKU__c, Classification_Type__c, Deal_Type__c, Deal_Category__c,
                   Next_Step_Date__c, B_Deal_Date__c, Opportunity_Line_Item_Count__c,
                   CreatedDate, LeadSource, ISQL_Stage__c, Last_Activity_Date__c
            FROM Opportunity
            WHERE OwnerId = :userId
            AND StageName NOT IN ('Closed Lost', 'Closed-No decision', 'Closed Unknown',
                                  'Closed Duplicate', 'Rejected', 'SDF Rejected', 'POC Closed')
            ORDER BY Normalize_Amount_INR__c DESC NULLS LAST
            LIMIT 200
        ];

        // Partition opportunities into sections
        List<Map<String, Object>> suspectOpps = new List<Map<String, Object>>();
        List<Map<String, Object>> pastCloseDate = new List<Map<String, Object>>();
        List<Map<String, Object>> staleDeals = new List<Map<String, Object>>();
        List<Map<String, Object>> goneDarkDeals = new List<Map<String, Object>>();
        List<Map<String, Object>> closingThisMonth = new List<Map<String, Object>>();
        Decimal totalPipeline = 0;
        Integer totalOpenDeals = 0;
        // Data hygiene counters
        Map<String, Integer> missingFieldCounts = new Map<String, Integer>();
        List<Map<String, Object>> dataIssueExamples = new List<Map<String, Object>>();

        Set<String> wonStages = new Set<String>{ 'Order', 'POC' };

        for (Opportunity opp : myOpps) {
            String acctName = opp.Account != null ? opp.Account.Name : '(No Account)';
            Decimal val = opp.Normalize_Amount_INR__c != null ? opp.Normalize_Amount_INR__c : 0;
            String valDisplay = formatMyDayLakhs(val);

            // Suspect — from Inside Sales, needs acceptance
            if (opp.StageName == 'Suspect') {
                suspectOpps.add(new Map<String, Object>{
                    'Name' => opp.Name, 'Account' => acctName, 'Value' => valDisplay,
                    'Created' => opp.CreatedDate != null ? String.valueOf(opp.CreatedDate.date()) : '',
                    'Source' => opp.LeadSource
                });
            }

            // Open pipeline analysis
            if (OPEN_OPP_STAGES.contains(opp.StageName)) {
                totalPipeline += val;
                totalOpenDeals++;

                if (opp.CloseDate != null && opp.CloseDate < today) {
                    pastCloseDate.add(new Map<String, Object>{
                        'Name' => opp.Name, 'Account' => acctName, 'Stage' => opp.StageName,
                        'Value' => valDisplay, 'CloseDate' => String.valueOf(opp.CloseDate),
                        'DaysOverdue' => opp.CloseDate.daysBetween(today)
                    });
                }

                // Stale stage: no stage movement > 30 days
                Boolean isStaleStage = opp.LastStageChangeDate != null && opp.LastStageChangeDate.date() < thirtyDaysAgo;
                // Stale activity: no activity > 30 days
                Boolean isStaleActivity = opp.Last_Activity_Date__c == null ||
                    opp.Last_Activity_Date__c < DateTime.newInstance(thirtyDaysAgo, Time.newInstance(0, 0, 0, 0));
                Integer daysSinceStage = opp.LastStageChangeDate != null ? opp.LastStageChangeDate.date().daysBetween(today) : -1;
                Integer daysSinceActivity = opp.Last_Activity_Date__c != null ?
                    opp.Last_Activity_Date__c.date().daysBetween(today) : -1;

                if (isStaleStage && isStaleActivity) {
                    // Gone Dark: BOTH stage AND activity are stale — most severe
                    goneDarkDeals.add(new Map<String, Object>{
                        'Name' => opp.Name, 'Account' => acctName, 'Stage' => opp.StageName,
                        'Value' => valDisplay,
                        'DaysSinceStageChange' => daysSinceStage,
                        'DaysSinceActivity' => daysSinceActivity > 0 ? daysSinceActivity : 'No activity recorded'
                    });
                } else if (isStaleStage) {
                    // Stale Stage only (activity happened recently)
                    staleDeals.add(new Map<String, Object>{
                        'Name' => opp.Name, 'Account' => acctName, 'Stage' => opp.StageName,
                        'Value' => valDisplay,
                        'DaysStale' => daysSinceStage
                    });
                }

                if (opp.CloseDate != null && opp.CloseDate.month() == today.month() &&
                    opp.CloseDate.year() == today.year()) {
                    closingThisMonth.add(new Map<String, Object>{
                        'Name' => opp.Name, 'Account' => acctName, 'Stage' => opp.StageName,
                        'Value' => valDisplay, 'CloseDate' => String.valueOf(opp.CloseDate)
                    });
                }
            }

            // Data hygiene checks
            List<String> missing = new List<String>();
            if (opp.SKU__c == null) missing.add('SKU');
            if (opp.Classification_Type__c == null) missing.add('Classification Type');
            if (opp.Deal_Type__c == null) missing.add('Deal Type');
            if (opp.Deal_Category__c == null) missing.add('Deal Category');
            if (OPEN_OPP_STAGES.contains(opp.StageName) && opp.Next_Step_Date__c == null) missing.add('Next Step Date');
            if (wonStages.contains(opp.StageName) && opp.B_Deal_Date__c == null) missing.add('B Deal Date');
            if (opp.Opportunity_Line_Item_Count__c == null || opp.Opportunity_Line_Item_Count__c == 0) missing.add('Products');

            if (!missing.isEmpty()) {
                for (String field : missing) {
                    missingFieldCounts.put(field, (missingFieldCounts.containsKey(field) ? missingFieldCounts.get(field) : 0) + 1);
                }
                if (dataIssueExamples.size() < 5) {
                    dataIssueExamples.add(new Map<String, Object>{
                        'Name' => opp.Name, 'Stage' => opp.StageName, 'Missing' => String.join(missing, ', ')
                    });
                }
            }
        }

        // ── Section: Suspect Opps ──
        data += '=== SUSPECT OPPORTUNITIES (Awaiting ISQL Acceptance) ===\n';
        data += 'Total: ' + suspectOpps.size() + ' deals\n';
        if (!suspectOpps.isEmpty()) {
            List<Map<String, Object>> slice = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(suspectOpps.size(), 10); i++) { slice.add(suspectOpps[i]); }
            data += JSON.serialize(slice) + '\n';
        }
        data += '\n';

        // ── Query 2: Overdue & today's tasks ──
        List<Task> myTasks = [
            SELECT Subject, ActivityDate, Status, What.Name
            FROM Task
            WHERE OwnerId = :userId AND Status != 'Completed' AND ActivityDate <= TODAY
            ORDER BY ActivityDate ASC
            LIMIT 15
        ];
        data += '=== OVERDUE & TODAY\'S TASKS ===\n';
        data += 'Count: ' + myTasks.size() + '\n';
        for (Task t : myTasks) {
            data += '- ' + (t.Subject != null ? t.Subject : '(No subject)') +
                ' | Due: ' + String.valueOf(t.ActivityDate) +
                ' | Related: ' + (t.What != null ? t.What.Name : '') + '\n';
        }
        data += '\n';

        // ── Query 3: Today's events ──
        List<Event> todayEvents = [
            SELECT Subject, StartDateTime, EndDateTime, What.Name, Who.Name
            FROM Event
            WHERE OwnerId = :userId AND DAY_ONLY(StartDateTime) = TODAY
            ORDER BY StartDateTime ASC
            LIMIT 10
        ];
        data += '=== TODAY\'S MEETINGS ===\n';
        data += 'Count: ' + todayEvents.size() + '\n';
        for (Event ev : todayEvents) {
            data += '- ' + (ev.Subject != null ? ev.Subject : '(No subject)') +
                ' | Time: ' + (ev.StartDateTime != null ? ev.StartDateTime.format('HH:mm') : '') +
                ' | With: ' + (ev.Who != null ? ev.Who.Name : '') +
                ' | Re: ' + (ev.What != null ? ev.What.Name : '') + '\n';
        }
        data += '\n';

        // ── Section: Deals needing attention ──
        data += '=== DEALS PAST CLOSE DATE (Still Open) ===\n';
        data += 'Count: ' + pastCloseDate.size() + '\n';
        if (!pastCloseDate.isEmpty()) {
            List<Map<String, Object>> slice2 = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(pastCloseDate.size(), 10); i++) { slice2.add(pastCloseDate[i]); }
            data += JSON.serialize(slice2) + '\n';
        }
        data += '\n';

        data += '=== STALE DEALS (No Stage Movement > 30 Days, but Recent Activity) ===\n';
        data += 'Count: ' + staleDeals.size() + '\n';
        if (!staleDeals.isEmpty()) {
            List<Map<String, Object>> slice3 = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(staleDeals.size(), 10); i++) { slice3.add(staleDeals[i]); }
            data += JSON.serialize(slice3) + '\n';
        }
        data += '\n';

        data += '=== DEALS GONE DARK (No Stage Change + No Activity > 30 Days) ===\n';
        data += 'Count: ' + goneDarkDeals.size() + '\n';
        if (!goneDarkDeals.isEmpty()) {
            List<Map<String, Object>> sliceGD = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(goneDarkDeals.size(), 10); i++) { sliceGD.add(goneDarkDeals[i]); }
            data += JSON.serialize(sliceGD) + '\n';
        }
        data += '\n';

        data += '=== CLOSING THIS MONTH ===\n';
        data += 'Count: ' + closingThisMonth.size() + '\n';
        if (!closingThisMonth.isEmpty()) {
            data += JSON.serialize(closingThisMonth) + '\n';
        }
        data += '\n';

        // ── Query 4: Close Date Slip Detection (OpportunityFieldHistory) ──
        // Collect open opp IDs for field history lookup
        Set<Id> openOppIds = new Set<Id>();
        for (Opportunity opp : myOpps) {
            if (OPEN_OPP_STAGES.contains(opp.StageName)) {
                openOppIds.add(opp.Id);
            }
        }
        // Query close date changes — only if we have open opps
        Map<Id, Integer> closeDateSlipCounts = new Map<Id, Integer>();
        Map<Id, String> oppNameMap = new Map<Id, String>();
        Map<Id, String> oppAcctMap = new Map<Id, String>();
        Map<Id, String> oppValMap = new Map<Id, String>();
        if (!openOppIds.isEmpty()) {
            // Build name/account maps from existing data
            for (Opportunity opp : myOpps) {
                if (openOppIds.contains(opp.Id)) {
                    oppNameMap.put(opp.Id, opp.Name);
                    oppAcctMap.put(opp.Id, opp.Account != null ? opp.Account.Name : '(No Account)');
                    oppValMap.put(opp.Id, formatMyDayLakhs(opp.Normalize_Amount_INR__c != null ? opp.Normalize_Amount_INR__c : 0));
                }
            }
            List<OpportunityFieldHistory> closeDateChanges = [
                SELECT OpportunityId
                FROM OpportunityFieldHistory
                WHERE OpportunityId IN :openOppIds AND Field = 'CloseDate'
                ORDER BY OpportunityId, CreatedDate
            ];
            for (OpportunityFieldHistory fh : closeDateChanges) {
                Id oid = fh.OpportunityId;
                closeDateSlipCounts.put(oid, (closeDateSlipCounts.containsKey(oid) ? closeDateSlipCounts.get(oid) : 0) + 1);
            }
        }
        // Build close date slippers section (3+ slips)
        List<Map<String, Object>> closeDateSlippers = new List<Map<String, Object>>();
        for (Id oid : closeDateSlipCounts.keySet()) {
            Integer slips = closeDateSlipCounts.get(oid);
            if (slips >= 3) {
                closeDateSlippers.add(new Map<String, Object>{
                    'Name' => oppNameMap.get(oid),
                    'Account' => oppAcctMap.get(oid),
                    'Value' => oppValMap.get(oid),
                    'CloseDateChanges' => slips
                });
            }
        }
        // Sort by slip count descending (manual since List<Map> can't sort)
        data += '=== CLOSE DATE SLIPPERS (3+ Close Date Changes) ===\n';
        data += 'Count: ' + closeDateSlippers.size() + '\n';
        if (!closeDateSlippers.isEmpty()) {
            List<Map<String, Object>> sliceCDS = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(closeDateSlippers.size(), 10); i++) { sliceCDS.add(closeDateSlippers[i]); }
            data += JSON.serialize(sliceCDS) + '\n';
        }
        data += '\n';

        // ── Query 5 (was 4): Bookings MTD ──
        AggregateResult[] bookingsMtd = [
            SELECT SUM(Net_New_INR__c) rev, COUNT(Id) cnt
            FROM Opportunity
            WHERE OwnerId = :userId AND StageName IN ('Order', 'POC') AND B_Deal_Date__c = THIS_MONTH
        ];
        Decimal mtdBookings = bookingsMtd[0].get('rev') != null ? (Decimal) bookingsMtd[0].get('rev') : 0;
        Integer mtdDeals = bookingsMtd[0].get('cnt') != null ? (Integer) bookingsMtd[0].get('cnt') : 0;

        // ── Query 6 (was 5): Won this quarter ──
        AggregateResult[] wonThisQ = [
            SELECT COUNT(Id) cnt, SUM(Net_New_INR__c) val
            FROM Opportunity
            WHERE OwnerId = :userId AND StageName IN ('Order', 'POC')
            AND B_Deal_Date__c >= :qStart AND B_Deal_Date__c <= :today
        ];
        Integer wonCount = wonThisQ[0].get('cnt') != null ? (Integer) wonThisQ[0].get('cnt') : 0;
        Decimal wonValue = wonThisQ[0].get('val') != null ? (Decimal) wonThisQ[0].get('val') : 0;

        // ── Query 7 (was 6): Lost this quarter ──
        AggregateResult[] lostThisQ = [
            SELECT COUNT(Id) cnt, SUM(Net_New_INR__c) val
            FROM Opportunity
            WHERE OwnerId = :userId AND StageName IN ('Closed Lost', 'Closed-No decision')
            AND CloseDate >= :qStart AND CloseDate <= :today
        ];
        Integer lostCount = lostThisQ[0].get('cnt') != null ? (Integer) lostThisQ[0].get('cnt') : 0;
        Decimal lostValue = lostThisQ[0].get('val') != null ? (Decimal) lostThisQ[0].get('val') : 0;

        // ── Query 8 (was 7): Meetings this week ──
        Integer meetingsThisWeek = [
            SELECT COUNT() FROM Event WHERE OwnerId = :userId AND StartDateTime = THIS_WEEK
        ];

        // ── Section: Pulse ──
        data += '=== PERFORMANCE PULSE ===\n';
        data += 'Bookings MTD: ' + formatMyDayLakhs(mtdBookings) + ' (' + mtdDeals + ' deals)\n';
        data += 'Open Pipeline: ' + formatMyDayLakhs(totalPipeline) + ' (' + totalOpenDeals + ' deals)\n';
        Integer totalDecided = wonCount + lostCount;
        if (totalDecided > 0) {
            Decimal winRateByCount = (Decimal) wonCount / totalDecided * 100;
            data += 'Win Rate (This Q by count): ' + winRateByCount.setScale(1) + '% (' + wonCount + ' won / ' + totalDecided + ' decided)\n';
            Decimal totalDecidedValue = wonValue + lostValue;
            if (totalDecidedValue > 0) {
                Decimal winRateByValue = wonValue / totalDecidedValue * 100;
                data += 'Win Rate (This Q by value): ' + winRateByValue.setScale(1) + '% (' + formatMyDayLakhs(wonValue) + ' won / ' + formatMyDayLakhs(totalDecidedValue) + ' decided)\n';
            }
        } else {
            data += 'Win Rate (This Q): No decided deals yet this quarter.\n';
        }
        data += 'Meetings This Week: ' + meetingsThisWeek + '\n\n';

        // ── Section: Data Hygiene ──
        data += '=== DATA HYGIENE ISSUES ===\n';
        Integer totalIssues = 0;
        for (Integer cnt : missingFieldCounts.values()) totalIssues += cnt;
        data += 'Total field gaps: ' + totalIssues + '\n';
        for (String field : missingFieldCounts.keySet()) {
            data += '- Missing ' + field + ': ' + missingFieldCounts.get(field) + ' deals\n';
        }
        if (!dataIssueExamples.isEmpty()) {
            data += 'Examples:\n' + JSON.serialize(dataIssueExamples) + '\n';
        }

        return data;
    }

    /**
     * Builds CSM (Customer Success Manager) daily brief data from targeted SOQLs.
     */
    @TestVisible
    private static String buildCsmBriefData(String userId) {
        Date today = Date.today();
        String data = '';

        // Calculate Indian FY quarter dates
        Integer m = today.month();
        Date quarterStart;
        if (m >= 4 && m <= 6) quarterStart = Date.newInstance(today.year(), 4, 1);
        else if (m >= 7 && m <= 9) quarterStart = Date.newInstance(today.year(), 7, 1);
        else if (m >= 10 && m <= 12) quarterStart = Date.newInstance(today.year(), 10, 1);
        else quarterStart = Date.newInstance(today.year(), 1, 1);

        // Prior quarter dates
        Date priorQStart, priorQEnd;
        if (m >= 4 && m <= 6) { priorQStart = Date.newInstance(today.year(), 1, 1); priorQEnd = Date.newInstance(today.year(), 3, 31); }
        else if (m >= 7 && m <= 9) { priorQStart = Date.newInstance(today.year(), 4, 1); priorQEnd = Date.newInstance(today.year(), 6, 30); }
        else if (m >= 10 && m <= 12) { priorQStart = Date.newInstance(today.year(), 7, 1); priorQEnd = Date.newInstance(today.year(), 9, 30); }
        else { priorQStart = Date.newInstance(today.year() - 1, 10, 1); priorQEnd = Date.newInstance(today.year() - 1, 12, 31); }

        // ── Query 1: At-risk accounts ──
        List<Account> atRiskAccounts = [
            SELECT Id, Name, RAG__c, Customer_Health__c, Churned_Day__c, Owner.Name, Last_Revenue_Date__c
            FROM Account
            WHERE Account_CSM__c = :userId
            AND (RAG__c IN ('RED', 'AMBER') OR Churned_Day__c > 0)
            ORDER BY RAG__c ASC, Churned_Day__c DESC NULLS LAST
            LIMIT 20
        ];
        data += '=== AT-RISK ACCOUNTS ===\n';
        data += 'Count: ' + atRiskAccounts.size() + '\n';
        for (Account a : atRiskAccounts) {
            data += '- ' + a.Name + ' | RAG: ' + (a.RAG__c != null ? a.RAG__c : 'Not set') +
                ' | Health: ' + (a.Customer_Health__c != null ? a.Customer_Health__c : 'N/A') +
                ' | Churned Days: ' + (a.Churned_Day__c != null ? String.valueOf(a.Churned_Day__c.intValue()) : '0') +
                ' | AD: ' + (a.Owner != null ? a.Owner.Name : '') + '\n';
        }
        data += '\n';

        // ── Query 2: Open Critical/Major tickets ──
        List<Case> criticalTickets = [
            SELECT CaseNumber, Subject, Priority, Status, Age_in_min__c, SLA_Violated__c, Account.Name
            FROM Case
            WHERE Account.Account_CSM__c = :userId
            AND Status IN ('New', 'Open', 'Note_added', 'Re-Open', 'Pending', 'In Progress')
            AND Priority IN ('Critical', 'Major')
            ORDER BY Priority ASC, Age_in_min__c DESC NULLS LAST
            LIMIT 20
        ];
        data += '=== CRITICAL/MAJOR OPEN TICKETS ===\n';
        data += 'Count: ' + criticalTickets.size() + '\n';
        for (Case c : criticalTickets) {
            String ageDisplay = c.Age_in_min__c != null ? String.valueOf((c.Age_in_min__c / 60).intValue()) + ' hrs' : 'N/A';
            data += '- #' + c.CaseNumber + ' | ' + (c.Account != null ? c.Account.Name : '') +
                ' | ' + c.Priority + ' | Age: ' + ageDisplay +
                ' | SLA: ' + (c.SLA_Violated__c == true ? 'BREACHED' : 'OK') +
                ' | ' + c.Status + '\n';
        }
        data += '\n';

        // ── Query 3 & 4: QBR coverage this quarter ──
        List<Account> csmAccounts = [
            SELECT Id, Name FROM Account WHERE Account_CSM__c = :userId LIMIT 200
        ];
        Set<Id> csmAccountIds = new Set<Id>();
        Map<Id, String> accountNames = new Map<Id, String>();
        for (Account a : csmAccounts) {
            csmAccountIds.add(a.Id);
            accountNames.put(a.Id, a.Name);
        }

        Set<Id> accountsWithQbr = new Set<Id>();
        if (!csmAccountIds.isEmpty()) {
            List<Event> qbrEvents = [
                SELECT Related_Account__c
                FROM Event
                WHERE Related_Account__c IN :csmAccountIds
                AND Meeting_Category__c = 'QBR'
                AND QBR_Document_Uploaded__c = true
                AND StartDateTime >= :quarterStart
                AND StartDateTime <= :today
            ];
            for (Event ev : qbrEvents) {
                if (ev.Related_Account__c != null) {
                    accountsWithQbr.add(ev.Related_Account__c);
                }
            }
        }

        List<String> accountsMissingQbr = new List<String>();
        for (Id acctId : csmAccountIds) {
            if (!accountsWithQbr.contains(acctId)) {
                accountsMissingQbr.add(accountNames.get(acctId));
            }
        }

        data += '=== QBR COVERAGE THIS QUARTER ===\n';
        data += 'Quarter: ' + String.valueOf(quarterStart) + ' to ' + String.valueOf(today) + '\n';
        data += 'Total accounts: ' + csmAccounts.size() + '\n';
        data += 'Accounts with completed QBR: ' + accountsWithQbr.size() + '\n';
        data += 'Accounts WITHOUT QBR this quarter: ' + accountsMissingQbr.size() + '\n';
        if (!accountsMissingQbr.isEmpty()) {
            Integer lim = Math.min(accountsMissingQbr.size(), 15);
            for (Integer i = 0; i < lim; i++) {
                data += '- ' + accountsMissingQbr[i] + '\n';
            }
            if (accountsMissingQbr.size() > 15) {
                data += '... and ' + (accountsMissingQbr.size() - 15) + ' more\n';
            }
        }
        data += '\n';

        // ── Query 5: Revenue MTD ──
        AggregateResult[] revMtd = [
            SELECT SUM(Revenue_Booked_Amount__c) rev, SUM(GP__c) gp
            FROM accounts_revenue__c
            WHERE CSM__c = :userId AND Revenue_Booked_On__c = THIS_MONTH
        ];
        Decimal mtdRev = revMtd[0].get('rev') != null ? (Decimal) revMtd[0].get('rev') : 0;
        Decimal mtdGp = revMtd[0].get('gp') != null ? (Decimal) revMtd[0].get('gp') : 0;

        data += '=== REVENUE PULSE ===\n';
        data += 'Revenue MTD: ' + formatMyDayLakhs(mtdRev) + '\n';
        data += 'GP MTD: ' + formatMyDayLakhs(mtdGp) + '\n';
        if (mtdRev > 0) {
            data += 'GP Margin: ' + (mtdGp / mtdRev * 100).setScale(1) + '%\n';
        }
        data += '\n';

        // ── Query 6 & 7: Revenue comparison (current Q vs prior Q) by account ──
        Map<String, Decimal> currentQRevByAcct = new Map<String, Decimal>();
        Map<String, Decimal> priorQRevByAcct = new Map<String, Decimal>();

        AggregateResult[] currentQRev = [
            SELECT Customer_Universal_Account__r.Name acctName, SUM(Revenue_Booked_Amount__c) rev
            FROM accounts_revenue__c
            WHERE CSM__c = :userId
            AND Revenue_Booked_On__c >= :quarterStart AND Revenue_Booked_On__c <= :today
            AND Customer_Universal_Account__c != null
            GROUP BY Customer_Universal_Account__r.Name
            ORDER BY SUM(Revenue_Booked_Amount__c) DESC
            LIMIT 50
        ];
        for (AggregateResult ar : currentQRev) {
            currentQRevByAcct.put((String) ar.get('acctName'), (Decimal) ar.get('rev'));
        }

        AggregateResult[] priorQRev = [
            SELECT Customer_Universal_Account__r.Name acctName, SUM(Revenue_Booked_Amount__c) rev
            FROM accounts_revenue__c
            WHERE CSM__c = :userId
            AND Revenue_Booked_On__c >= :priorQStart AND Revenue_Booked_On__c <= :priorQEnd
            AND Customer_Universal_Account__c != null
            GROUP BY Customer_Universal_Account__r.Name
            ORDER BY SUM(Revenue_Booked_Amount__c) DESC
            LIMIT 50
        ];
        for (AggregateResult ar : priorQRev) {
            priorQRevByAcct.put((String) ar.get('acctName'), (Decimal) ar.get('rev'));
        }

        // Find declining accounts (>20% drop)
        List<Map<String, Object>> declining = new List<Map<String, Object>>();
        Set<String> allAcctNames = new Set<String>();
        allAcctNames.addAll(currentQRevByAcct.keySet());
        allAcctNames.addAll(priorQRevByAcct.keySet());

        for (String acct : allAcctNames) {
            Decimal currentRev = currentQRevByAcct.containsKey(acct) ? currentQRevByAcct.get(acct) : 0;
            Decimal priorRev = priorQRevByAcct.containsKey(acct) ? priorQRevByAcct.get(acct) : 0;
            if (priorRev > 0 && currentRev < priorRev * 0.8) {
                Decimal changePct = ((currentRev - priorRev) / priorRev * 100).setScale(1);
                declining.add(new Map<String, Object>{
                    'Account' => acct,
                    'CurrentQ' => formatMyDayLakhs(currentRev),
                    'PriorQ'   => formatMyDayLakhs(priorRev),
                    'Change'   => String.valueOf(changePct) + '%'
                });
            }
        }

        data += '=== ACCOUNT REVENUE COMPARISON (Current Q vs Prior Q) ===\n';
        data += 'NOTE: Current quarter has only ' + quarterStart.daysBetween(today) + ' days of data vs full prior quarter.\n';
        data += 'Accounts with >20% revenue decline: ' + declining.size() + '\n';
        if (!declining.isEmpty()) {
            List<Map<String, Object>> slice4 = new List<Map<String, Object>>();
            for (Integer i = 0; i < Math.min(declining.size(), 10); i++) { slice4.add(declining[i]); }
            data += JSON.serialize(slice4) + '\n';
        }
        data += '\n';

        // ── Query 8: Accounts missing RAG or no recent activity ──
        Date sixtyDaysAgo = today.addDays(-60);
        List<Account> hygieneAccounts = [
            SELECT Name, RAG__c, Last_Activity__c
            FROM Account
            WHERE Account_CSM__c = :userId
            AND (RAG__c = null OR Last_Activity__c < :sixtyDaysAgo OR Last_Activity__c = null)
            LIMIT 20
        ];
        data += '=== DATA HYGIENE ===\n';
        Integer missingRag = 0;
        Integer noRecentActivity = 0;
        for (Account a : hygieneAccounts) {
            if (a.RAG__c == null) missingRag++;
            if (a.Last_Activity__c == null || a.Last_Activity__c < sixtyDaysAgo) noRecentActivity++;
        }
        data += 'Accounts missing RAG: ' + missingRag + '\n';
        data += 'Accounts with no activity in 60+ days: ' + noRecentActivity + '\n';
        for (Account a : hygieneAccounts) {
            List<String> issues = new List<String>();
            if (a.RAG__c == null) issues.add('No RAG');
            if (a.Last_Activity__c == null || a.Last_Activity__c < sixtyDaysAgo) issues.add('No recent activity');
            data += '- ' + a.Name + ': ' + String.join(issues, ', ') + '\n';
        }

        return data;
    }

    /**
     * Formats a decimal value into ₹ Lakhs or Crores for My Day brief data.
     */
    @TestVisible
    private static String formatMyDayLakhs(Decimal amount) {
        if (amount == null) return '₹0';
        if (Math.abs(amount) >= 10000000) {
            return '₹' + (amount / 10000000).setScale(2) + ' Cr';
        }
        if (Math.abs(amount) >= 100000) {
            return '₹' + (amount / 100000).setScale(2) + ' L';
        }
        return '₹' + amount.setScale(0).format();
    }

    @AuraEnabled
    public static AssistantResponse askQuestion(String userQuestion, String conversationContext) {
        Long startTime = System.currentTimeMillis();
        AssistantResponse resp = new AssistantResponse();
        String initialSoql = null;
        Integer retryCount = 0;
        String errorType = null;

        try {
            // Input validation
            if (String.isBlank(userQuestion)) {
                resp.success = false;
                resp.errorMessage = 'Please enter a question.';
                errorType = 'INPUT_ERROR';
                resp.executionTimeMs = System.currentTimeMillis() - startTime;
                logQuery(userQuestion, null, null, 0, false, resp.errorMessage, errorType, null, resp.executionTimeMs);
                return resp;
            }
            if (userQuestion.length() > 1000) {
                resp.success = false;
                resp.errorMessage = 'Question is too long. Please keep it under 1000 characters.';
                errorType = 'INPUT_ERROR';
                resp.executionTimeMs = System.currentTimeMillis() - startTime;
                logQuery(userQuestion, null, null, 0, false, resp.errorMessage, errorType, null, resp.executionTimeMs);
                return resp;
            }

            // Inject today's date and logged-in user context so Claude can handle personal queries accurately
            Date today = Date.today();
            Integer fyStartYear = today.month() >= 4 ? today.year() : today.year() - 1;
            String userFullName = UserInfo.getName();
            String currentUserId = UserInfo.getUserId();
            String dateContext = '\n[Today is ' + String.valueOf(today) +
                '. Current FY started ' + fyStartYear + '-04-01.' +
                ' Logged-in user: ' + userFullName + ' (Salesforce User ID: ' + currentUserId + ').]';
            String enrichedQuestion = userQuestion + dateContext;

            // Step -1: KPI deterministic engine (no Claude for query generation)
            // Must run BEFORE conversation history prepend — uses raw question for phrase matching
            try {
                KpiResult kpiResult = runKpiEngine(userQuestion, today);
                if (kpiResult != null) {
                    System.debug('KPI_ENGINE: ' + kpiResult.kpiId + ' detected, bypassing planner + SOQL prompt');

                    // Build conversation for Claude summary-only
                    List<Map<String, String>> kpiConversation = new List<Map<String, String>>();
                    kpiConversation.add(new Map<String, String>{
                        'role' => 'user',
                        'content' => userQuestion
                    });
                    kpiConversation.add(new Map<String, String>{
                        'role' => 'assistant',
                        'content' => 'I used the deterministic KPI engine (' + kpiResult.kpiLabel +
                            ') and executed ' + kpiResult.soqlQueries.size() + ' query(ies) against ' +
                            kpiResult.totalRecords + ' records. Results are pre-computed.'
                    });
                    kpiConversation.add(new Map<String, String>{
                        'role' => 'user',
                        'content' => 'Here are the pre-computed KPI results. Present them as a business summary:\n\n' +
                            kpiResult.resultsJson
                    });

                    ClaudeApiService.ClaudeResponse kpiSummary =
                        ClaudeApiService.sendConversation(KPI_SUMMARY_PROMPT, kpiConversation, 8192);

                    resp.answer = kpiSummary.content;
                    resp.soqlQuery = String.join(kpiResult.soqlQueries, '\n---\n');
                    resp.recordCount = kpiResult.totalRecords;
                    resp.success = true;
                    resp.executionTimeMs = System.currentTimeMillis() - startTime;
                    logQuery(userQuestion, kpiResult.soqlQueries[0], kpiResult.soqlQueries[0],
                             kpiResult.totalRecords, true, null, 'KPI_ENGINE', 0, resp.executionTimeMs);
                    return resp;
                }
            } catch (Exception kpiEx) {
                // KPI engine error — log and fall through to existing flow
                System.debug(LoggingLevel.WARN, 'KPI_ENGINE_ERROR: ' + kpiEx.getMessage() + ' — falling through');
            }

            // ── Conversational follow-up classifier ──
            // Detects pure conversational messages (no data intent) and answers
            // using conversation history without generating SOQL.
            if (String.isNotBlank(conversationContext) && isConversationalFollowup(userQuestion)) {
                resp.answer = handleConversationalFollowup(userQuestion, conversationContext);
                resp.success = true;
                logQuery(userQuestion, null, null,
                         0, true, null, 'FOLLOWUP', 0, resp.executionTimeMs);
                return resp;
            }

            // Prepend full conversation history so Claude can resolve follow-ups
            if (String.isNotBlank(conversationContext)) {
                String ctx = conversationContext.length() > 4000
                    ? '...' + conversationContext.substring(conversationContext.length() - 4000)
                    : conversationContext;
                enrichedQuestion = '[Conversation history]\n' + ctx +
                    '\n\n[Current question]\n' + enrichedQuestion;
            }

            // Step 0: Try structured planner path (revenue-only, behind feature flag)
            List<Map<String, String>> queries = null;
            Boolean usedPlanner = false;

            if (isStructuredPlannerEnabled()) {
                // Resolve revenue domain to get allowlists for validation
                AskSF_Domain__mdt revDomain = resolveDomain('accounts_revenue__c');
                if (revDomain != null) {
                    PlannerResult planResult = runRevenuePlanner(enrichedQuestion, revDomain);

                    if (planResult.status == 'SUCCESS') {
                        // Planner compiled SOQL — use it, skip the legacy prompt
                        queries = planResult.queries;
                        usedPlanner = true;

                    } else if (planResult.status == 'NOT_REVENUE') {
                        // Classification result: this question is not about revenue.
                        // Check if the target domain is blocked before falling through.
                        // The planner's reason often hints at the actual domain (bookings, credits, etc.)
                        String reason = planResult.reason != null ? planResult.reason.toLowerCase() : '';

                        // Check all registered non-queryable domains
                        // If the reason mentions a blocked domain's keywords, block it here
                        List<AskSF_Domain__mdt> blockedDomains = [
                            SELECT DeveloperName, DomainKeywords__c, UserMessageTemplate__c
                            FROM AskSF_Domain__mdt
                            WHERE Queryable__c = false
                            ORDER BY SortOrder__c ASC NULLS LAST
                        ];
                        Boolean blocked = false;
                        for (AskSF_Domain__mdt bd : blockedDomains) {
                            if (String.isNotBlank(bd.DomainKeywords__c)) {
                                for (String kw : bd.DomainKeywords__c.split(',')) {
                                    if (reason.contains(kw.trim().toLowerCase()) ||
                                        userQuestion.toLowerCase().contains(kw.trim().toLowerCase())) {
                                        // Match — block this question
                                        resp.success = true;
                                        resp.answer = String.isNotBlank(bd.UserMessageTemplate__c)
                                            ? bd.UserMessageTemplate__c
                                            : 'This data is not available through Ask SF.';
                                        resp.recordCount = 0;
                                        resp.executionTimeMs = System.currentTimeMillis() - startTime;
                                        logQuery(userQuestion, null, null, 0, true, null,
                                                 'PLANNER_DOMAIN_BLOCKED', 0, resp.executionTimeMs);
                                        return resp;
                                    }
                                }
                            }
                        }

                        // Not blocked — fall through to legacy SOQL prompt
                        // (handles bookings, pipeline, cases, leads, etc.)
                        System.debug('Planner: not_revenue, not blocked → falling through to SOQL prompt');
                    }
                    // else status == 'ERROR' → fall through to legacy SOQL prompt (safe fallback)
                }
            }

            // Step 1: Fall back to full SOQL prompt if planner didn't handle it
            if (queries == null) {
                ClaudeApiService.ClaudeResponse soqlResponse =
                    ClaudeApiService.sendMessage(SOQL_SYSTEM_PROMPT, enrichedQuestion, 8192);

                // Step 2: Extract ALL SOQL queries (supports 1-5 labeled queries)
                queries = SoqlSanitizer.extractAllSoql(soqlResponse.content);

                // Step 2.5: Apply semantic overrides to legacy-path SOQL
                List<SemanticOverride> legacyOverrides = detectOverrides(userQuestion);
                if (!legacyOverrides.isEmpty()) {
                    for (Integer qi = 0; qi < queries.size(); qi++) {
                        Map<String, String> q = queries[qi];
                        Map<String, Object> overrideResult =
                            applyOverridesToSoql(q.get('soql'), legacyOverrides);
                        List<String> appliedIds = (List<String>) overrideResult.get('applied');
                        if (!appliedIds.isEmpty()) {
                            q.put('soql', (String) overrideResult.get('soql'));
                            for (String oid : appliedIds) {
                                System.debug('SEMANTIC_OVERRIDE_APPLIED: ' + oid + ' (legacy path, query ' + qi + ')');
                            }
                        }
                    }
                }
            }

            initialSoql = queries[0].get('soql');

            // Step 3: Validate all queries target allowed objects
            for (Map<String, String> q : queries) {
                if (!SoqlSanitizer.isAllowedObject(q.get('soql'))) {
                    throw new AuraHandledException('This query targets a restricted object. Please ask about Opportunities, Accounts, Leads, Cases, or Contacts.');
                }
            }

            // Step 3.1: Domain capability check
            String primaryObject = SoqlSanitizer.extractObjectName(queries[0].get('soql'));
            AskSF_Domain__mdt domain = resolveDomain(primaryObject);

            if (domain != null && !domain.Queryable__c) {
                resp.success = true;
                resp.answer = String.isNotBlank(domain.UserMessageTemplate__c)
                    ? domain.UserMessageTemplate__c
                    : 'This data is not available through Ask SF (' + domain.SourceType__c + ' source).';
                resp.soqlQuery = queries[0].get('soql');
                resp.recordCount = 0;
                resp.executionTimeMs = System.currentTimeMillis() - startTime;
                logQuery(userQuestion, initialSoql, resp.soqlQuery, 0, true, null,
                         'DOMAIN_NOT_QUERYABLE', 0, resp.executionTimeMs);
                return resp;
            }

            String parityNote = null;
            if (domain != null && domain.Parity__c == 'APPROXIMATE') {
                parityNote = 'NOTE: This data domain (' + domain.DeveloperName +
                    ') has APPROXIMATE parity with dashboards. Numbers may differ from Tableau.';
            }

            // Step 3.5: Auto-split large object queries that span >5 months
            // This ensures H1/H2 split happens reliably even if Claude fails to split
            queries = autoSplitLargeObjectQueries(queries);

            // Step 4: Execute each query with per-query self-correction retry
            List<Map<String, Object>> allResults = new List<Map<String, Object>>();
            Integer totalRecords = 0;
            List<String> allSoqlQueries = new List<String>();

            for (Map<String, String> q : queries) {
                QueryResult qr = executeWithRetry(q.get('soql'), enrichedQuestion);
                retryCount += qr.retries;

                // Track the final (possibly corrected) SOQL
                allSoqlQueries.add(qr.finalSoql);

                // Handle both execution paths: Database.query() vs REST API callout
                if (qr.restApiJson != null) {
                    // REST API path — use actual fetched count, not totalSize
                    Integer count = qr.restApiRecordCount != null ? qr.restApiRecordCount : 0;
                    totalRecords += count;
                    Map<String, Object> resultEntry = new Map<String, Object>{
                        'label' => q.get('label'),
                        'soql' => qr.finalSoql,
                        'jsonResult' => qr.restApiJson,
                        'count' => count
                    };
                    if (qr.restApiTruncated) {
                        resultEntry.put('truncated', true);
                        resultEntry.put('totalSize', qr.restApiTotalSize);
                    }
                    allResults.add(resultEntry);
                } else {
                    // Standard Database.query() path
                    totalRecords += qr.records.size();
                    allResults.add(new Map<String, Object>{
                        'label' => q.get('label'),
                        'soql' => qr.finalSoql,
                        'records' => qr.records,
                        'count' => qr.records.size()
                    });
                }
            }

            // Store all queries in response (joined by separator for display)
            resp.soqlQuery = String.join(allSoqlQueries, '\n---\n');
            resp.recordCount = totalRecords;

            // Step 5: Build combined labeled results JSON
            // Budget: divide available space equally across queries so all queries get included
            Integer maxTotalChars = 80000;
            Integer maxPerQuery = allResults.size() > 0 ? maxTotalChars / allResults.size() : maxTotalChars;

            String resultsJson = '';
            for (Map<String, Object> result : allResults) {
                String label = (String) result.get('label');
                String soql = (String) result.get('soql');
                Integer count = (Integer) result.get('count');

                // Handle both execution paths
                String sectionJson;
                if (result.containsKey('jsonResult')) {
                    // REST API path — already serialized
                    sectionJson = (String) result.get('jsonResult');
                } else {
                    // Standard Database.query() path
                    List<SObject> records = (List<SObject>) result.get('records');
                    sectionJson = JSON.serialize(records);
                }

                // Pre-format monetary values in Lakhs/Crores so Claude doesn't do the math
                sectionJson = enrichJsonWithLakhsFormatting(sectionJson);

                // Compute aggregate totals BEFORE trimming (uses full dataset)
                String computedTotals = computeAggregateTotals(result);

                // If this section's JSON exceeds its budget, trim to top rows
                // Keep top rows (already sorted by ORDER BY DESC from SOQL) + totals
                Integer headerOverhead = 300; // label, SOQL, totals line
                Integer jsonBudget = maxPerQuery - headerOverhead;
                Integer originalRows = count;
                if (sectionJson.length() > jsonBudget && jsonBudget > 1000) {
                    sectionJson = trimJsonToFit(sectionJson, jsonBudget);
                }

                resultsJson += '=== ' + label + ' (' + count + ' records';
                if (result.containsKey('truncated') && (Boolean) result.get('truncated')) {
                    resultsJson += ' of ' + (Integer) result.get('totalSize') + ' total — TRUNCATED, analysis is partial';
                }
                if (sectionJson.length() < jsonBudget && originalRows > 100) {
                    resultsJson += ', showing top rows — full totals in PRE-COMPUTED TOTALS below';
                }
                resultsJson += ') ===\n';
                resultsJson += 'SOQL: ' + soql + '\n';
                resultsJson += sectionJson + '\n';

                if (String.isNotBlank(computedTotals)) {
                    resultsJson += computedTotals;
                }
                resultsJson += '\n';
            }

            // Step 6: Summarize results via Claude
            List<Map<String, String>> conversation = new List<Map<String, String>>();
            conversation.add(new Map<String, String>{
                'role' => 'user',
                'content' => userQuestion
            });

            String querySummary = 'I executed ' + allResults.size() + ' SOQL quer' +
                (allResults.size() == 1 ? 'y' : 'ies') + ':\n';
            for (Map<String, Object> result : allResults) {
                querySummary += '- ' + (String) result.get('label') + ': ' +
                    (String) result.get('soql') + ' → ' + (Integer) result.get('count') + ' records\n';
            }

            conversation.add(new Map<String, String>{
                'role' => 'assistant',
                'content' => querySummary
            });
            // Inject parity note for APPROXIMATE domains
            if (String.isNotBlank(parityNote)) {
                resultsJson = parityNote + '\n\n' + resultsJson;
            }

            conversation.add(new Map<String, String>{
                'role' => 'user',
                'content' => 'Here are the results (' + totalRecords + ' total records across ' +
                    allResults.size() + ' queries). Provide a business summary:\n\n' + resultsJson
            });

            ClaudeApiService.ClaudeResponse summaryResponse =
                ClaudeApiService.sendConversation(SUMMARY_SYSTEM_PROMPT, conversation, 8192);

            resp.answer = summaryResponse.content;
            resp.success = true;

        } catch (SoqlSanitizer.SoqlValidationException e) {
            resp.success = false;
            resp.errorMessage = 'Could not generate a valid query. Try rephrasing your question. (' + e.getMessage() + ')';
            errorType = 'SOQL_VALIDATION';
        } catch (System.QueryException e) {
            resp.success = false;
            resp.errorMessage = 'Query error: ' + e.getMessage() + (resp.soqlQuery != null ? '\nGenerated SOQL: ' + resp.soqlQuery : '');
            errorType = 'QUERY_ERROR';
        } catch (ClaudeApiService.ClaudeException e) {
            resp.success = false;
            resp.errorMessage = 'AI service error: ' + e.getMessage();
            errorType = 'API_ERROR';
        } catch (System.CalloutException e) {
            resp.success = false;
            resp.errorMessage = 'Could not reach the AI service. Please try again in a moment.';
            errorType = 'CALLOUT_ERROR';
        } catch (Exception e) {
            resp.success = false;
            resp.errorMessage = 'Unexpected error: ' + e.getMessage();
            errorType = 'UNKNOWN';
        }

        resp.executionTimeMs = System.currentTimeMillis() - startTime;

        // Log every query for analytics
        logQuery(userQuestion, initialSoql, resp.soqlQuery, retryCount,
                 resp.success == true, resp.errorMessage, errorType,
                 resp.recordCount, resp.executionTimeMs);

        return resp;
    }

    /**
     * Result wrapper for executeWithRetry — carries both the records and the final SOQL.
     * Supports two execution paths: Database.query() (records) or REST API callout (restApiJson).
     */
    private class QueryResult {
        List<SObject> records;
        String finalSoql;
        // REST API execution path — when set, records is null and this holds the JSON response
        String restApiJson;
        Integer restApiRecordCount;   // Actual number of records fetched (may be < totalSize if truncated)
        Integer restApiTotalSize;     // Salesforce's reported totalSize (full result set)
        Boolean restApiTruncated = false; // True if pagination cap hit before all pages fetched
        // Number of self-correction retries attempted (for analytics logging)
        Integer retries = 0;
    }

    // Salesforce governor limit is 50,000 rows per transaction.
    // Database.countQuery() is free (1 row). Pre-check to avoid uncatchable System.LimitException.
    private static final Integer ROW_SAFETY_LIMIT = 40000;

    // Test-only flag: when true, forces REST API execution path regardless of row estimate.
    @TestVisible private static Boolean forceRestApiExecution = false;

    // Objects known to have >50K rows — if estimation fails, assume unsafe and route to REST
    private static final Set<String> KNOWN_LARGE_OBJECTS = new Set<String>{
        'accounts_revenue__c', 'opportunity', 'case', 'lead', 'event', 'task',
        'opportunity_trend__c', 'saas_daily_usage__c'
    };

    /**
     * Auto-splits queries on large objects (accounts_revenue__c) when the date range
     * spans more than 5 months. Ensures reliable H1/H2 splitting even if Claude
     * generates a single full-year query.
     *
     * For queries already split by Claude (each ≤6 months), passes them through unchanged.
     * For unsplit queries spanning >5 months, creates H1 (Apr-Sep) and H2 (Oct-Mar) chunks.
     */
    @TestVisible
    private static List<Map<String, String>> autoSplitLargeObjectQueries(List<Map<String, String>> queries) {
        List<Map<String, String>> result = new List<Map<String, String>>();

        for (Map<String, String> q : queries) {
            String soql = q.get('soql');
            String label = q.get('label');
            String objectName = SoqlSanitizer.extractObjectName(soql);

            if (objectName == null || objectName.toLowerCase() != 'accounts_revenue__c') {
                result.add(q);
                continue;
            }

            // Extract date range: Revenue_Booked_On__c >= YYYY-MM-DD AND Revenue_Booked_On__c <= YYYY-MM-DD
            Pattern dateRangePattern = Pattern.compile(
                '(?i)Revenue_Booked_On__c\\s*>=\\s*(\\d{4}-\\d{2}-\\d{2})\\s+AND\\s+Revenue_Booked_On__c\\s*<=\\s*(\\d{4}-\\d{2}-\\d{2})'
            );
            Matcher dateMatcher = dateRangePattern.matcher(soql);

            if (!dateMatcher.find()) {
                result.add(q); // No parseable date range, keep as-is
                continue;
            }

            Date startDate = Date.valueOf(dateMatcher.group(1));
            Date endDate = Date.valueOf(dateMatcher.group(2));
            Integer monthSpan = startDate.monthsBetween(endDate);

            if (monthSpan <= 6) {
                result.add(q); // Already within safe range
                continue;
            }

            // Split into 6-month chunks
            System.debug('Auto-splitting ' + objectName + ' query spanning ' + monthSpan +
                ' months: ' + dateMatcher.group(1) + ' to ' + dateMatcher.group(2));

            // Capture the SOQL parts before and after the date range
            String beforeDates = soql.substring(0, dateMatcher.start());
            String afterDates = soql.substring(dateMatcher.end());

            // Strip any redundant Revenue_Booked_On__c filters that Claude may have added
            // (e.g., "AND Revenue_Booked_On__c >= 2024-03-23" as a rogue lookback filter)
            afterDates = afterDates.replaceAll(
                '(?i)\\s+AND\\s+Revenue_Booked_On__c\\s*(>=|<=|>|<|=)\\s*\\d{4}-\\d{2}-\\d{2}', ''
            );

            Date chunkStart = startDate;
            Integer chunkIndex = 1;
            while (chunkStart < endDate) {
                Date chunkEnd = chunkStart.addMonths(6).addDays(-1);
                if (chunkEnd > endDate) chunkEnd = endDate;

                String chunkSoql = beforeDates +
                    'Revenue_Booked_On__c >= ' + String.valueOf(chunkStart) +
                    ' AND Revenue_Booked_On__c <= ' + String.valueOf(chunkEnd) +
                    afterDates;

                // Create descriptive label (H1, H2, etc.)
                String halfLabel = chunkIndex == 1 ? 'H1' : 'H2';
                String monthRange = String.valueOf(chunkStart).substring(0, 7) + ' to ' +
                    String.valueOf(chunkEnd).substring(0, 7);
                String chunkLabel = label + ' (' + halfLabel + ': ' + monthRange + ')';

                result.add(new Map<String, String>{
                    'label' => chunkLabel,
                    'soql' => chunkSoql
                });

                System.debug('  Chunk ' + chunkIndex + ': ' + String.valueOf(chunkStart) + ' to ' + String.valueOf(chunkEnd));

                chunkStart = chunkEnd.addDays(1);
                chunkIndex++;
            }
        }

        return result;
    }

    /**
     * Estimates how many source rows a SOQL query would scan.
     * Computes aggregate totals from query results so Claude doesn't have to do arithmetic.
     * For aggregate queries with SUM/COUNT, sums up all numeric fields and appends a
     * PRE-COMPUTED TOTALS line that Claude can use directly in its summary.
     */
    // Known measure aliases/suffixes that should be summed in aggregate totals.
    // Numeric dimension fields like Quarter__c, Year__c, month numbers must NOT be summed.
    private static final Set<String> MEASURE_ALIASES = new Set<String>{
        'rev', 'gp', 'cnt', 'amount', 'value', 'cost', 'total', 'sum', 'count',
        'mrr', 'nrr', 'ob', 'target', 'variance', 'budget', 'net_new'
    };
    private static final Set<String> MEASURE_FIELD_SUFFIXES = new Set<String>{
        'amount__c', 'rev__c', 'gp__c', 'cost__c', 'value__c', 'mrr__c',
        'total__c', 'count__c', 'bvt__c', 'revenue__c'
    };

    // Known non-measure numeric fields that should never be summed
    // (even though they contain measure-like substrings like 'rev' in 'revMonth')
    private static final Set<String> NON_MEASURE_FIELDS = new Set<String>{
        'revmonth', 'revyear', 'quarter', 'month', 'year', 'recordcount',
        'escalation_level__c', 'ticket_reopen_count__c'
    };

    @TestVisible
    private static Boolean isMeasureField(String fieldKey) {
        if (fieldKey == null) return false;
        String lower = fieldKey.toLowerCase();
        // Exclusion list: known non-measure numeric fields
        if (NON_MEASURE_FIELDS.contains(lower)) return false;
        // exprN fields from AggregateResult are always measures (SUM, COUNT, AVG, etc.)
        if (lower.startsWith('expr')) return true;
        // Exact match on known aliases (e.g., 'rev', 'gp', 'cnt')
        if (MEASURE_ALIASES.contains(lower)) return true;
        // Suffix match on Salesforce field API names (e.g., Revenue_Booked_Amount__c)
        for (String suffix : MEASURE_FIELD_SUFFIXES) {
            if (lower.endsWith(suffix)) return true;
        }
        // Contains known measure keywords (handles aliases like 'total_gp', 'net_new_inr')
        for (String alias : MEASURE_ALIASES) {
            if (lower.contains(alias)) return true;
        }
        return false;
    }

    /**
     * Formats a raw numeric value as Indian Lakhs (÷100,000) or Crores (÷10,000,000).
     * This ensures Claude never has to do the Lakhs/Crores division itself,
     * eliminating the common LLM error of dividing by 1,000,000 instead of 100,000.
     */
    @TestVisible
    private static String formatAsLakhs(Decimal value) {
        if (value == null) return '₹0.00 L';
        Decimal absVal = value < 0 ? -value : value;
        String sign = value < 0 ? '-' : '';
        if (absVal >= 1000000000) {
            // >= ₹10,000 L (₹100 Cr) → show in Crores for very large values only
            Decimal crores = absVal / 10000000;
            return sign + '₹' + crores.setScale(2) + ' Cr';
        } else {
            // Show in Lakhs — consistent with Tableau dashboards
            Decimal lakhs = absVal / 100000;
            return sign + '₹' + lakhs.setScale(2) + ' L';
        }
    }

    /**
     * Enriches JSON result rows with pre-formatted Lakhs/Crores values for measure fields.
     * Adds a "_display" suffixed key for each numeric measure, e.g.:
     * "monthlyGP":24265419.21 → also adds "monthlyGP_display":"₹242.65 L"
     * This eliminates Claude's need to do Lakhs division (which it often gets wrong).
     */
    @TestVisible
    private static String enrichJsonWithLakhsFormatting(String jsonStr) {
        try {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
            if (rows == null || rows.isEmpty()) return jsonStr;

            // Identify measure fields from first row
            Map<String, Object> firstRow = (Map<String, Object>) rows[0];
            Set<String> measureKeys = new Set<String>();
            for (String key : firstRow.keySet()) {
                if (key == 'attributes' || key == 'Id') continue;
                Object val = firstRow.get(key);
                if ((val instanceof Decimal || val instanceof Double || val instanceof Integer || val instanceof Long)
                    && isMeasureField(key)) {
                    measureKeys.add(key);
                }
            }

            if (measureKeys.isEmpty()) return jsonStr;

            // Enrich each row with _display values
            for (Object rowObj : rows) {
                Map<String, Object> row = (Map<String, Object>) rowObj;
                for (String key : measureKeys) {
                    Object val = row.get(key);
                    if (val != null) {
                        Decimal numVal;
                        if (val instanceof Decimal) numVal = (Decimal) val;
                        else if (val instanceof Double) numVal = (Decimal) (Double) val;
                        else if (val instanceof Integer) numVal = (Decimal) (Integer) val;
                        else if (val instanceof Long) numVal = (Decimal) (Long) val;
                        else continue;
                        row.put(key + '_display', formatAsLakhs(numVal));
                    }
                }
            }

            return JSON.serialize(rows);
        } catch (Exception e) {
            // Non-critical — return original JSON if enrichment fails
            return jsonStr;
        }
    }

    private static String computeAggregateTotals(Map<String, Object> queryResult) {
        try {
            // Parse the JSON result (works for both REST API and Database.query paths)
            String jsonStr;
            if (queryResult.containsKey('jsonResult')) {
                jsonStr = (String) queryResult.get('jsonResult');
            } else {
                List<SObject> records = (List<SObject>) queryResult.get('records');
                if (records == null || records.isEmpty()) return null;
                jsonStr = JSON.serialize(records);
            }

            List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonStr);
            if (rows == null || rows.size() < 2) return null; // No need for totals on single-row results

            // Identify numeric MEASURE fields from first row — skip dimensions like Quarter, Year
            Map<String, Object> firstRow = (Map<String, Object>) rows[0];
            Map<String, Decimal> totals = new Map<String, Decimal>();
            for (String key : firstRow.keySet()) {
                if (key == 'attributes' || key == 'Id') continue;
                Object val = firstRow.get(key);
                if ((val instanceof Decimal || val instanceof Double || val instanceof Integer || val instanceof Long)
                    && isMeasureField(key)) {
                    totals.put(key, 0);
                }
            }

            if (totals.isEmpty()) return null;

            // Sum only measure fields across all rows
            for (Object rowObj : rows) {
                Map<String, Object> row = (Map<String, Object>) rowObj;
                for (String key : totals.keySet()) {
                    Object val = row.get(key);
                    if (val != null) {
                        Decimal current = totals.get(key);
                        if (val instanceof Decimal) {
                            totals.put(key, current + (Decimal) val);
                        } else if (val instanceof Double) {
                            totals.put(key, current + (Double) val);
                        } else if (val instanceof Integer) {
                            totals.put(key, current + (Integer) val);
                        } else if (val instanceof Long) {
                            totals.put(key, current + (Long) val);
                        }
                    }
                }
            }

            // Format totals line — show BOTH raw value and Lakhs-formatted value
            // so Claude never has to do the Lakhs division itself
            String result = 'PRE-COMPUTED TOTALS (use these exact values, do NOT recompute): ';
            List<String> parts = new List<String>();
            for (String key : totals.keySet()) {
                Decimal val = totals.get(key).setScale(2);
                String formatted = formatAsLakhs(val);
                parts.add(key + '=' + val + ' (' + formatted + ')');
            }
            return result + String.join(parts, ', ') + '\n';
        } catch (Exception e) {
            // Non-critical — if totals computation fails, Claude will compute them itself
            return null;
        }
    }

    /**
     * Trims a JSON array string to fit within a character budget.
     * Keeps the first N elements (top rows from ORDER BY DESC) that fit.
     * Returns valid JSON array.
     */
    @TestVisible
    private static String trimJsonToFit(String jsonArrayStr, Integer maxChars) {
        try {
            List<Object> rows = (List<Object>) JSON.deserializeUntyped(jsonArrayStr);
            if (rows == null || rows.isEmpty()) return jsonArrayStr;

            // Binary search-ish: start with estimated rows that fit, then adjust
            // Average ~150-200 chars per row for aggregate results
            Integer estimatedRows = Math.max(50, maxChars / 200);
            if (estimatedRows >= rows.size()) return jsonArrayStr; // Already fits

            // Keep top rows (already sorted by SOQL ORDER BY DESC)
            List<Object> trimmed = new List<Object>();
            for (Integer i = 0; i < Math.min(estimatedRows, rows.size()); i++) {
                trimmed.add(rows.get(i));
            }

            String result = JSON.serialize(trimmed);
            // If still too large, halve and retry
            while (result.length() > maxChars && trimmed.size() > 20) {
                Integer halfSize = trimmed.size() / 2;
                List<Object> smaller = new List<Object>();
                for (Integer i = 0; i < halfSize; i++) {
                    smaller.add(trimmed.get(i));
                }
                trimmed = smaller;
                result = JSON.serialize(trimmed);
            }
            return result;
        } catch (Exception e) {
            // If parsing fails, do a simple character truncation
            if (jsonArrayStr.length() > maxChars) {
                // Find last complete JSON object within budget
                Integer cutPoint = jsonArrayStr.lastIndexOf('},', maxChars);
                if (cutPoint > 0) {
                    return jsonArrayStr.substring(0, cutPoint + 1) + ']';
                }
            }
            return jsonArrayStr;
        }
    }

    /**
     * Uses Database.countQuery() which costs only 1 query row (NOT counted against 50K limit).
     * FAIL-CLOSED: for known large objects, estimation failure returns ROW_SAFETY_LIMIT + 1
     * to force the REST API path. For unknown objects, returns 0 (safe to proceed).
     */
    private static Integer estimateQueryRows(String soql) {
        String objectName = null;
        try {
            objectName = SoqlSanitizer.extractObjectName(soql);
            if (objectName == null) return 0;

            // Build COUNT query: keep FROM + WHERE, strip SELECT fields + GROUP BY + ORDER BY + LIMIT
            Pattern fromPattern = Pattern.compile('(?i)\\bFROM\\s+\\w+');
            Matcher fromMatcher = fromPattern.matcher(soql);
            if (!fromMatcher.find()) {
                return KNOWN_LARGE_OBJECTS.contains(objectName.toLowerCase()) ? ROW_SAFETY_LIMIT + 1 : 0;
            }
            String fromClause = fromMatcher.group();

            // Find WHERE clause (if any) — everything between WHERE and GROUP BY/ORDER BY/LIMIT/HAVING/end
            String whereClause = '';
            Pattern wherePattern = Pattern.compile('(?i)\\bWHERE\\b(.+?)(?:\\bGROUP\\s+BY\\b|\\bORDER\\s+BY\\b|\\bLIMIT\\b|\\bHAVING\\b|$)');
            Matcher whereMatcher = wherePattern.matcher(soql);
            if (whereMatcher.find()) {
                whereClause = ' WHERE' + whereMatcher.group(1);
            }

            String countSoql = 'SELECT COUNT() ' + fromClause + whereClause;
            return Database.countQuery(countSoql);
        } catch (Exception e) {
            // FAIL CLOSED for known large objects: if we can't estimate, assume it's too large
            if (objectName != null && KNOWN_LARGE_OBJECTS.contains(objectName.toLowerCase())) {
                System.debug(LoggingLevel.WARN, 'Row estimation failed for large object ' +
                    objectName + ': ' + e.getMessage() + '. Routing to REST API (fail-closed).');
                return ROW_SAFETY_LIMIT + 1;
            }
            // Unknown objects: fail open (proceed with Database.query)
            System.debug(LoggingLevel.WARN, 'Row estimation failed for ' + objectName + ': ' + e.getMessage());
            return 0;
        }
    }

    // Transaction-scoped cache: avoids repeated OAuth exchanges for multi-query analyses
    private static String cachedAccessToken;

    /**
     * Gets an API-enabled access token via OAuth refresh_token grant.
     * Lightning sessions are NOT API-enabled, so we use the stored refresh token
     * from AI_Assistant_Config__mdt to get a fresh API-enabled access token.
     * Caches the token for the duration of the transaction (up to 5 queries per askQuestion call).
     * Falls back to UserInfo.getSessionId() if no refresh token is configured.
     */
    private static String getApiAccessToken() {
        if (cachedAccessToken != null) {
            return cachedAccessToken;
        }
        // Read OAuth config from Custom Metadata
        AI_Assistant_Config__mdt config = AI_Assistant_Config__mdt.getInstance('Claude_API');
        String refreshToken = config?.SF_Refresh_Token__c;
        String clientId = config?.SF_Client_Id__c;

        if (String.isNotBlank(refreshToken) && String.isNotBlank(clientId)) {
            // Exchange refresh token for a fresh API-enabled access token
            HttpRequest tokenReq = new HttpRequest();
            tokenReq.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/oauth2/token');
            tokenReq.setMethod('POST');
            tokenReq.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            tokenReq.setBody('grant_type=refresh_token&client_id=' +
                EncodingUtil.urlEncode(clientId, 'UTF-8') +
                '&refresh_token=' + EncodingUtil.urlEncode(refreshToken, 'UTF-8'));
            tokenReq.setTimeout(15000);

            HttpResponse tokenRes = new Http().send(tokenReq);
            if (tokenRes.getStatusCode() == 200) {
                Map<String, Object> tokenData =
                    (Map<String, Object>) JSON.deserializeUntyped(tokenRes.getBody());
                cachedAccessToken = (String) tokenData.get('access_token');
                return cachedAccessToken;
            }
            System.debug(LoggingLevel.WARN, 'OAuth token exchange failed: ' +
                tokenRes.getStatusCode() + ' - falling back to session ID');
        }

        // Fallback: try the current session ID (works in non-Lightning contexts)
        String sessionId = UserInfo.getSessionId();
        if (String.isNotBlank(sessionId)) {
            cachedAccessToken = sessionId;
            return cachedAccessToken;
        }

        throw new System.QueryException(
            'Cannot execute large query: no API credentials available. ' +
            'Configure SF_Refresh_Token__c and SF_Client_Id__c in AI Assistant Config custom metadata.'
        );
    }

    /**
     * Executes a SOQL query via REST API callout to the org's own endpoint.
     * This creates a SEPARATE execution context with its own 50K row governor limit,
     * bypassing the cumulative limit of the current Apex transaction.
     * Used for large queries (accounts_revenue__c full-year, etc.) that would exceed
     * the synchronous 50K limit.
     *
     * NOTE on CRUD/FLS: The REST callout authenticates as the refresh-token owner
     * (currently the same admin who set up the integration). The REST API enforces
     * that user's profile permissions. For stricter per-user FLS, migrate to Named
     * Credentials with Per-User principal when the org allows Connected App creation.
     *
     * Handles REST API pagination: follows nextRecordsUrl until all pages are fetched
     * (capped at 10 pages / ~20,000 rows to avoid callout limits).
     */
    private static QueryResult executeViaRestApi(String soql) {
        QueryResult qr = new QueryResult();
        qr.finalSoql = soql;

        String accessToken = cachedAccessToken != null ? cachedAccessToken : getApiAccessToken();

        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        String nextUrl = baseUrl + '/services/data/v60.0/query?q=' +
            EncodingUtil.urlEncode(soql, 'UTF-8');

        List<Map<String, Object>> allCleanRecords = new List<Map<String, Object>>();
        Integer totalSize = 0;
        Integer pageCount = 0;
        final Integer MAX_PAGES = 10; // Safety cap: 10 pages × 2000 rows = 20K max

        while (nextUrl != null && pageCount < MAX_PAGES) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(nextUrl);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200) {
                String errMsg = 'REST API query failed (HTTP ' + res.getStatusCode() + ')';
                try {
                    List<Object> errors = (List<Object>) JSON.deserializeUntyped(res.getBody());
                    if (!errors.isEmpty()) {
                        Map<String, Object> firstErr = (Map<String, Object>) errors[0];
                        errMsg = (String) firstErr.get('message');
                    }
                } catch (Exception parseEx) {
                    errMsg += ': ' + res.getBody().abbreviate(500);
                }
                throw new System.QueryException(errMsg);
            }

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

            if (pageCount == 0) {
                totalSize = (Integer) responseMap.get('totalSize');
            }

            List<Object> records = (List<Object>) responseMap.get('records');
            for (Object rec : records) {
                Map<String, Object> recMap = (Map<String, Object>) rec;
                recMap.remove('attributes');
                allCleanRecords.add(recMap);
            }

            // Check for next page
            Boolean done = (Boolean) responseMap.get('done');
            if (done == true || done == null) {
                nextUrl = null;
            } else {
                String nextRecordsUrl = (String) responseMap.get('nextRecordsUrl');
                nextUrl = nextRecordsUrl != null ? baseUrl + nextRecordsUrl : null;
            }
            pageCount++;
        }

        qr.restApiJson = JSON.serialize(allCleanRecords);
        qr.restApiRecordCount = allCleanRecords.size(); // Actual fetched count
        qr.restApiTotalSize = totalSize;                // Salesforce's full count
        qr.restApiTruncated = (allCleanRecords.size() < totalSize);
        return qr;
    }

    /**
     * Executes a SOQL query with up to 2 self-correction retries via Claude.
     * Pre-checks row count: if too large for synchronous execution, routes to
     * REST API callout (separate execution context with own 50K limit).
     * Returns both the results and the (possibly corrected) final SOQL.
     */
    private static QueryResult executeWithRetry(String soql, String context) {
        QueryResult qr = new QueryResult();
        // Strip rogue lookback date filters Claude sometimes adds to revenue queries
        // (e.g., "AND Revenue_Booked_On__c >= 2024-03-24" — a 2-year lookback that is never needed)
        if (soql.containsIgnoreCase('accounts_revenue__c')) {
            // Find the primary date range (first >= and <= pair)
            Pattern primaryRange = Pattern.compile(
                '(?i)Revenue_Booked_On__c\\s*>=\\s*(\\d{4}-\\d{2}-\\d{2})\\s+AND\\s+Revenue_Booked_On__c\\s*<=\\s*(\\d{4}-\\d{2}-\\d{2})'
            );
            Matcher pm = primaryRange.matcher(soql);
            if (pm.find()) {
                // Remove any ADDITIONAL Revenue_Booked_On__c filters after the primary range
                String before = soql.substring(0, pm.end());
                String after = soql.substring(pm.end());
                after = after.replaceAll(
                    '(?i)\\s+AND\\s+Revenue_Booked_On__c\\s*(>=|<=|>|<|=)\\s*\\d{4}-\\d{2}-\\d{2}', ''
                );
                soql = before + after;
            }
        }
        qr.finalSoql = soql;
        System.QueryException lastQueryError = null;

        for (Integer attempt = 0; attempt < 3; attempt++) {
            try {
                // Pre-check: will this query exceed the governor limit?
                Integer headroom = Limits.getLimitQueryRows() - Limits.getQueryRows();
                Integer estimatedRows = estimateQueryRows(qr.finalSoql);

                Boolean tooManyRows = estimatedRows > 0 &&
                    (estimatedRows > ROW_SAFETY_LIMIT || estimatedRows > headroom - 1000);
                if (tooManyRows || forceRestApiExecution) {
                    // Too many rows for synchronous Database.query() — use REST API callout.
                    // Each REST API call gets its own execution context with a fresh 50K limit.
                    // NOTE: REST path executes under the OAuth principal's CRUD/FLS, not the
                    // LWC user's. Acceptable for admin-only read-only aggregate queries.
                    // For per-user FLS, migrate to Named Credentials with Per-User principal.
                    System.debug('Pre-check: ' + estimatedRows + ' rows estimated (headroom: ' +
                        headroom + '). Routing to REST API callout.');
                    return executeViaRestApi(qr.finalSoql);
                }

                qr.records = Database.query(qr.finalSoql);
                // CRUD/FLS enforcement: strip fields the running user cannot read
                if (!qr.records.isEmpty()) {
                    SObjectAccessDecision decision = Security.stripInaccessible(
                        AccessType.READABLE, qr.records
                    );
                    qr.records = decision.getRecords();
                }
                return qr;
            } catch (System.QueryException e) {
                lastQueryError = e;
                qr.retries++;
                if (attempt < 2) {
                    try {
                        String fixPrompt =
                            'Your SOQL query failed. Analyze the error and return a CORRECTED query.\n' +
                            'Error: ' + e.getMessage() + '\n' +
                            'Failed query: ' + qr.finalSoql + '\n' +
                            'Original request: ' + context + '\n' +
                            'Return ONLY the fixed SOQL in ```soql ``` code blocks.';
                        ClaudeApiService.ClaudeResponse fixResp =
                            ClaudeApiService.sendMessage(SOQL_SYSTEM_PROMPT, fixPrompt, 8192);
                        String fixedSoql = SoqlSanitizer.extractSoql(fixResp.content);
                        if (!SoqlSanitizer.isAllowedObject(fixedSoql)) {
                            break;
                        }
                        qr.finalSoql = fixedSoql;
                    } catch (Exception retryEx) {
                        break;
                    }
                }
            }
        }

        if (lastQueryError != null) {
            throw lastQueryError;
        }
        return qr;
    }

    /**
     * Logs query to AI_Query_Log__c for analytics. Failures silently caught
     * so logging never breaks the main flow.
     */
    private static void logQuery(String question, String initialSoql, String finalSoql,
                                  Integer retryCount, Boolean success, String errorMessage,
                                  String errorType, Integer recordCount, Long executionTimeMs) {
        try {
            AI_Query_Log__c log = new AI_Query_Log__c(
                Question__c = question != null ? question.abbreviate(5000) : null,
                Initial_SOQL__c = initialSoql != null ? initialSoql.abbreviate(5000) : null,
                Final_SOQL__c = finalSoql != null ? finalSoql.abbreviate(5000) : null,
                Retry_Count__c = retryCount,
                Success__c = success,
                Error_Message__c = errorMessage != null ? errorMessage.abbreviate(5000) : null,
                Error_Type__c = errorType,
                Record_Count__c = recordCount,
                Execution_Time_Ms__c = executionTimeMs,
                Batch_Id__c = currentBatchId
            );
            insert log;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to log query: ' + e.getMessage());
        }
    }
}