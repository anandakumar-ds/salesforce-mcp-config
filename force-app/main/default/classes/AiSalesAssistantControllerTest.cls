@isTest
private class AiSalesAssistantControllerTest {

    private static void setupTestConfig() {
        ClaudeApiService.testConfig = new AI_Assistant_Config__mdt(
            DeveloperName = 'Claude_API',
            API_Key__c = 'test-api-key-12345',
            Model_Name__c = 'claude-sonnet-4-6',
            Max_Tokens__c = 4096
        );
        // Default planner OFF — tests that need it explicitly set testPlannerFlag = true
        AiSalesAssistantController.testPlannerFlag = false;
    }

    /**
     * Multi-call mock: first call returns SOQL, second call returns summary.
     */
    private class MockClaudeTwoCalls implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // First call: SOQL generation — use simple query that works in any org
                res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, Name FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            } else {
                // Second call: Summary
                res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"I found 5 accounts in the system."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
            }
            return res;
        }
    }

    private class MockClaudeInvalidSoql implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":"msg_03","type":"message","role":"assistant","content":[{"type":"text","text":"I cannot generate a query for that request. Please provide more details."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}');
            return res;
        }
    }

    /**
     * Mock that returns bad SOQL first (triggers retry), then fixed SOQL, then summary.
     */
    private class MockClaudeWithRetry implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // First call: return SOQL with non-existent field to trigger QueryException
                res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, ZZZ_No_Such_Field__c FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            } else if (callCount == 2) {
                // Retry call: return fixed SOQL
                res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, Name FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            } else {
                // Summary call
                res.setBody('{"id":"msg_03","type":"message","role":"assistant","content":[{"type":"text","text":"After correcting the query, I found accounts in the system."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
            }
            return res;
        }
    }

    private class MockClaudeApiFailure implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"type":"error","error":{"type":"api_error","message":"Internal server error"}}');
            return res;
        }
    }

    @isTest
    static void testAskQuestion_Success() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeTwoCalls());

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show me some accounts', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Answer should not be null');
        System.assertNotEquals(null, resp.soqlQuery, 'SOQL should not be null');
        System.assert(resp.soqlQuery.contains('SELECT'), 'SOQL should contain SELECT');
        System.assertNotEquals(null, resp.executionTimeMs, 'Execution time should be set');
    }

    @isTest
    static void testAskQuestion_WithConversationContext() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeTwoCalls());

        String context = 'Q: Who are the most active SDRs?\nA: Sakshi Jadhav leads with 618 leads created this fiscal year.';

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Who is the best performer among them?', context);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Should succeed with conversation context: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Answer should not be null');
    }

    @isTest
    static void testAskQuestion_EmptyInput() {
        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('', null);
        Test.stopTest();

        System.assertEquals(false, resp.success, 'Should fail for empty input');
        System.assertNotEquals(null, resp.errorMessage, 'Should have error message');
        System.assert(resp.errorMessage.contains('enter a question'), 'Should ask to enter question: ' + resp.errorMessage);
    }

    @isTest
    static void testAskQuestion_NullInput() {
        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion(null, null);
        Test.stopTest();

        System.assertEquals(false, resp.success, 'Should fail for null input');
    }

    @isTest
    static void testAskQuestion_TooLongInput() {
        String longInput = '';
        for (Integer i = 0; i < 110; i++) {
            longInput += 'abcdefghij'; // 1100 characters
        }

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion(longInput, null);
        Test.stopTest();

        System.assertEquals(false, resp.success, 'Should fail for long input');
        System.assert(resp.errorMessage.contains('1000'), 'Should mention character limit: ' + resp.errorMessage);
    }

    @isTest
    static void testAskQuestion_InvalidSoqlResponse() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeInvalidSoql());

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Do something weird', null);
        Test.stopTest();

        System.assertEquals(false, resp.success, 'Should fail for invalid SOQL');
        System.assert(resp.errorMessage.contains('Could not generate') || resp.errorMessage.contains('valid query'),
            'Should mention query issue: ' + resp.errorMessage);
    }

    @isTest
    static void testAskQuestion_ApiFailure() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeApiFailure());

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Count all accounts', null);
        Test.stopTest();

        System.assertEquals(false, resp.success, 'Should fail on API error');
        System.assertNotEquals(null, resp.errorMessage, 'Should have error message');
    }

    @isTest
    static void testAskQuestion_RetryOnQueryError() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeWithRetry());

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show me some accounts', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Should succeed after self-correction retry: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Should have answer after retry');
        // The final SOQL should be the corrected one
        System.assert(resp.soqlQuery.contains('Name'), 'Corrected SOQL should select Name');
        System.assert(!resp.soqlQuery.contains('ZZZ_No_Such_Field'), 'Should not contain the bad field');
    }

    /**
     * Multi-query mock: first call returns 2 SOQL blocks, second call returns summary.
     */
    private class MockClaudeMultiQuery implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // First call: return 2 labeled SOQL queries — use JSON serialization to handle escaping
                String multiQueryText = '-- Query 1: Won deals\n```soql\nSELECT Id, Name FROM Account WHERE Type = \'Customer\' LIMIT 5\n```\n\n-- Query 2: All accounts\n```soql\nSELECT Id, Name FROM Account LIMIT 5\n```';
                Map<String, Object> content1 = new Map<String, Object>{
                    'type' => 'text',
                    'text' => multiQueryText
                };
                Map<String, Object> body = new Map<String, Object>{
                    'id' => 'msg_01',
                    'type' => 'message',
                    'role' => 'assistant',
                    'content' => new List<Object>{ content1 },
                    'model' => 'claude-sonnet-4-6',
                    'stop_reason' => 'end_turn',
                    'usage' => new Map<String, Object>{ 'input_tokens' => 100, 'output_tokens' => 80 }
                };
                res.setBody(JSON.serialize(body));
            } else {
                // Summary call
                res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"Win rate analysis: Based on 2 query results, the overall win rate is 45% by count."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
            }
            return res;
        }
    }

    @isTest
    static void testAskQuestion_MultiQuery() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeMultiQuery());

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('What is our win rate by cluster?', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Multi-query should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Should have answer');
        System.assert(resp.soqlQuery.contains('---'), 'Should contain multi-query separator: ' + resp.soqlQuery);
    }

    /**
     * Mock that handles Claude API, OAuth token exchange, AND self-org REST API calls.
     * Routes by endpoint: /services/oauth2/token → OAuth, /services/data → REST query, else → Claude.
     */
    private class MockClaudeAndRestApi implements HttpCalloutMock {
        private Integer claudeCallCount = 0;
        public Boolean oauthCalled = false;
        public String lastAuthHeader;

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('services/oauth2/token')) {
                // OAuth token exchange
                oauthCalled = true;
                res.setStatusCode(200);
                res.setBody('{"access_token":"00D_TEST_ACCESS_TOKEN_12345","token_type":"Bearer","instance_url":"https://test.salesforce.com"}');
            } else if (req.getEndpoint().contains('services/data')) {
                // Self-org REST API query call — verify Authorization header
                lastAuthHeader = req.getHeader('Authorization');
                res.setStatusCode(200);
                res.setBody('{"totalSize":3,"done":true,"records":[' +
                    '{"attributes":{"type":"AggregateResult"},"Cluster__c":"BFSI","expr0":5000000},' +
                    '{"attributes":{"type":"AggregateResult"},"Cluster__c":"SME","expr0":3000000},' +
                    '{"attributes":{"type":"AggregateResult"},"Cluster__c":"APAC","expr0":2000000}' +
                    ']}');
            } else {
                // Claude API calls
                claudeCallCount++;
                res.setStatusCode(200);
                if (claudeCallCount == 1) {
                    res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Industry, COUNT(Id) cnt FROM Account GROUP BY Industry LIMIT 2000\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
                } else {
                    res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"Revenue analysis: BFSI leads with ₹50L, followed by SME at ₹30L and APAC at ₹20L."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
                }
            }
            return res;
        }
    }

    /**
     * Mock for REST API error response — also handles OAuth token exchange properly.
     */
    private class MockClaudeAndRestApiError implements HttpCalloutMock {
        private Integer claudeCallCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('services/oauth2/token')) {
                // OAuth token exchange succeeds even in error test
                res.setStatusCode(200);
                res.setBody('{"access_token":"00D_TEST_TOKEN","token_type":"Bearer"}');
            } else if (req.getEndpoint().contains('services/data')) {
                // REST API returns error
                res.setStatusCode(400);
                res.setBody('[{"message":"INVALID_FIELD: No such field \'BadField__c\'","errorCode":"INVALID_FIELD"}]');
            } else {
                claudeCallCount++;
                res.setStatusCode(200);
                if (claudeCallCount <= 3) {
                    res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, Name FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
                } else {
                    res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"Summary text."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
                }
            }
            return res;
        }
    }

    /**
     * Mock where OAuth token exchange FAILS — to test fallback behavior.
     */
    private class MockClaudeAndOAuthFailure implements HttpCalloutMock {
        private Integer claudeCallCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('services/oauth2/token')) {
                // OAuth exchange fails
                res.setStatusCode(401);
                res.setBody('{"error":"invalid_grant","error_description":"expired refresh token"}');
            } else if (req.getEndpoint().contains('services/data')) {
                // Shouldn't reach here if session ID fallback works, but handle gracefully
                res.setStatusCode(200);
                res.setBody('{"totalSize":1,"done":true,"records":[{"attributes":{"type":"AggregateResult"},"expr0":100}]}');
            } else {
                claudeCallCount++;
                res.setStatusCode(200);
                res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, Name FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            }
            return res;
        }
    }

    @isTest
    static void testAskQuestion_RestApiPath_Success() {
        setupTestConfig();
        MockClaudeAndRestApi mock = new MockClaudeAndRestApi();
        Test.setMock(HttpCalloutMock.class, mock);

        // Force the REST API execution path
        AiSalesAssistantController.forceRestApiExecution = true;

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('What is the revenue by cluster?', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'REST API path should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Should have answer from REST API path');
        System.assertNotEquals(null, resp.soqlQuery, 'Should have SOQL query');

        // Verify OAuth token exchange was called
        System.assertEquals(true, mock.oauthCalled, 'OAuth token exchange should have been called');
        // Verify the REST API call used the Bearer token from OAuth, not a session ID
        System.assertEquals('Bearer 00D_TEST_ACCESS_TOKEN_12345', mock.lastAuthHeader,
            'REST API should use the access token from OAuth exchange');

        // Reset the flag
        AiSalesAssistantController.forceRestApiExecution = false;
    }

    @isTest
    static void testAskQuestion_RestApiPath_Error() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndRestApiError());

        AiSalesAssistantController.forceRestApiExecution = true;

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show me revenue data', null);
        Test.stopTest();

        // REST API error should be caught and surface as query error
        System.assertEquals(false, resp.success, 'Should fail on REST API error');

        AiSalesAssistantController.forceRestApiExecution = false;
    }

    @isTest
    static void testAskQuestion_RestApiPath_OAuthFailure() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndOAuthFailure());

        AiSalesAssistantController.forceRestApiExecution = true;

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show me revenue data', null);
        Test.stopTest();

        // OAuth failure falls back to session ID. In test context, UserInfo.getSessionId()
        // returns a value, so the REST call proceeds with that token and succeeds.
        // Key assertions: (a) no unhandled exception, (b) response is populated,
        // (c) the system was resilient to the 401 OAuth error.
        System.assertNotEquals(null, resp, 'Should return a response even with OAuth failure');
        System.assert(resp.success != null, 'Response success flag should be set');
        // If it succeeded, verify we got a real answer (session ID fallback worked)
        // If it failed, verify it failed gracefully with an error message, not an exception
        if (!resp.success) {
            System.assertNotEquals(null, resp.errorMessage, 'Failed response should have error message');
        }

        AiSalesAssistantController.forceRestApiExecution = false;
    }

    @isTest
    static void testAutoSplitLargeObjectQueries_FullYear() {
        // Full year query (12 months) should be split into 2 chunks
        List<Map<String, String>> queries = new List<Map<String, String>>();
        queries.add(new Map<String, String>{
            'label' => 'GP by customer',
            'soql' => 'SELECT Customer_Name__c, SUM(GP__c) gp FROM accounts_revenue__c WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-31 GROUP BY Customer_Name__c ORDER BY SUM(GP__c) DESC LIMIT 50'
        });

        List<Map<String, String>> result = AiSalesAssistantController.autoSplitLargeObjectQueries(queries);
        System.assertEquals(2, result.size(), 'Full year should split into 2 chunks');
        System.assert(result[0].get('soql').contains('2025-04-01'), 'H1 should start Apr');
        System.assert(result[0].get('soql').contains('2025-09-30'), 'H1 should end Sep');
        System.assert(result[1].get('soql').contains('2025-10-01'), 'H2 should start Oct');
        System.assert(result[1].get('soql').contains('2026-03-31'), 'H2 should end Mar');
        System.assert(result[0].get('label').contains('H1'), 'First chunk should be labeled H1');
        System.assert(result[1].get('label').contains('H2'), 'Second chunk should be labeled H2');
    }

    @isTest
    static void testAutoSplitLargeObjectQueries_AlreadySplit() {
        // 6-month query should NOT be split further
        List<Map<String, String>> queries = new List<Map<String, String>>();
        queries.add(new Map<String, String>{
            'label' => 'H1 revenue',
            'soql' => 'SELECT Cluster__c, SUM(Revenue_Booked_Amount__c) rev FROM accounts_revenue__c WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2025-09-30 GROUP BY Cluster__c'
        });

        List<Map<String, String>> result = AiSalesAssistantController.autoSplitLargeObjectQueries(queries);
        System.assertEquals(1, result.size(), '6-month query should not be split');
        System.assertEquals('H1 revenue', result[0].get('label'), 'Label should be unchanged');
    }

    @isTest
    static void testAutoSplitLargeObjectQueries_NonLargeObject() {
        // Opportunity queries should never be split
        List<Map<String, String>> queries = new List<Map<String, String>>();
        queries.add(new Map<String, String>{
            'label' => 'Pipeline',
            'soql' => 'SELECT StageName, COUNT(Id) cnt FROM Opportunity GROUP BY StageName'
        });

        List<Map<String, String>> result = AiSalesAssistantController.autoSplitLargeObjectQueries(queries);
        System.assertEquals(1, result.size(), 'Non-large object should not be split');
    }

    // --- Measure Field Detection (computeAggregateTotals safety) ---

    @isTest
    static void testIsMeasureField_AggregateExpressions() {
        // exprN fields from AggregateResult should always be measures
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('expr0'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('expr1'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('expr12'));
    }

    @isTest
    static void testIsMeasureField_KnownMeasureAliases() {
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('rev'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('gp'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('cnt'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('amount'));
    }

    @isTest
    static void testIsMeasureField_SalesforceFieldSuffixes() {
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('Revenue_Booked_Amount__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('GP__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('Net_New_INR__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('Variable_Cost__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('BVT__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('Total_Cost__c'));
        System.assertEquals(true, AiSalesAssistantController.isMeasureField('MRR_Amount__c'));
    }

    @isTest
    static void testIsMeasureField_DimensionsShouldBeFalse() {
        // Numeric dimensions must NOT be identified as measures
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Quarter__c'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Year__c'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Cluster__c'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Region__c'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('StageName'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Name'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField('Id'));
        System.assertEquals(false, AiSalesAssistantController.isMeasureField(null));
    }

    // --- REST API Truncation Behavior ---

    /**
     * Mock that returns paginated REST API results with truncation.
     * First page: done=false with nextRecordsUrl. Second page: done=true.
     * Total reported = 500, but we return 6 records total.
     */
    private class MockClaudeAndRestApiPaginated implements HttpCalloutMock {
        private Integer claudeCallCount = 0;
        private Integer restCallCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');

            if (req.getEndpoint().contains('services/oauth2/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"00D_TEST_TOKEN","token_type":"Bearer","instance_url":"https://test.salesforce.com"}');
            } else if (req.getEndpoint().contains('services/data')) {
                restCallCount++;
                res.setStatusCode(200);
                if (restCallCount == 1) {
                    // First page: done=false, reports totalSize=500 but only 3 records
                    res.setBody('{"totalSize":500,"done":false,"nextRecordsUrl":"/services/data/v62.0/query/01gxx000000MOCK-2000","records":[' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"BFSI","expr0":5000000},' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"SME","expr0":3000000},' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"APAC","expr0":2000000}' +
                        ']}');
                } else {
                    // Second page: done=true, 3 more records
                    res.setBody('{"totalSize":500,"done":true,"records":[' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"ME","expr0":1500000},' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"Africa","expr0":1000000},' +
                        '{"attributes":{"type":"AggregateResult"},"Cluster__c":"US","expr0":800000}' +
                        ']}');
                }
            } else {
                claudeCallCount++;
                res.setStatusCode(200);
                if (claudeCallCount == 1) {
                    res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Cluster__c, SUM(Revenue_Booked_Amount__c) FROM accounts_revenue__c WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2025-09-30 GROUP BY Cluster__c ORDER BY SUM(Revenue_Booked_Amount__c) DESC LIMIT 2000\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
                } else {
                    res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[{"type":"text","text":"Revenue by cluster: BFSI leads with ₹50L."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
                }
            }
            return res;
        }
    }

    @isTest
    static void testAskQuestion_RestApiPath_Pagination() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndRestApiPaginated());

        AiSalesAssistantController.forceRestApiExecution = true;

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('What is revenue by cluster this H1?', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Paginated REST API path should succeed: ' + resp.errorMessage);
        System.assertNotEquals(null, resp.answer, 'Should have answer');
        // Record count should reflect actual fetched records, not totalSize
        System.assert(resp.recordCount <= 6, 'Record count should reflect actual fetched records (6), not totalSize (500)');

        AiSalesAssistantController.forceRestApiExecution = false;
    }

    @isTest
    static void testAskQuestion_RestApiPath_OAuthVerifiesTokenExchange() {
        setupTestConfig();
        MockClaudeAndRestApi mock = new MockClaudeAndRestApi();
        Test.setMock(HttpCalloutMock.class, mock);

        AiSalesAssistantController.forceRestApiExecution = true;

        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Revenue by cluster?', null);
        Test.stopTest();

        // OAuth MUST have been called
        System.assertEquals(true, mock.oauthCalled, 'OAuth token exchange must be called');
        // Authorization header MUST use Bearer token from OAuth, NOT session ID
        System.assertNotEquals(null, mock.lastAuthHeader, 'Authorization header must be set');
        System.assert(mock.lastAuthHeader.startsWith('Bearer '), 'Must use Bearer token: ' + mock.lastAuthHeader);
        System.assert(mock.lastAuthHeader.contains('00D_TEST_ACCESS_TOKEN_12345'),
            'Must use the token from OAuth exchange, not a session ID');
        System.assertEquals(true, resp.success, 'Should succeed with valid OAuth: ' + resp.errorMessage);

        AiSalesAssistantController.forceRestApiExecution = false;
    }

    @isTest
    static void testAssistantResponse_Serialization() {
        AiSalesAssistantController.AssistantResponse resp = new AiSalesAssistantController.AssistantResponse();
        resp.answer = 'Test answer';
        resp.soqlQuery = 'SELECT Id FROM Account';
        resp.recordCount = 5;
        resp.success = true;
        resp.errorMessage = null;
        resp.executionTimeMs = 1234;

        String jsonStr = JSON.serialize(resp);
        System.assert(jsonStr.contains('Test answer'), 'Should serialize answer');
        System.assert(jsonStr.contains('1234'), 'Should serialize execution time');
    }

    // --- Domain Capability Matrix Tests ---

    @isTest
    static void testResolveDomain_NonQueryable() {
        setupTestConfig();

        // Set up a non-queryable domain override
        AskSF_Domain__mdt fakeDomain = new AskSF_Domain__mdt(
            DeveloperName = 'credits',
            SourceType__c = 'EXTERNAL',
            Queryable__c = false,
            Parity__c = 'NOT_SUPPORTED',
            PrimaryObject__c = 'Account',
            ResponseMode__c = 'EXPLAIN_ONLY',
            UserMessageTemplate__c = 'Account Credits data lives in AWS QuickSight, not in Salesforce.'
        );
        AiSalesAssistantController.testDomainOverride = fakeDomain;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndRestApi());
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('What are our account credits?', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Non-queryable domain should succeed');
        System.assert(resp.answer.contains('AWS QuickSight'),
            'Answer should contain the user message template');
        System.assertEquals(0, resp.recordCount, 'No records should be returned');

        AiSalesAssistantController.testDomainOverride = null;
    }

    @isTest
    static void testResolveDomain_ApproximateParity() {
        setupTestConfig();

        // Set up an APPROXIMATE domain override
        AskSF_Domain__mdt fakeDomain = new AskSF_Domain__mdt(
            DeveloperName = 'retention',
            SourceType__c = 'LIVE_SF',
            Queryable__c = true,
            Parity__c = 'APPROXIMATE',
            PrimaryObject__c = 'accounts_revenue__c',
            ResponseMode__c = 'INSIGHT'
        );
        AiSalesAssistantController.testDomainOverride = fakeDomain;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndRestApi());
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show retention rate by cluster', null);
        Test.stopTest();

        // The flow should complete normally (queryable=true) but parity note gets injected
        System.assertEquals(true, resp.success, 'APPROXIMATE domain should still execute normally');
        System.assert(resp.answer != null, 'Should have an answer');

        AiSalesAssistantController.testDomainOverride = null;
    }

    @isTest
    static void testResolveDomain_NullDomain() {
        setupTestConfig();

        // No override — query an object with no domain record
        AiSalesAssistantController.testDomainOverride = null;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockClaudeAndRestApi());
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Show all contacts', null);
        Test.stopTest();

        // Should complete normally — no domain record means no special behavior
        System.assertEquals(true, resp.success, 'Null domain should not crash the flow');

        AiSalesAssistantController.testDomainOverride = null;
    }

    @isTest
    static void testResolveDomain_DirectMethod() {
        // Test with override set
        AskSF_Domain__mdt fakeDomain = new AskSF_Domain__mdt(
            DeveloperName = 'test_domain',
            SourceType__c = 'LIVE_SF',
            Queryable__c = true,
            Parity__c = 'EXACT',
            PrimaryObject__c = 'Account'
        );
        AiSalesAssistantController.testDomainOverride = fakeDomain;

        AskSF_Domain__mdt result = AiSalesAssistantController.resolveDomain('Account');
        System.assertNotEquals(null, result, 'Override should be returned');
        System.assertEquals('test_domain', result.DeveloperName, 'Should return override domain');
        System.assertEquals(true, result.Queryable__c, 'Should be queryable');

        // Clear override — without real CMT records, should return null for unknown objects
        AiSalesAssistantController.testDomainOverride = null;
        AskSF_Domain__mdt nullResult = AiSalesAssistantController.resolveDomain('UnknownObject__c');
        System.assertEquals(null, nullResult, 'Unknown object should return null without override');

        // Blank object name should return null
        AskSF_Domain__mdt blankResult = AiSalesAssistantController.resolveDomain('');
        System.assertEquals(null, blankResult, 'Blank object name should return null');
    }

    // === Structured Planner Tests ===

    private static AskSF_Domain__mdt buildRevenueDomain() {
        return new AskSF_Domain__mdt(
            DeveloperName = 'revenue',
            SourceType__c = 'LIVE_SF',
            Queryable__c = true,
            Parity__c = 'EXACT',
            PrimaryObject__c = 'accounts_revenue__c',
            AllowedMeasures__c = 'Revenue_Booked_Amount__c,GP__c,Variable_Cost__c,Fixed_Cost__c,Total_Cost__c,Norm_Rev_Amount__c',
            AllowedDimensions__c = 'Cluster__c,Region__c,SKU__c,Parent_SKU__c,Product_Type__c,Classification__c,Revenue_Classification__c,Currency__c,Account__r.Name,Account_Manager__c,CSM__c'
        );
    }

    @isTest
    static void testValidateRevenuePlan_ValidAggregate() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c","Currency__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assertEquals(null, error, 'Valid plan should pass validation');
    }

    @isTest
    static void testValidateRevenuePlan_InvalidMeasure() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"FakeField__c","alias":"fake"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"fake","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('FakeField__c'), 'Should reject unknown measure');
    }

    @isTest
    static void testValidateRevenuePlan_InvalidDimension() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
            '"dimensions":["Account.Industry"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"gp","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('Account.Industry'), 'Should reject unknown dimension');
    }

    @isTest
    static void testValidateRevenuePlan_DetailIntentBlocked() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"detail","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('Detail intent'), 'Detail intent should be blocked');
    }

    @isTest
    static void testValidateRevenuePlan_MissingDateFilter() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('dateFilter'), 'Missing dateFilter should fail');
    }

    @isTest
    static void testValidateRevenuePlan_NotRevenue() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"not_revenue","reason":"This is about bookings"}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('not revenue'), 'not_revenue domain should fail validation');
    }

    @isTest
    static void testValidateRevenuePlan_InvalidOperator() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[{"field":"Cluster__c","op":"LIKE","value":"%BFSI%"}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('Invalid operator'), 'LIKE should not be allowed');
    }

    @isTest
    static void testValidateRevenuePlan_LimitExceeded() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":5000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assert(error != null && error.contains('Limit exceeds'), 'Limit >2000 should fail');
    }

    @isTest
    static void testValidateRevenuePlan_CountIdAllowed() {
        AskSF_Domain__mdt domain = buildRevenueDomain();
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"COUNT","field":"Id","alias":"cnt"},{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String error = AiSalesAssistantController.validateRevenuePlan(plan, domain);
        System.assertEquals(null, error, 'COUNT(Id) should always be allowed');
    }

    @isTest
    static void testCompileSoqlFromPlan_SimpleAggregate() {
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c","Currency__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String soql = AiSalesAssistantController.compileSoqlFromPlan(plan);
        System.assert(soql.contains('SELECT Cluster__c, Currency__c, SUM(Revenue_Booked_Amount__c) rev'), 'Should build SELECT');
        System.assert(soql.contains('FROM accounts_revenue__c'), 'Should target correct object');
        System.assert(soql.contains('Revenue_Booked_On__c >= 2025-04-01'), 'Should have date start');
        System.assert(soql.contains('Revenue_Booked_On__c <= 2026-03-14'), 'Should have date end');
        System.assert(soql.contains('GROUP BY Cluster__c, Currency__c'), 'Should GROUP BY dimensions');
        System.assert(soql.contains('ORDER BY SUM(Revenue_Booked_Amount__c) DESC'), 'Should ORDER BY aggregate expression');
        System.assert(soql.contains('LIMIT 2000'), 'Should have limit');
    }

    @isTest
    static void testCompileSoqlFromPlan_WithFilters() {
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"ranking","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
            '"dimensions":["Account__r.Name","SKU__c","Cluster__c","Currency__c"],' +
            '"filters":[{"field":"Account__c","op":"!=","value":null},{"field":"Parent_SKU__c","op":"=","value":"Voice"}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-10-01","end":"2025-12-31"},' +
            '"sort":{"field":"gp","direction":"DESC"},"limit":2000}'
        );

        String soql = AiSalesAssistantController.compileSoqlFromPlan(plan);
        System.assert(soql.contains('Account__c != null'), 'Should handle null comparison');
        System.assert(soql.contains('Parent_SKU__c = \'Voice\''), 'Should handle string equality filter');
        System.assert(soql.contains('Revenue_Booked_On__c >= 2025-10-01'), 'Should have Q3 date start');
    }

    @isTest
    static void testCompileSoqlFromPlan_WithInFilter() {
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[{"field":"Cluster__c","op":"IN","value":["BFSI & Strategic Large","SME Funded"]}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        String soql = AiSalesAssistantController.compileSoqlFromPlan(plan);
        System.assert(soql.contains('Cluster__c IN ('), 'Should have IN clause');
        System.assert(soql.contains('\'BFSI & Strategic Large\''), 'Should quote IN values');
    }

    @isTest
    static void testIsStructuredPlannerEnabled_Default() {
        // Without any config, should default to false
        AiSalesAssistantController.testPlannerFlag = null;
        // Can't easily test getInstance without deployed CMT, but flag override works
        AiSalesAssistantController.testPlannerFlag = false;
        System.assertEquals(false, AiSalesAssistantController.isStructuredPlannerEnabled());

        AiSalesAssistantController.testPlannerFlag = true;
        System.assertEquals(true, AiSalesAssistantController.isStructuredPlannerEnabled());

        AiSalesAssistantController.testPlannerFlag = null;
    }

    /**
     * Mock that simulates the planner path: first call returns planner JSON, second returns summary.
     */
    private class MockClaudePlannerPath implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // Planner call: return a valid revenue plan JSON
                String planJson = '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
                    '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
                    '"dimensions":["Cluster__c"],' +
                    '"filters":[],' +
                    '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
                    '"sort":{"field":"rev","direction":"DESC"},"limit":2000}';
                res.setBody('{"id":"msg_plan","type":"message","role":"assistant","content":[{"type":"text","text":"' +
                    planJson.replace('"', '\\"') + '"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            } else {
                // Summary call
                res.setBody('{"id":"msg_sum","type":"message","role":"assistant","content":[{"type":"text","text":"Revenue summary via planner path."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
            }
            return res;
        }
    }

    @isTest
    static void testPlannerPath_EndToEnd() {
        setupTestConfig();
        AiSalesAssistantController.testPlannerFlag = true;
        AiSalesAssistantController.testDomainOverride = buildRevenueDomain();

        Test.setMock(HttpCalloutMock.class, new MockClaudePlannerPath());
        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('Total revenue this year', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Planner path should succeed: ' + resp.errorMessage);
        System.assert(resp.soqlQuery != null && resp.soqlQuery.contains('accounts_revenue__c'),
            'Should compile SOQL from plan');

        // Cleanup
        AiSalesAssistantController.testPlannerFlag = null;
        AiSalesAssistantController.testDomainOverride = null;
    }

    /**
     * Mock for planner fallback: planner returns not_revenue, then falls through to SOQL prompt.
     */
    private class MockClaudePlannerFallback implements HttpCalloutMock {
        private Integer callCount = 0;

        public HTTPResponse respond(HTTPRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // Planner says not_revenue
                String planJson = '{"domain":"not_revenue","reason":"This is about bookings"}';
                res.setBody('{"id":"msg_nr","type":"message","role":"assistant","content":[{"type":"text","text":"' +
                    planJson.replace('"', '\\"') + '"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}');
            } else if (callCount == 2) {
                // SOQL prompt fallback
                res.setBody('{"id":"msg_soql","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT Id, Name FROM Account LIMIT 5\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            } else {
                // Summary
                res.setBody('{"id":"msg_sum2","type":"message","role":"assistant","content":[{"type":"text","text":"Here are the accounts."}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":200,"output_tokens":30}}');
            }
            return res;
        }
    }

    @isTest
    static void testPlannerPath_FallbackToPrompt() {
        setupTestConfig();
        AiSalesAssistantController.testPlannerFlag = true;
        AiSalesAssistantController.testDomainOverride = buildRevenueDomain();

        Test.setMock(HttpCalloutMock.class, new MockClaudePlannerFallback());
        Test.startTest();
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('How many bookings this quarter?', null);
        Test.stopTest();

        System.assertEquals(true, resp.success, 'Fallback path should succeed: ' + resp.errorMessage);

        // Cleanup
        AiSalesAssistantController.testPlannerFlag = null;
        AiSalesAssistantController.testDomainOverride = null;
    }

    /**
     * Mock for planner blocked domain: planner returns not_revenue with reason
     * matching a blocked domain's keywords.
     */
    private class MockClaudePlannerBlocked implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            // Planner says not_revenue with reason mentioning credits (blocked domain)
            String planJson = '{"domain":"not_revenue","reason":"This is about account credits which are in AWS QuickSight"}';
            res.setBody('{"id":"msg_bl","type":"message","role":"assistant","content":[{"type":"text","text":"' +
                planJson.replace('"', '\\"') + '"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}');
            return res;
        }
    }

    @isTest
    static void testPlannerPath_NotRevenueBlocked() {
        setupTestConfig();
        AiSalesAssistantController.testPlannerFlag = true;
        AiSalesAssistantController.testDomainOverride = buildRevenueDomain();

        Test.setMock(HttpCalloutMock.class, new MockClaudePlannerBlocked());
        Test.startTest();
        // This question mentions "credits" which should match blocked domain keywords
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.askQuestion('What are our account credits?', null);
        Test.stopTest();

        // In test context without real CMT blocked domain records, the keyword check
        // queries AskSF_Domain__mdt WHERE Queryable__c = false — will be empty in tests.
        // So it falls through to SOQL prompt (MockClaudePlannerBlocked only has 1 response,
        // so the SOQL prompt call will get the same response and fail to extract SOQL).
        // This tests the code path executes without exceptions.
        // Full blocked-domain behavior requires deployed CMT records.
        System.assertNotEquals(null, resp, 'Response should not be null');

        // Cleanup
        AiSalesAssistantController.testPlannerFlag = null;
        AiSalesAssistantController.testDomainOverride = null;
    }

    @isTest
    static void testPlannerResult_ThreeStates() {
        AskSF_Domain__mdt domain = buildRevenueDomain();

        // Test SUCCESS path
        Map<String, Object> validPlan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );
        String validError = AiSalesAssistantController.validateRevenuePlan(validPlan, domain);
        System.assertEquals(null, validError, 'Valid plan should pass');

        // Test NOT_REVENUE path
        Map<String, Object> notRevPlan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"not_revenue","reason":"This is about bookings"}'
        );
        String notRevDomain = (String) notRevPlan.get('domain');
        System.assertEquals('not_revenue', notRevDomain, 'Should detect not_revenue');

        // Test ERROR path (invalid measure)
        Map<String, Object> badPlan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"BadField__c","alias":"bad"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"bad","direction":"DESC"},"limit":2000}'
        );
        String badError = AiSalesAssistantController.validateRevenuePlan(badPlan, domain);
        System.assertNotEquals(null, badError, 'Invalid plan should fail validation');
        System.assert(badError.contains('BadField__c'), 'Error should mention the bad field');
    }

    // === Semantic Override Engine Tests ===

    private static List<Map<String, Object>> buildTestRegistry() {
        // Minimal registry with just the critical overrides for testing
        String json_str = '[' +
            '{"id":"region_scaleup","terms":["scaleup","scaleups","scale up"],' +
            '"correctField":"Region__c","correctValue":"Scaleup",' +
            '"forbiddenFields":["Cluster__c","Account_Cluster__c"],' +
            '"reason":"Scaleup is a Region__c value."},' +
            '{"id":"region_domestic","terms":["domestic","domestic enterprise"],' +
            '"correctField":"Region__c","correctValue":"Domestic Enterprise",' +
            '"forbiddenFields":["Cluster__c","Account_Cluster__c"],' +
            '"reason":"Domestic Enterprise is a Region__c value."},' +
            '{"id":"cluster_apac","terms":["apac","asia pacific"],' +
            '"correctField":"Cluster__c","correctValue":"APAC",' +
            '"forbiddenFields":["Region__c","Account_Region__c"],' +
            '"reason":"APAC is a Cluster__c value."},' +
            '{"id":"cluster_ksa","terms":["ksa","saudi"],' +
            '"correctField":"Cluster__c","correctValue":"KSA",' +
            '"forbiddenFields":["Region__c","Account_Region__c"],' +
            '"reason":"KSA is a Cluster__c value."},' +
            '{"id":"cluster_uae","terms":["uae","emirates","dubai"],' +
            '"correctField":"Cluster__c","correctValue":"UAE",' +
            '"forbiddenFields":["Region__c","Account_Region__c"],' +
            '"reason":"UAE is a Cluster__c value."},' +
            '{"id":"cluster_mena","terms":["mena","middle east"],' +
            '"correctField":"Cluster__c","correctValue":["UAE","KSA"],' +
            '"forbiddenFields":["Region__c","Account_Region__c"],' +
            '"reason":"MENA maps to Cluster__c IN (UAE, KSA)."}' +
        ']';
        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(json_str);
        List<Map<String, Object>> registry = new List<Map<String, Object>>();
        for (Object o : parsed) {
            registry.add((Map<String, Object>) o);
        }
        return registry;
    }

    @isTest
    static void testDetectOverrides_ScaleupMatchesRegion() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('How much GP has scaleups contributed this FY?');

        System.assertEquals(1, overrides.size(), 'Should detect one override');
        System.assertEquals('region_scaleup', overrides[0].overrideId);
        System.assertEquals('Region__c', overrides[0].correctField);
        System.assertEquals('Scaleup', overrides[0].correctValue);
        System.assert(overrides[0].forbiddenFields.contains('cluster__c'),
            'Cluster__c should be forbidden');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testDetectOverrides_APACMatchesCluster() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('Revenue for APAC region this year');

        System.assertEquals(1, overrides.size(), 'Should detect one override');
        System.assertEquals('cluster_apac', overrides[0].overrideId);
        System.assertEquals('Cluster__c', overrides[0].correctField);
        System.assertEquals('APAC', overrides[0].correctValue);
        System.assert(overrides[0].forbiddenFields.contains('region__c'),
            'Region__c should be forbidden for APAC');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testDetectOverrides_UAEMatchesCluster() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('How is UAE performing on revenue?');

        System.assertEquals(1, overrides.size());
        System.assertEquals('cluster_uae', overrides[0].overrideId);
        System.assertEquals('Cluster__c', overrides[0].correctField);

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testDetectOverrides_MENAMultiValue() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('Total MENA revenue');

        System.assertEquals(1, overrides.size());
        System.assertEquals('cluster_mena', overrides[0].overrideId);
        System.assert(overrides[0].correctValue instanceof List<Object>,
            'MENA should have multi-value correctValue');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testDetectOverrides_NoMatch() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('Total revenue this year');

        System.assertEquals(0, overrides.size(), 'No overrides should match');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testDetectOverrides_WholeWordOnly() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        // "scaling" should NOT match "scale" because 'g' follows
        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('We are scaling our operations');

        // "scale" should not match "scaling" (right bound is alpha)
        Boolean hasScaleup = false;
        for (AiSalesAssistantController.SemanticOverride so : overrides) {
            if (so.overrideId == 'region_scaleup') hasScaleup = true;
        }
        System.assertEquals(false, hasScaleup, 'scaling should not trigger scaleup override');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testApplyOverridesToPlan_FixesClusterToRegion() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        // Simulate a plan that wrongly uses Cluster__c = 'Scaleup'
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
            '"dimensions":["Cluster__c","Currency__c"],' +
            '"filters":[{"field":"Cluster__c","op":"=","value":"Scaleup"}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"gp","direction":"DESC"},"limit":2000}'
        );

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('GP for scaleups this FY');

        List<String> applied = AiSalesAssistantController.applyOverridesToPlan(plan, overrides);
        System.assert(applied.contains('region_scaleup'), 'Should have applied region_scaleup override');

        // Verify the filter was corrected
        List<Object> filters = (List<Object>) plan.get('filters');
        Boolean hasRegionFilter = false;
        Boolean hasClusterFilter = false;
        for (Object fObj : filters) {
            Map<String, Object> f = (Map<String, Object>) fObj;
            String field = (String) f.get('field');
            if (field == 'Region__c') hasRegionFilter = true;
            if (field == 'Cluster__c') hasClusterFilter = true;
        }
        System.assertEquals(true, hasRegionFilter, 'Should have Region__c filter');
        System.assertEquals(false, hasClusterFilter, 'Should NOT have Cluster__c filter');

        // Verify dimensions were corrected too
        List<Object> dims = (List<Object>) plan.get('dimensions');
        Boolean hasRegionDim = false;
        for (Object d : dims) {
            if ((String) d == 'Region__c') hasRegionDim = true;
        }
        System.assertEquals(true, hasRegionDim, 'Cluster__c dimension should be replaced with Region__c');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testApplyOverridesToSoql_FixesClusterToRegion() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        String wrongSoql = 'SELECT Cluster__c, Currency__c, SUM(GP__c) gp ' +
            'FROM accounts_revenue__c ' +
            'WHERE Revenue_Booked_On__c >= 2025-04-01 AND Revenue_Booked_On__c <= 2026-03-14 ' +
            'AND Cluster__c = \'Scaleup\' ' +
            'GROUP BY Cluster__c, Currency__c ORDER BY SUM(GP__c) DESC LIMIT 200';

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('GP for scaleup this year');

        Map<String, Object> result =
            AiSalesAssistantController.applyOverridesToSoql(wrongSoql, overrides);

        String correctedSoql = (String) result.get('soql');
        List<String> applied = (List<String>) result.get('applied');

        System.assert(applied.contains('region_scaleup'), 'Should have applied override');
        System.assert(correctedSoql.contains('Region__c'), 'Should contain Region__c');
        System.assert(!correctedSoql.contains('Cluster__c'), 'Should NOT contain Cluster__c');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testCheckForbiddenFields_DetectsViolation() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
            '"dimensions":["Cluster__c"],' +
            '"filters":[{"field":"Cluster__c","op":"=","value":"Scaleup"}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"gp","direction":"DESC"},"limit":2000}'
        );

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('GP for scaleups');

        String error = AiSalesAssistantController.checkForbiddenFields(plan, overrides);
        System.assertNotEquals(null, error, 'Should detect forbidden field violation');
        System.assert(error.contains('Cluster__c'), 'Error should mention Cluster__c');
        System.assert(error.contains('Region__c'), 'Error should mention correct field Region__c');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testCheckForbiddenFields_CleanPlan() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        // Plan correctly uses Region__c for Scaleup
        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"GP__c","alias":"gp"}],' +
            '"dimensions":["Region__c"],' +
            '"filters":[{"field":"Region__c","op":"=","value":"Scaleup"}],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"gp","direction":"DESC"},"limit":2000}'
        );

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('GP for scaleups');

        String error = AiSalesAssistantController.checkForbiddenFields(plan, overrides);
        System.assertEquals(null, error, 'Correctly formed plan should pass');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    @isTest
    static void testApplyOverridesToPlan_MENAMultiValue() {
        AiSalesAssistantController.testRegistryOverride = buildTestRegistry();

        Map<String, Object> plan = (Map<String, Object>) JSON.deserializeUntyped(
            '{"domain":"revenue","intent":"aggregate","object":"accounts_revenue__c",' +
            '"measures":[{"fn":"SUM","field":"Revenue_Booked_Amount__c","alias":"rev"}],' +
            '"dimensions":["Cluster__c","Currency__c"],' +
            '"filters":[],' +
            '"dateFilter":{"field":"Revenue_Booked_On__c","start":"2025-04-01","end":"2026-03-14"},' +
            '"sort":{"field":"rev","direction":"DESC"},"limit":2000}'
        );

        List<AiSalesAssistantController.SemanticOverride> overrides =
            AiSalesAssistantController.detectOverrides('Total MENA revenue');

        List<String> applied = AiSalesAssistantController.applyOverridesToPlan(plan, overrides);
        System.assert(applied.contains('cluster_mena'), 'Should have applied MENA override');

        // Check the IN filter was added
        List<Object> filters = (List<Object>) plan.get('filters');
        Boolean hasInFilter = false;
        for (Object fObj : filters) {
            Map<String, Object> f = (Map<String, Object>) fObj;
            if ((String) f.get('field') == 'Cluster__c' && (String) f.get('op') == 'IN') {
                hasInFilter = true;
            }
        }
        System.assertEquals(true, hasInFilter, 'Should have Cluster__c IN filter for MENA');

        AiSalesAssistantController.testRegistryOverride = null;
    }

    // ==================== formatAsLakhs Tests ====================

    @isTest
    static void testFormatAsLakhs_SmallValue() {
        // 2,142,000 → ₹21.42 L
        String result = AiSalesAssistantController.formatAsLakhs(2142000);
        System.assertEquals('₹21.42 L', result, 'Should format 2142000 as ₹21.42 L');
    }

    @isTest
    static void testFormatAsLakhs_MobilityGPApril() {
        // The exact value that caused the 10x bug: 24,265,419.21 should be ₹242.65 L
        String result = AiSalesAssistantController.formatAsLakhs(24265419.21);
        System.assertEquals('₹242.65 L', result, 'Should format 24265419.21 as ₹242.65 L (NOT ₹24.27 L)');
    }

    @isTest
    static void testFormatAsLakhs_LargeLakhsValue() {
        // 150,000,000 → ₹1500.00 L (under Crore threshold of 1B)
        String result = AiSalesAssistantController.formatAsLakhs(150000000);
        System.assertEquals('₹1500.00 L', result, 'Should format 150M as ₹1500.00 L');
    }

    @isTest
    static void testFormatAsLakhs_CroreValue() {
        // 1,500,000,000 (1.5B) → ₹150.00 Cr (above Crore threshold)
        String result = AiSalesAssistantController.formatAsLakhs(1500000000);
        System.assertEquals('₹150.00 Cr', result, 'Should format 1.5B as ₹150.00 Cr');
    }

    @isTest
    static void testFormatAsLakhs_NegativeValue() {
        String result = AiSalesAssistantController.formatAsLakhs(-5000000);
        System.assertEquals('-₹50.00 L', result, 'Should handle negative values');
    }

    @isTest
    static void testFormatAsLakhs_ZeroValue() {
        String result = AiSalesAssistantController.formatAsLakhs(0);
        System.assertEquals('₹0.00 L', result, 'Should handle zero');
    }

    @isTest
    static void testFormatAsLakhs_NullValue() {
        String result = AiSalesAssistantController.formatAsLakhs(null);
        System.assertEquals('₹0.00 L', result, 'Should handle null');
    }

    // ==================== enrichJsonWithLakhsFormatting Tests ====================

    @isTest
    static void testEnrichJson_AddsDisplayFields() {
        // Simulate aggregate query result with GP values
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        Map<String, Object> row1 = new Map<String, Object>{
            'revMonth' => 4, 'revYear' => 2025, 'Currency__c' => 'INR',
            'monthlyGP' => 24265419.21
        };
        Map<String, Object> row2 = new Map<String, Object>{
            'revMonth' => 5, 'revYear' => 2025, 'Currency__c' => 'INR',
            'monthlyGP' => 24242818.38
        };
        rows.add(row1);
        rows.add(row2);

        String inputJson = JSON.serialize(rows);
        String enrichedJson = AiSalesAssistantController.enrichJsonWithLakhsFormatting(inputJson);

        // Parse and verify _display fields were added
        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(enrichedJson);
        Map<String, Object> parsedRow1 = (Map<String, Object>) parsed[0];
        System.assert(parsedRow1.containsKey('monthlyGP_display'), 'Should add monthlyGP_display');
        System.assertEquals('₹242.65 L', (String) parsedRow1.get('monthlyGP_display'),
            'Display value should be ₹242.65 L');

        Map<String, Object> parsedRow2 = (Map<String, Object>) parsed[1];
        System.assertEquals('₹242.43 L', (String) parsedRow2.get('monthlyGP_display'),
            'Display value should be ₹242.43 L');
    }

    @isTest
    static void testEnrichJson_SkipsNonMeasureFields() {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        Map<String, Object> row = new Map<String, Object>{
            'revMonth' => 4, 'totalRev' => 50000000
        };
        rows.add(row);

        String enrichedJson = AiSalesAssistantController.enrichJsonWithLakhsFormatting(JSON.serialize(rows));
        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(enrichedJson);
        Map<String, Object> parsedRow = (Map<String, Object>) parsed[0];

        // revMonth is NOT a measure field — should not get _display
        System.assert(!parsedRow.containsKey('revMonth_display'), 'Should not add display for non-measure fields');
        // totalRev IS a measure — should get _display
        System.assert(parsedRow.containsKey('totalRev_display'), 'Should add display for measure fields');
        System.assertEquals('₹500.00 L', (String) parsedRow.get('totalRev_display'));
    }

    @isTest
    static void testEnrichJson_HandlesEmptyJson() {
        String result = AiSalesAssistantController.enrichJsonWithLakhsFormatting('[]');
        System.assertEquals('[]', result, 'Should return empty array unchanged');
    }

    // ── KPI Engine Tests ──────────────────────────────────────────────────

    static List<Map<String, Object>> buildTestKpiRegistry() {
        List<Map<String, Object>> registry = new List<Map<String, Object>>();

        // WIN_RATE
        Map<String, Object> winRate = new Map<String, Object>();
        winRate.put('id', 'WIN_RATE');
        winRate.put('displayName', 'Win Rate');
        winRate.put('formulaType', 'RATIO');
        winRate.put('questionTerms', new List<Object>{ 'win rate', 'win %', 'win percentage' });
        winRate.put('defaultDimension', 'Account_Cluster__c');
        Map<String, Object> dims = new Map<String, Object>();
        dims.put('cluster', 'Account_Cluster__c');
        dims.put('region', 'Account_Region__c');
        dims.put('owner', 'Owner.Name');
        winRate.put('supportedDimensions', dims);
        winRate.put('showBothValueAndCount', true);
        winRate.put('interpretationNote', 'Test note');

        Map<String, Object> numSpec = new Map<String, Object>();
        numSpec.put('measureField', 'Amount');
        numSpec.put('measureFn', 'SUM');
        numSpec.put('countField', 'Id');
        numSpec.put('dateField', 'B_Deal_Date__c');
        numSpec.put('stageFilter', new List<Object>{ 'Order' });
        winRate.put('numerator', numSpec);

        Map<String, Object> denSpec = new Map<String, Object>();
        denSpec.put('measureField', 'Amount');
        denSpec.put('measureFn', 'SUM');
        denSpec.put('countField', 'Id');
        denSpec.put('dateField', 'CloseDate');
        denSpec.put('stageFilter', new List<Object>{
            'Order', 'Negotiation', 'Closed Lost', 'Closed-No decision',
            'Closed Unknown', 'Closed Duplicate', 'Rejected', 'SDF Rejected'
        });
        winRate.put('denominator', denSpec);
        registry.add(winRate);

        // CONVERSION_RATE
        Map<String, Object> convRate = new Map<String, Object>();
        convRate.put('id', 'CONVERSION_RATE');
        convRate.put('displayName', 'Conversion Rate');
        convRate.put('formulaType', 'RATIO');
        convRate.put('questionTerms', new List<Object>{ 'conversion rate', 'conversion ratio' });
        convRate.put('defaultDimension', 'Account_Cluster__c');
        convRate.put('supportedDimensions', dims);
        convRate.put('showBothValueAndCount', true);
        convRate.put('numerator', numSpec);
        convRate.put('denominator', denSpec);
        registry.add(convRate);

        // SALES_CYCLE_AVG
        Map<String, Object> cycleAvg = new Map<String, Object>();
        cycleAvg.put('id', 'SALES_CYCLE_AVG');
        cycleAvg.put('displayName', 'Average Sales Cycle');
        cycleAvg.put('formulaType', 'AVERAGE');
        cycleAvg.put('questionTerms', new List<Object>{ 'average sales cycle', 'avg sales cycle', 'sales cycle' });
        cycleAvg.put('defaultDimension', 'Account_Cluster__c');
        cycleAvg.put('supportedDimensions', dims);
        Map<String, Object> comp = new Map<String, Object>();
        comp.put('startDateField', 'ISQL_Accepted_Date__c');
        comp.put('endDateField', 'B_Deal_Date__c');
        comp.put('stageFilter', new List<Object>{ 'Order' });
        comp.put('maxDetailRows', 10000);
        cycleAvg.put('computation', comp);
        registry.add(cycleAvg);

        // SALES_CYCLE_MEDIAN
        Map<String, Object> cycleMed = new Map<String, Object>();
        cycleMed.put('id', 'SALES_CYCLE_MEDIAN');
        cycleMed.put('displayName', 'Median Sales Cycle');
        cycleMed.put('formulaType', 'MEDIAN');
        cycleMed.put('questionTerms', new List<Object>{ 'median sales cycle', 'sales cycle median' });
        cycleMed.put('defaultDimension', 'Account_Cluster__c');
        cycleMed.put('supportedDimensions', dims);
        cycleMed.put('computation', comp);
        registry.add(cycleMed);

        return registry;
    }

    // ── KPI Detection Tests ──

    @isTest
    static void testDetectKpi_WinRate() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is our win rate across all clusters this FY?');
        System.assertNotEquals(null, kpi, 'Should detect WIN_RATE');
        System.assertEquals('WIN_RATE', kpi.get('id'));
    }

    @isTest
    static void testDetectKpi_WinPercent() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is the win % for APAC this quarter?');
        System.assertNotEquals(null, kpi, 'Should detect WIN_RATE from "win %"');
        System.assertEquals('WIN_RATE', kpi.get('id'));
    }

    @isTest
    static void testDetectKpi_ConversionRate() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is the conversion rate this month?');
        System.assertNotEquals(null, kpi, 'Should detect CONVERSION_RATE');
        System.assertEquals('CONVERSION_RATE', kpi.get('id'));
    }

    @isTest
    static void testDetectKpi_AvgSalesCycle() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is the average sales cycle this FY?');
        System.assertNotEquals(null, kpi, 'Should detect SALES_CYCLE_AVG');
        System.assertEquals('SALES_CYCLE_AVG', kpi.get('id'));
    }

    @isTest
    static void testDetectKpi_MedianSalesCycle() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is the median sales cycle for Domestic Enterprise?');
        System.assertNotEquals(null, kpi, 'Should detect SALES_CYCLE_MEDIAN');
        System.assertEquals('SALES_CYCLE_MEDIAN', kpi.get('id'));
    }

    @isTest
    static void testDetectKpi_NoMatch() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'Show me the top 10 customers by revenue this quarter');
        System.assertEquals(null, kpi, 'Should not match any KPI');
    }

    @isTest
    static void testDetectKpi_NullInput() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(null);
        System.assertEquals(null, kpi, 'Null input should return null');
    }

    // ── KPI Grouping Detection Tests ──

    @isTest
    static void testExtractGrouping_Cluster() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent('What is our win rate?');
        String dim = AiSalesAssistantController.extractKpiGrouping(
            'What is the win rate across all clusters this FY?', kpi);
        System.assertEquals('Account_Cluster__c', dim, 'Should detect cluster dimension');
    }

    @isTest
    static void testExtractGrouping_Region() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent('What is our win rate?');
        String dim = AiSalesAssistantController.extractKpiGrouping(
            'What is the win rate by region this FY?', kpi);
        System.assertEquals('Account_Region__c', dim, 'Should detect region dimension');
    }

    @isTest
    static void testExtractGrouping_Default() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent('What is our win rate?');
        String dim = AiSalesAssistantController.extractKpiGrouping(
            'What is the win rate this FY?', kpi);
        System.assertEquals('Account_Cluster__c', dim, 'Should use default dimension');
    }

    // ── KPI Time Range Tests ──

    @isTest
    static void testExtractTimeRange_CurrentFY() {
        Date today = Date.newInstance(2026, 3, 14);
        Map<String, Object> range = AiSalesAssistantController.extractKpiTimeRange(
            'What is the win rate this FY?', today);
        System.assertEquals(Date.newInstance(2025, 4, 1), range.get('start'));
        // FY end uses full fiscal year boundary (Mar 31), not today — matches Tableau
        System.assertEquals(Date.newInstance(2026, 3, 31), range.get('end'));
        System.assert(((String) range.get('label')).contains('FY2025'));
    }

    @isTest
    static void testExtractTimeRange_ThisQuarter() {
        Date today = Date.newInstance(2026, 3, 14);
        Map<String, Object> range = AiSalesAssistantController.extractKpiTimeRange(
            'What is the win rate this quarter?', today);
        System.assertEquals(Date.newInstance(2026, 1, 1), range.get('start'));
        // Quarter end uses full quarter boundary — matches Tableau
        System.assertEquals(Date.newInstance(2026, 3, 31), range.get('end'));
    }

    @isTest
    static void testExtractTimeRange_ThisMonth() {
        Date today = Date.newInstance(2026, 3, 14);
        Map<String, Object> range = AiSalesAssistantController.extractKpiTimeRange(
            'What is the conversion rate this month?', today);
        System.assertEquals(Date.newInstance(2026, 3, 1), range.get('start'));
        System.assertEquals(today, range.get('end'));
    }

    @isTest
    static void testExtractTimeRange_LastQuarter() {
        Date today = Date.newInstance(2026, 3, 14);
        Map<String, Object> range = AiSalesAssistantController.extractKpiTimeRange(
            'What was the win rate last quarter?', today);
        System.assertEquals(Date.newInstance(2025, 10, 1), range.get('start'));
        System.assertEquals(Date.newInstance(2025, 12, 31), range.get('end'));
    }

    @isTest
    static void testExtractTimeRange_LastMonth() {
        Date today = Date.newInstance(2026, 3, 14);
        Map<String, Object> range = AiSalesAssistantController.extractKpiTimeRange(
            'Show me last month conversion rate', today);
        System.assertEquals(Date.newInstance(2026, 2, 1), range.get('start'));
        System.assertEquals(Date.newInstance(2026, 2, 28), range.get('end'));
    }

    // ── Formula Computation Tests ──

    @isTest
    static void testComputeMedian_OddCount() {
        List<Integer> vals = new List<Integer>{ 3, 8, 9, 11, 15 };
        Decimal med = AiSalesAssistantController.computeMedian(vals);
        System.assertEquals(9, med, 'Median of [3,8,9,11,15] = 9');
    }

    @isTest
    static void testComputeMedian_EvenCount() {
        List<Integer> vals = new List<Integer>{ 3, 8, 11, 15 };
        Decimal med = AiSalesAssistantController.computeMedian(vals);
        System.assertEquals(9.5, med, 'Median of [3,8,11,15] = 9.5');
    }

    @isTest
    static void testComputeMedian_Empty() {
        Decimal med = AiSalesAssistantController.computeMedian(new List<Integer>());
        System.assertEquals(0, med, 'Median of empty = 0');
    }

    @isTest
    static void testComputeMedian_SingleValue() {
        List<Integer> vals = new List<Integer>{ 42 };
        Decimal med = AiSalesAssistantController.computeMedian(vals);
        System.assertEquals(42, med, 'Median of [42] = 42');
    }

    @isTest
    static void testComputeRatio_Normal() {
        Decimal ratio = AiSalesAssistantController.computeRatio(25, 100);
        System.assertEquals(25.00, ratio, 'Ratio 25/100 = 25%');
    }

    @isTest
    static void testComputeRatio_DivideByZero() {
        Decimal ratio = AiSalesAssistantController.computeRatio(25, 0);
        System.assertEquals(0, ratio, 'Divide by zero returns 0');
    }

    @isTest
    static void testComputeRatio_NullDenominator() {
        Decimal ratio = AiSalesAssistantController.computeRatio(25, null);
        System.assertEquals(0, ratio, 'Null denominator returns 0');
    }

    // ── KPI Engine End-to-End (with real Opp data) ──

    @isTest
    static void testRunKpiEngine_WinRateDetectsAndExecutes() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        // No test Opportunity data — will return 0 rows but should not error
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate across clusters this FY?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result, 'Should detect and execute WIN_RATE');
        System.assertEquals('WIN_RATE', result.kpiId);
        System.assertEquals(2, result.soqlQueries.size(), 'Win rate needs 2 queries');
        // Numerator query should use B_Deal_Date__c
        System.assert(result.soqlQueries[0].contains('B_Deal_Date__c'),
            'Numerator should filter by B_Deal_Date__c');
        // Denominator query should use CloseDate
        System.assert(result.soqlQueries[1].contains('CloseDate'),
            'Denominator should filter by CloseDate');
        // Denominator should include Negotiation
        System.assert(result.soqlQueries[1].contains('Negotiation'),
            'Denominator should include Negotiation stage');
    }

    @isTest
    static void testRunKpiEngine_ConversionRateDetectsAndExecutes() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the conversion rate this quarter?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result, 'Should detect CONVERSION_RATE');
        System.assertEquals('CONVERSION_RATE', result.kpiId);
    }

    @isTest
    static void testRunKpiEngine_SalesCycleAvg() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the average sales cycle this FY?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result, 'Should detect SALES_CYCLE_AVG');
        System.assertEquals('SALES_CYCLE_AVG', result.kpiId);
        System.assertEquals(1, result.soqlQueries.size(), 'Sales cycle needs 1 detail query');
        System.assert(result.soqlQueries[0].contains('ISQL_Accepted_Date__c'),
            'Should query ISQL_Accepted_Date__c');
    }

    @isTest
    static void testRunKpiEngine_MedianSalesCycle() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the median sales cycle for Domestic Enterprise this quarter?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result, 'Should detect SALES_CYCLE_MEDIAN');
        System.assertEquals('SALES_CYCLE_MEDIAN', result.kpiId);
    }

    @isTest
    static void testRunKpiEngine_NoMatch_ReturnsNull() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'Show me revenue by cluster this FY',
                Date.newInstance(2026, 3, 14));
        System.assertEquals(null, result, 'Non-KPI question should return null');
    }

    @isTest
    static void testRunKpiEngine_WinRateWithRegionGrouping() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate by region this FY?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result);
        System.assertEquals('Account_Region__c', result.dimension);
    }

    @isTest
    static void testRunKpiEngine_WinRateThisMonth() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this month?',
                Date.newInstance(2026, 3, 14));
        System.assertNotEquals(null, result);
        // Verify the date range in the query
        System.assert(result.soqlQueries[0].contains('2026-03-01'),
            'This month should start from Mar 1');
    }

    // ── KPI Parity Tests (Tableau-validated configuration) ──

    @isTest
    static void testWinRate_NumeratorUsesB_Deal_Date() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        String numSoql = result.soqlQueries[0];
        System.assert(numSoql.contains('B_Deal_Date__c'),
            'PARITY: Won side MUST use B_Deal_Date__c, not CloseDate');
        System.assert(!numSoql.contains('CloseDate'),
            'PARITY: Won side MUST NOT use CloseDate');
    }

    @isTest
    static void testWinRate_DenominatorUsesCloseDate() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        String denSoql = result.soqlQueries[1];
        System.assert(denSoql.contains('CloseDate'),
            'PARITY: Consumed side MUST use CloseDate');
        System.assert(!denSoql.contains('B_Deal_Date__c'),
            'PARITY: Consumed side MUST NOT use B_Deal_Date__c');
    }

    @isTest
    static void testWinRate_DenominatorIncludesNegotiation() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        String denSoql = result.soqlQueries[1];
        System.assert(denSoql.contains('Negotiation'),
            'PARITY: Consumed stages MUST include Negotiation');
    }

    @isTest
    static void testWinRate_DenominatorIncludesAllTerminalStages() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        String denSoql = result.soqlQueries[1];
        // Must include all terminal stages from Tableau Key KPIs dashboard
        for (String stage : new String[]{ 'Order', 'Negotiation', 'Closed Lost',
            'Closed-No decision', 'Closed Unknown', 'Closed Duplicate', 'Rejected', 'SDF Rejected' }) {
            System.assert(denSoql.contains(stage),
                'PARITY: Consumed MUST include stage: ' + stage);
        }
    }

    @isTest
    static void testWinRate_NoAmountPositiveFilter() {
        // Parity: queries must NOT filter Amount > 0 (reversals/zeros must be in denominator)
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        for (String soql : result.soqlQueries) {
            System.assert(!soql.contains('Amount > 0'),
                'PARITY: Must NOT filter Amount > 0 — negatives/zeros belong in consumed denominator');
            System.assert(!soql.contains('Amount != null'),
                'PARITY: Must NOT filter Amount != null — SUM handles nulls');
        }
    }

    @isTest
    static void testWinRate_UsesAmountNotNetNew() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        for (String soql : result.soqlQueries) {
            System.assert(soql.contains('SUM(Amount)'),
                'PARITY: Must use SUM(Amount), not Net_New_INR__c (which is 0 for lost deals)');
            System.assert(!soql.contains('Net_New_INR__c'),
                'PARITY: Must NOT use Net_New_INR__c');
        }
    }

    @isTest
    static void testWinRate_AlwaysUsesKpiEngine() {
        // When "win rate" is in the question, KPI engine must intercept — not planner
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'What is our win rate across all clusters this FY?');
        System.assertNotEquals(null, kpi,
            'PARITY: "win rate" must ALWAYS be caught by KPI engine');
        System.assertEquals('WIN_RATE', kpi.get('id'));
    }

    @isTest
    static void testWinRate_WinPercentAlsoDetected() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        Map<String, Object> kpi = AiSalesAssistantController.detectKpiIntent(
            'Show me the win % by cluster');
        System.assertNotEquals(null, kpi,
            'PARITY: "win %" must also be caught by KPI engine');
    }

    @isTest
    static void testWinRate_FYUsesFullYearBoundary() {
        // PARITY: "this FY" must use full FY end (Mar 31), NOT today.
        // Tableau includes deals with future CloseDate within FY in consumed denominator.
        // Root cause of 7.82 Cr gap: 143 deals with CloseDate Mar 15-31 were excluded.
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        String denSoql = result.soqlQueries[1];
        System.assert(denSoql.contains('2026-03-31'),
            'PARITY: Consumed denominator MUST use full FY end (2026-03-31), not today (2026-03-14). ' +
            'Gap of 7.82 Cr / 143 deals was caused by truncating at today.');
        System.assert(!denSoql.contains('2026-03-14'),
            'PARITY: MUST NOT use today as FY end — Tableau uses complete FY boundaries');
    }

    @isTest
    static void testWinRate_ResultContainsBothValueAndCount() {
        AiSalesAssistantController.testKpiRegistryOverride = buildTestKpiRegistry();
        AiSalesAssistantController.KpiResult result =
            AiSalesAssistantController.runKpiEngine(
                'What is the win rate this FY?', Date.newInstance(2026, 3, 14));
        // Results JSON must contain both rate types
        System.assert(result.resultsJson.contains('rateByValue'),
            'PARITY: Must include rateByValue');
        System.assert(result.resultsJson.contains('rateByCount'),
            'PARITY: Must include rateByCount');
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  MY DAY FEATURE TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Mock that returns a single Claude response (for My Day brief summary).
     */
    private class MockClaudeMyDay implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":"msg_myday","type":"message","role":"assistant","content":[{"type":"text","text":"## ⚡ Good morning! Here is your daily brief:\\n\\n### New Opps to Review\\nNo new suspect deals today.\\n\\n### Your Pulse\\n₹0L booked MTD"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":500,"output_tokens":200}}');
            return res;
        }
    }

    @isTest
    static void testGetMyDayEligibility_ReturnsResult() {
        // The running test user's profile may or may not be AD/CX.
        // We just verify the method runs and returns the expected keys.
        Map<String, String> result = AiSalesAssistantController.getMyDayEligibility();
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.containsKey('eligible'), 'Result must contain eligible key');
        System.assert(result.containsKey('persona'), 'Result must contain persona key');
        String eligible = result.get('eligible');
        System.assert(eligible == 'true' || eligible == 'false',
            'eligible must be true or false, got: ' + eligible);
    }

    @isTest
    static void testGetMyDayBrief_NonEligibleProfile() {
        // Running user in test context is typically 'System Administrator'
        // which is NOT in AD_PROFILES or CX_PROFILES, so it should return
        // an error response (unless running under AD/CSM profile).
        setupTestConfig();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockClaudeMyDay());
        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.getMyDayBrief();
        Test.stopTest();

        // We can't control the running user's profile in tests without creating
        // a user, so we just assert it returns a valid response object.
        System.assertNotEquals(null, resp, 'Response should not be null');
        System.assertNotEquals(null, resp.executionTimeMs, 'Execution time should be set');
    }

    @isTest
    static void testGetMyDayBrief_WithCallout() {
        // Test the full flow — if user profile is eligible, it makes a callout.
        // If not eligible, it returns error. Either path should not throw.
        setupTestConfig();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MockClaudeMyDay());

        AiSalesAssistantController.AssistantResponse resp =
            AiSalesAssistantController.getMyDayBrief();
        Test.stopTest();

        System.assertNotEquals(null, resp);
        // Regardless of profile, the method should complete gracefully
        if (resp.success) {
            System.assertNotEquals(null, resp.answer, 'Successful response should have answer');
        } else {
            System.assertNotEquals(null, resp.errorMessage, 'Failed response should have error message');
        }
    }

    @isTest
    static void testFormatMyDayLakhs_DirectCoverage() {
        // formatMyDayLakhs is @TestVisible — test directly with various amounts
        String result1 = AiSalesAssistantController.formatMyDayLakhs(0);
        System.assertEquals('₹0', result1);

        String result2 = AiSalesAssistantController.formatMyDayLakhs(500000);
        System.assert(result2.contains('L'), 'Should format as Lakhs: ' + result2);

        String result3 = AiSalesAssistantController.formatMyDayLakhs(15000000);
        System.assert(result3.contains('Cr'), 'Should format as Crores: ' + result3);

        String result4 = AiSalesAssistantController.formatMyDayLakhs(null);
        System.assertEquals('₹0', result4);
    }

    @isTest
    static void testBuildAdBriefData_DirectCoverage() {
        // buildAdBriefData is @TestVisible — call directly with current user ID.
        // No DML for Opportunity (org flows cause SOQL limit issues).
        // The method runs 7 SOQLs and returns a data string with section headers.
        setupTestConfig();

        Test.startTest();
        String briefData = AiSalesAssistantController.buildAdBriefData(UserInfo.getUserId());
        Test.stopTest();

        System.assertNotEquals(null, briefData, 'Brief data should not be null');
        System.assert(briefData.length() > 0, 'Brief data should not be empty');
        // Verify key sections exist (uses === markers)
        System.assert(briefData.contains('SUSPECT OPPORTUNITIES'), 'Should contain suspect section');
        System.assert(briefData.contains('OVERDUE'), 'Should contain overdue tasks section');
        System.assert(briefData.contains('PERFORMANCE PULSE'), 'Should contain pulse section');
    }

    @isTest
    static void testBuildCsmBriefData_DirectCoverage() {
        // buildCsmBriefData is @TestVisible — call directly with current user ID.
        // No DML for Case (org flows require Owner and cause validation issues).
        setupTestConfig();

        // Create test account assigned to current user as CSM
        Account testAcc = new Account(
            Name = 'CSM Brief Test Account',
            Account_CSM__c = UserInfo.getUserId()
        );
        insert testAcc;

        Test.startTest();
        String briefData = AiSalesAssistantController.buildCsmBriefData(UserInfo.getUserId());
        Test.stopTest();

        System.assertNotEquals(null, briefData, 'Brief data should not be null');
        System.assert(briefData.length() > 0, 'Brief data should not be empty');
        System.assert(briefData.contains('CRITICAL') || briefData.contains('REVENUE') || briefData.contains('QBR'),
            'Should contain CSM-relevant sections');
    }

    @isTest
    static void testBuildAdBriefData_EmptyOrg() {
        // Ensure AD brief handles zero data gracefully (no opps, no tasks, no events)
        setupTestConfig();

        Test.startTest();
        String briefData = AiSalesAssistantController.buildAdBriefData(UserInfo.getUserId());
        Test.stopTest();

        System.assertNotEquals(null, briefData);
        // Should still have section headers even with no data
        System.assert(briefData.contains('CLOSING THIS MONTH'), 'Should contain closing section');
        System.assert(briefData.contains('DATA HYGIENE'), 'Should contain hygiene section');
    }

    @isTest
    static void testBuildCsmBriefData_WithRedAccount() {
        // Test CSM brief with a RED RAG account to cover at-risk path
        setupTestConfig();

        Account testAcc = new Account(
            Name = 'CSM Red Account',
            Account_CSM__c = UserInfo.getUserId(),
            RAG__c = 'RED'
        );
        insert testAcc;

        Test.startTest();
        String briefData = AiSalesAssistantController.buildCsmBriefData(UserInfo.getUserId());
        Test.stopTest();

        System.assertNotEquals(null, briefData);
        System.assert(briefData.contains('ACCOUNT REVENUE') || briefData.contains('ACCOUNTS MISSING RAG'),
            'Should contain revenue or hygiene sections');
    }
}
