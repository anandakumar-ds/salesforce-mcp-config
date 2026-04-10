/**
 * Service class for communicating with the Anthropic Claude API.
 * Handles HTTP callouts, request building, and response parsing.
 */
public class ClaudeApiService {

    public class ClaudeException extends Exception {}

    public class ClaudeResponse {
        public String content;
        public String stopReason;
    }

    /**
     * Sends a single message to Claude with a system prompt.
     */
    public static ClaudeResponse sendMessage(String systemPrompt, String userMessage, Integer maxTokens) {
        List<Map<String, String>> messages = new List<Map<String, String>>();
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userMessage });
        return callClaudeApi(systemPrompt, messages, maxTokens, null);
    }

    /**
     * Sends a single message with an explicit model override.
     * Use this for tasks where a faster/cheaper model is sufficient (e.g., SOQL generation).
     * Pass null for modelOverride to use the default model from config.
     */
    public static ClaudeResponse sendMessage(String systemPrompt, String userMessage, Integer maxTokens, String modelOverride) {
        List<Map<String, String>> messages = new List<Map<String, String>>();
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userMessage });
        return callClaudeApi(systemPrompt, messages, maxTokens, modelOverride);
    }

    /**
     * Sends a multi-turn conversation to Claude with a system prompt.
     */
    public static ClaudeResponse sendConversation(String systemPrompt, List<Map<String, String>> messages, Integer maxTokens) {
        return callClaudeApi(systemPrompt, messages, maxTokens, null);
    }

    /**
     * Sends a multi-turn conversation with an explicit model override.
     */
    public static ClaudeResponse sendConversation(String systemPrompt, List<Map<String, String>> messages, Integer maxTokens, String modelOverride) {
        return callClaudeApi(systemPrompt, messages, maxTokens, modelOverride);
    }

    // Test-visible config override so tests don't depend on deployed Custom Metadata records
    @TestVisible
    private static AI_Assistant_Config__mdt testConfig;
    // When true, forces config to null even if the record exists (for testing missing-config scenario)
    @TestVisible
    private static Boolean testForceNullConfig = false;

    /**
     * Core method: builds and sends the HTTP request to Claude API.
     * @param modelOverride — if non-null, overrides the model from config. Use for fast-model routing.
     */
    private static ClaudeResponse callClaudeApi(String systemPrompt, List<Map<String, String>> messages, Integer maxTokens, String modelOverride) {
        // Load config — use test override if available
        AI_Assistant_Config__mdt config;
        if (Test.isRunningTest() && testForceNullConfig) {
            config = null;
        } else if (Test.isRunningTest() && testConfig != null) {
            config = testConfig;
        } else {
            config = AI_Assistant_Config__mdt.getInstance('Claude_API');
        }
        if (config == null) {
            throw new ClaudeException('AI Assistant configuration not found. Please set up the Claude_API custom metadata record.');
        }

        String apiKey = config.API_Key__c;
        // Model priority: explicit override > config value > default
        String modelName = String.isNotBlank(modelOverride)
            ? modelOverride
            : (config.Model_Name__c != null ? config.Model_Name__c : 'claude-sonnet-4-6');
        String endpoint = 'https://api.anthropic.com/v1/messages';

        // Build messages array for the request
        List<Map<String, String>> apiMessages = new List<Map<String, String>>();
        for (Map<String, String> msg : messages) {
            Map<String, String> apiMsg = new Map<String, String>();
            apiMsg.put('role', msg.get('role'));
            apiMsg.put('content', msg.get('content'));
            apiMessages.add(apiMsg);
        }

        // Build request body
        Map<String, Object> requestBody = new Map<String, Object>();
        requestBody.put('model', modelName);
        requestBody.put('max_tokens', maxTokens != null ? maxTokens : 4096);
        requestBody.put('temperature', 0.1);

        // System prompt
        if (String.isNotBlank(systemPrompt)) {
            requestBody.put('system', systemPrompt);
        }

        // Messages
        requestBody.put('messages', apiMessages);

        // Build HTTP request
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('x-api-key', apiKey);
        req.setHeader('anthropic-version', '2023-06-01');
        req.setTimeout(120000); // Max 120 seconds
        req.setBody(JSON.serialize(requestBody));

        // Send request
        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            String errorMsg = 'Claude API returned status ' + res.getStatusCode();
            try {
                Map<String, Object> errorBody = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                Map<String, Object> error = (Map<String, Object>) errorBody.get('error');
                if (error != null) {
                    errorMsg += ': ' + (String) error.get('message');
                }
            } catch (Exception e) {
                errorMsg += ': ' + res.getBody();
            }
            throw new ClaudeException(errorMsg);
        }

        // Parse response
        return parseResponse(res.getBody());
    }

    /**
     * Parses Claude API response JSON.
     * Claude response format:
     * {
     *   "content": [{"type": "text", "text": "response text"}],
     *   "stop_reason": "end_turn"
     * }
     */
    private static ClaudeResponse parseResponse(String responseBody) {
        Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

        List<Object> contentBlocks = (List<Object>) responseMap.get('content');
        if (contentBlocks == null || contentBlocks.isEmpty()) {
            throw new ClaudeException('Empty response from Claude.');
        }

        // Concatenate all text content blocks
        String responseText = '';
        for (Object blockObj : contentBlocks) {
            Map<String, Object> block = (Map<String, Object>) blockObj;
            String blockType = (String) block.get('type');
            if (blockType == 'text') {
                String text = (String) block.get('text');
                if (text != null) {
                    responseText += text;
                }
            }
        }

        if (String.isBlank(responseText)) {
            throw new ClaudeException('Empty response from Claude.');
        }

        ClaudeResponse claudeResp = new ClaudeResponse();
        claudeResp.content = responseText;
        claudeResp.stopReason = (String) responseMap.get('stop_reason');

        return claudeResp;
    }
}
