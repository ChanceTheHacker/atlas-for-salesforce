@IsTest
private class Atlas_SupportTicketsTest {
    static Id conversation() {
        return Atlas_Data.saveConversation('{"title":"Atlas production investigation","mode":"support-tickets","request":"Investigate, do not repair QA."}');
    }

    static Map<String,Object> batch(String assigneeId) {
        return new Map<String,Object>{'projectKey' => 'DEMO', 'tickets' => new List<Object>{
            new Map<String,Object>{'ref' => 'bug-1', 'issueType' => 'Bug', 'summary' => 'Suspected validation bug',
                'description' => 'QA evidence only. Confirm in production; manager to review and assign repair.',
                'assigneeId' => assigneeId, 'dueDate' => null}
        }};
    }

    static void refusedBatch(Id id, Map<String,Object> input) {
        try { Atlas_Tickets.prepareBatch(id, JSON.serialize(input)); System.assert(false, 'Unsafe batch must fail'); }
        catch (AuraHandledException e) { System.assertNotEquals(null, e.getMessage()); }
        try { Atlas_Tickets.applyBatch(id, JSON.serialize(input)); System.assert(false, 'Direct save must also fail'); }
        catch (AuraHandledException e) { System.assertNotEquals(null, e.getMessage()); }
    }

    @IsTest
    static void investigationModePersistsAndCannotBecomeSource() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = conversation();
            System.assert(Atlas_Data.isSupportTicketsConversation(id));
            System.assertEquals(false, Atlas_Data.isSupportTicketsConversation(null));
            Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'id' => id, 'status' => 'Closed'}));
            Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'id' => id, 'status' => 'Open', 'mode' => 'support-tickets'}));
            Map<String,Object> stored = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(id));
            System.assertEquals('support-tickets', stored.get('mode'));
            for (String mode : new List<String>{'Source', 'Task', 'Files', null}) {
                try { Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'id' => id, 'mode' => mode})); System.assert(false); }
                catch (AuraHandledException e) { System.assert(e.getMessage().contains('cannot change modes')); }
            }
            System.assert(Atlas_Data.isSupportTicketsConversation(id));
            Id source = Atlas_Data.saveConversation('{"title":"Atlas source work","mode":"Source"}');
            Atlas_Data.assertSourceChangesAllowed(source);
            try { Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'id' => source, 'mode' => 'support-tickets'})); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('cannot change modes')); }
        }
    }

    @IsTest
    static void sourceBackupsProposalsApprovalAndRestoresAreRefused() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = conversation();
            Atlas_Change__c change = new Atlas_Change__c(Conversation__c = id, Status__c = 'Proposed', Revision__c = 1);
            insert as user change;
            Integer calls = Limits.getCallouts();
            try { Atlas_Changes.startBackup(id, null, 'Must not create a change', '[{"type":"ApexClass","name":"Example"}]'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets')); }
            try { Atlas_Changes.startBackup(null, change.Id, 'Must not reuse a change', '[{"type":"ApexClass","name":"Example"}]'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets')); }
            try { Atlas_Changes.propose(change.Id, '{}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets')); }
            try { Atlas_Changes.decide(change.Id, 1, true, null, 'Default'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets')); }
            try { Atlas_Changes.startRestore(change.Id, '[]', 'Default', false, '{}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets')); }
            System.assertEquals(calls, Limits.getCallouts(), 'No source callouts are made by rejected investigation writes');
            System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
            System.assertEquals(0, [SELECT COUNT() FROM ContentVersion]);
        }
    }

    @IsTest
    static void backgroundWorkersRefuseLegacyOrRelinkedInvestigationChanges() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = conversation();
            for (String status : new List<String>{'Deploying', 'Restoring'}) {
                Atlas_Change__c change = new Atlas_Change__c(Conversation__c = id, Status__c = status, Revision__c = 1);
                insert as user change;
                Integer calls = Limits.getCallouts();
                Atlas_Changes.executeDeployment(change.Id, null, 0);
                Atlas_Change__c result = [SELECT Status__c, Result__c, Deploy_Id__c FROM Atlas_Change__c WHERE Id = :change.Id];
                System.assertEquals('Failed', result.Status__c);
                System.assert(result.Result__c.contains('Support Tickets'));
                System.assertEquals(null, result.Deploy_Id__c);
                System.assertEquals(calls, Limits.getCallouts());
            }
        }
    }

    @IsTest
    static void unconfiguredManagerAllowsUnassignedManualBugWithoutRemoteWrites() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Data.saveSetting('jira', '{"projectKey":"DEMO"}');
            Id id = conversation();
            String prepared = Atlas_Tickets.prepareBatch(id, JSON.serialize(batch(null)));
            Integer calls = Limits.getCallouts();
            String result = Atlas_Tickets.applyBatch(id, prepared);
            System.assertEquals(result, Atlas_Tickets.applyBatch(id, prepared), 'Response-loss retry reuses saved draft');
            System.assertEquals(calls, Limits.getCallouts());
            Atlas_Ticket__c ticket = [SELECT Issue_Type__c, Assignee__c, Due_Date__c, Stage__c FROM Atlas_Ticket__c WHERE Conversation__c = :id];
            System.assertEquals('Bug', ticket.Issue_Type__c);
            System.assertEquals(null, ticket.Assignee__c);
            System.assertEquals(null, ticket.Due_Date__c);
            System.assertEquals('Draft', ticket.Stage__c);
            System.assert(result.contains('routed to the manager manually'));
        }
    }

    @IsTest
    static void investigationDraftsCannotChangeTasksEpicsProjectsOrAssignments() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Data.saveSetting('jira', '{"projectKey":"DEMO"}');
            Id id = conversation();
            Map<String,Object> input = batch(null);
            ((Map<String,Object>)((List<Object>)input.get('tickets'))[0]).put('issueType', 'Task');
            refusedBatch(id, input);
            input = batch(null); input.put('epics', new List<Object>{new Map<String,Object>{'ref' => 'epic'}}); refusedBatch(id, input);
            input = batch(null); input.put('updates', new List<Object>{new Map<String,Object>{'target' => 'DEMO-1'}}); refusedBatch(id, input);
            input = batch(null); input.put('projectKey', 'OTHER'); refusedBatch(id, input);
            input = batch(null); input.put('tickets', new List<Object>()); refusedBatch(id, input);
            Id other = Atlas_Data.savePerson('{"name":"Other developer","jiraId":"other"}');
            refusedBatch(id, batch(other));
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c]);
        }
    }

    @IsTest
    static void managerChangesRequireAnotherReviewBeforeSavingBug() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id manager = Atlas_Data.savePerson('{"name":"Review Manager","jiraId":"manager"}');
            Atlas_Data.saveSetting('jira', JSON.serialize(new Map<String,Object>{'projectKey' => 'DEMO', 'apiVersion' => '2',
                'reviewManagerPersonId' => manager, 'reviewManagerIdentityType' => 'name'}));
            Id id = conversation();
            String prepared = Atlas_Tickets.prepareBatch(id, JSON.serialize(batch(manager)));
            // Older clients omit these fields; omission preserves the reviewed manager.
            Atlas_Data.saveSetting('jira', '{"projectKey":"DEMO","apiVersion":"2"}');
            Map<String,Object> preserved = Atlas_Jira.reviewManager();
            System.assertEquals(String.valueOf(manager), preserved.get('personId'));
            System.assertEquals(true, preserved.get('ready'));
            System.assertEquals('name', preserved.get('identityType'));
            // Explicitly remove the manager to invalidate the already prepared Bug.
            Atlas_Data.saveSetting('jira', '{"projectKey":"DEMO","apiVersion":"2","reviewManagerPersonId":""}');
            Map<String,Object> cleared = Atlas_Jira.reviewManager();
            System.assertEquals('unconfigured', cleared.get('status'));
            System.assertEquals(false, cleared.get('ready'));
            System.assertEquals('', cleared.get('identityType'));
            try { Atlas_Tickets.applyBatch(id, prepared); System.assert(false, 'A prepared Bug must be reviewed again after its manager is cleared.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('configured manager')); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c]);
        }
    }
}
