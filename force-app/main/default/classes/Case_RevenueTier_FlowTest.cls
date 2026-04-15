/**
 * Unit tests for the Case_RevenueTier_BeforeSave Flow.
 *
 * Validates that the Flow correctly stamps Account_Revenue_Tier__c and related
 * context fields on new Cases based on the Account's Support_Tier__c formula.
 *
 * Covers tier scenarios: HYPERCARE (active + expired), STRATEGIC, PREMIUM,
 * STANDARD, and UNKNOWN (no Account), plus bulk insert governor-limit behavior.
 *
 * See docs/revenue-in-support/02-case-flow-specification.md
 */
@isTest
private class Case_RevenueTier_FlowTest {

    private static final String TEST_CSM_ALIAS = 'uatcsm';
    private static final String TEST_CSM_EMAIL = 'uat-csm@exotel.test.invalid';

    @testSetup
    static void setup() {
        // Create a test CSM user
        Profile standardUserProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User csm = new User(
            Alias         = TEST_CSM_ALIAS,
            Email         = TEST_CSM_EMAIL,
            Username      = TEST_CSM_EMAIL,
            LastName      = 'TestCSM',
            FirstName     = 'UAT',
            TimeZoneSidKey   = 'Asia/Kolkata',
            LocaleSidKey     = 'en_IN',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey= 'en_US',
            ProfileId     = standardUserProfile.Id
        );
        insert csm;

        // Create canonical test accounts — one per tier scenario.
        // NOTE: Hypercare_active__c picklist values assumed — adjust if needed.
        List<Account> accounts = new List<Account>{
            new Account(
                Name = 'UAT Hypercare Active',
                Hypercare_active__c    = 'Active',
                Hypercare_End_Date__c  = DateTime.now().addDays(30),
                Account_CSM__c         = csm.Id,
                RAG__c                 = 'RED'
            ),
            new Account(
                Name = 'UAT Hypercare Expired',
                Hypercare_active__c    = 'Active',
                Hypercare_End_Date__c  = DateTime.now().addDays(-5),
                Account_CSM__c         = csm.Id,
                RAG__c                 = 'AMBER'
            ),
            new Account(
                Name = 'UAT Strategic Top',
                Top_Customer__c = true,
                Account_CSM__c  = csm.Id,
                RAG__c          = 'GREEN'
            ),
            new Account(
                Name = 'UAT Strategic SAAS Premium',
                Is_SAAS_Premium_Account__c = true,
                Account_CSM__c             = csm.Id,
                RAG__c                     = 'AMBER'
            ),
            new Account(
                Name = 'UAT Premium',
                SAAS_Enterprise_Account__c = true,
                Account_CSM__c             = csm.Id,
                RAG__c                     = 'GREEN'
            ),
            new Account(
                Name = 'UAT Premium RED',
                SAAS_Enterprise_Account__c = true,
                Account_CSM__c             = csm.Id,
                RAG__c                     = 'RED'
            ),
            new Account(
                Name = 'UAT Standard',
                Account_CSM__c = csm.Id
            )
        };
        insert accounts;
    }

    // ------------------------------------------------------------------
    // Tier assignment tests
    // ------------------------------------------------------------------

    @isTest
    static void tierStampedForActiveHypercare() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Hypercare Active' LIMIT 1];
        Case c = new Case(
            AccountId = a.Id,
            Subject   = 'Test Hypercare Active',
            Priority  = 'Minor',
            Status    = 'New'
        );
        insert c;

        Case stamped = [
            SELECT Account_Revenue_Tier__c, Priority, Account_CSM_Name__c, Account_RAG_at_Creation__c
            FROM Case WHERE Id = :c.Id
        ];

        System.assertEquals('HYPERCARE', stamped.Account_Revenue_Tier__c,
            'Active Hypercare account should stamp HYPERCARE tier');
        System.assertEquals('Critical', stamped.Priority,
            'Hypercare tier should upgrade Minor priority to Critical');
        System.assertEquals('RED', stamped.Account_RAG_at_Creation__c,
            'RAG at creation should be captured from Account');
        System.assert(String.isNotBlank(stamped.Account_CSM_Name__c),
            'CSM name should be stamped on the Case');
    }

    @isTest
    static void tierFallsBackWhenHypercareExpired() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Hypercare Expired' LIMIT 1];
        Case c = new Case(
            AccountId = a.Id,
            Subject   = 'Test Hypercare Expired',
            Status    = 'New'
        );
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];

        System.assertNotEquals('HYPERCARE', stamped.Account_Revenue_Tier__c,
            'Expired Hypercare should not stamp HYPERCARE tier');
    }

    @isTest
    static void tierStampedForTopCustomer() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Strategic Top' LIMIT 1];
        Case c = new Case(AccountId = a.Id, Subject = 'Test Top Customer', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('STRATEGIC', stamped.Account_Revenue_Tier__c);
    }

    @isTest
    static void tierStampedForSaasPremium() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Strategic SAAS Premium' LIMIT 1];
        Case c = new Case(AccountId = a.Id, Subject = 'Test SAAS Premium', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('STRATEGIC', stamped.Account_Revenue_Tier__c);
    }

    @isTest
    static void tierStampedForSaasEnterpriseGreen() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Premium' LIMIT 1];
        Case c = new Case(AccountId = a.Id, Subject = 'Test Premium Green', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('PREMIUM', stamped.Account_Revenue_Tier__c);
    }

    @isTest
    static void tierFallsToStandardForSaasEnterpriseRed() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Premium RED' LIMIT 1];
        Case c = new Case(AccountId = a.Id, Subject = 'Test Premium Red', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('STANDARD', stamped.Account_Revenue_Tier__c,
            'SAAS Enterprise with RED RAG should fall to STANDARD — only GREEN/AMBER qualify for PREMIUM');
    }

    @isTest
    static void tierStampedForStandardAccount() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Standard' LIMIT 1];
        Case c = new Case(AccountId = a.Id, Subject = 'Test Standard', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('STANDARD', stamped.Account_Revenue_Tier__c);
    }

    @isTest
    static void tierUnknownWhenNoAccount() {
        Case c = new Case(Subject = 'Test No Account', Status = 'New');
        insert c;

        Case stamped = [SELECT Account_Revenue_Tier__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('UNKNOWN', stamped.Account_Revenue_Tier__c,
            'Case without Account should stamp UNKNOWN tier');
    }

    // ------------------------------------------------------------------
    // Priority handling tests
    // ------------------------------------------------------------------

    @isTest
    static void priorityPreservedForNonHypercare() {
        Account a = [SELECT Id FROM Account WHERE Name = 'UAT Strategic Top' LIMIT 1];
        Case c = new Case(
            AccountId = a.Id,
            Subject   = 'Test Priority Preserved',
            Priority  = 'Critical',
            Status    = 'New'
        );
        insert c;

        Case stamped = [SELECT Priority FROM Case WHERE Id = :c.Id];
        System.assertEquals('Critical', stamped.Priority,
            'Existing Critical priority should not be downgraded');
    }

    // ------------------------------------------------------------------
    // Bulk handling — governor limits
    // ------------------------------------------------------------------

    @isTest
    static void bulkInsertStamp200Cases() {
        List<Account> accs = [SELECT Id FROM Account ORDER BY Name LIMIT 7];
        System.assertEquals(7, accs.size(), 'Expected 7 UAT accounts from @testSetup');

        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 200; i++) {
            cases.add(new Case(
                AccountId = accs[Math.mod(i, accs.size())].Id,
                Subject   = 'Bulk Test ' + i,
                Status    = 'New'
            ));
        }

        Test.startTest();
        insert cases;
        Test.stopTest();

        Set<Id> ids = new Map<Id, Case>(cases).keySet();
        Integer stampedCount = [
            SELECT COUNT() FROM Case
            WHERE Id IN :ids AND Account_Revenue_Tier__c != null
        ];

        System.assertEquals(200, stampedCount,
            'All 200 bulk-inserted Cases should have Account_Revenue_Tier__c stamped');
    }
}
