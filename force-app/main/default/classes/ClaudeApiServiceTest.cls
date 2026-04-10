@isTest
private class ClaudeApiServiceTest {

    private static void setupTestConfig() {
        ClaudeApiService.testConfig = new AI_Assistant_Config__mdt(
            DeveloperName = 'Gemini_API',
            API_Key__c = 'test-api-key-12345',
            Model_Name__c = 'claude-sonnet-4-6',
            Max_Tokens__c = 4096
        );
    }

    private class MockClaudeSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"```soql\\nSELECT COUNT(Id) FROM Opportunity WHERE StageName = \'Order\'\\n```"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50}}');
            return res;
        }
    }

    private class MockClaudeError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"type":"error","error":{"type":"invalid_request_error","message":"Bad request"}}');
            return res;
        }
    }

    private class MockClaudeEmptyResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"id":"msg_02","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":0}}');
            return res;
        }
    }

    @isTest
    static void testSendMessage_Success() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());
        Test.startTest();
        ClaudeApiService.ClaudeResponse resp = ClaudeApiService.sendMessage(
            'You are a SOQL expert.',
            'Count all won deals',
            1024
        );
        Test.stopTest();

        System.assertNotEquals(null, resp, 'Response should not be null');
        System.assertNotEquals(null, resp.content, 'Content should not be null');
        System.assert(resp.content.contains('SELECT'), 'Response should contain SOQL');
        System.assertEquals('end_turn', resp.stopReason, 'Stop reason should be end_turn');
    }

    @isTest
    static void testSendConversation_Success() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());

        List<Map<String, String>> messages = new List<Map<String, String>>();
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => 'Count deals' });
        messages.add(new Map<String, String>{ 'role' => 'assistant', 'content' => 'Here is the query' });
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => 'Summarize results' });

        Test.startTest();
        ClaudeApiService.ClaudeResponse resp = ClaudeApiService.sendConversation(
            'Summarize data.',
            messages,
            2048
        );
        Test.stopTest();

        System.assertNotEquals(null, resp, 'Response should not be null');
    }

    @isTest
    static void testSendMessage_ApiError() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeError());

        Test.startTest();
        try {
            ClaudeApiService.sendMessage('Test', 'Test', 1024);
            System.assert(false, 'Should have thrown exception');
        } catch (ClaudeApiService.ClaudeException e) {
            System.assert(e.getMessage().contains('400'), 'Error should contain status code: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testSendMessage_EmptyResponse() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeEmptyResponse());

        Test.startTest();
        try {
            ClaudeApiService.sendMessage('Test', 'Test', 1024);
            System.assert(false, 'Should have thrown exception');
        } catch (ClaudeApiService.ClaudeException e) {
            System.assert(e.getMessage().toLowerCase().contains('empty'),
                'Should mention empty response: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testSendMessage_WithModelOverride() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());
        Test.startTest();
        // Test the 4-param overload with explicit model override
        ClaudeApiService.ClaudeResponse resp = ClaudeApiService.sendMessage(
            'You are a SOQL expert.',
            'Count all won deals',
            1024,
            'claude-haiku-4-5-20250414'
        );
        Test.stopTest();

        System.assertNotEquals(null, resp, 'Response should not be null');
        System.assertNotEquals(null, resp.content, 'Content should not be null');
    }

    @isTest
    static void testSendConversation_WithModelOverride() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());

        List<Map<String, String>> messages = new List<Map<String, String>>();
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => 'Count deals' });

        Test.startTest();
        ClaudeApiService.ClaudeResponse resp = ClaudeApiService.sendConversation(
            'Summarize data.',
            messages,
            2048,
            'claude-haiku-4-5-20250414'
        );
        Test.stopTest();

        System.assertNotEquals(null, resp, 'Response should not be null');
    }

    @isTest
    static void testSendMessage_NullModelOverrideFallsToConfig() {
        setupTestConfig();
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());
        Test.startTest();
        // null override should fall back to config model
        ClaudeApiService.ClaudeResponse resp = ClaudeApiService.sendMessage(
            'Test', 'Test', 1024, null
        );
        Test.stopTest();
        System.assertNotEquals(null, resp);
    }

    @isTest
    static void testSendMessage_NoConfig() {
        // Force null config — should throw config-not-found error
        ClaudeApiService.testConfig = null;
        ClaudeApiService.testForceNullConfig = true;
        Test.setMock(HttpCalloutMock.class, new MockClaudeSuccess());

        Test.startTest();
        try {
            ClaudeApiService.sendMessage('Test', 'Test', 1024);
            System.assert(false, 'Should have thrown exception for missing config');
        } catch (ClaudeApiService.ClaudeException e) {
            System.assert(e.getMessage().contains('configuration not found'),
                'Should mention missing config: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
