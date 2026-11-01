@IsTest
private class Atlas_TicketsTest {
    @TestSetup
    static void setup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c me = new Atlas_Person__c(Name = 'Me Myself', User__c = UserInfo.getUserId(), Active__c = true, Jira_Account_Id__c = 'jira-me');
            insert me;
            insert new Atlas_Person__c(Name = 'Robin Report', Manager__c = me.Id, Active__c = true, Aliases__c = 'rob', Jira_Account_Id__c = 'jira-robin');
            insert new Atlas_Conversation__c(Name = 'Plan', Mode__c = 'Task', Status__c = 'Open');
        }
    }

    static Id person(String name) {
        return [SELECT Id FROM Atlas_Person__c WHERE Name = :name].Id;
    }

    static Id conversation() {
        return [SELECT Id FROM Atlas_Conversation__c LIMIT 1].Id;
    }

    static Map<String, Object> apply(String batchJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(Atlas_Tickets.applyBatch(conversation(), Atlas_Tickets.prepareBatch(conversation(), batchJson)));
    }

    static Map<String, Object> query(String requestJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(Atlas_Tickets.agentQuery((Map<String, Object>) JSON.deserializeUntyped(requestJson)));
    }

    static void save(String text) {
        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(text);
        if (input.get('id') != null) input.put('expectedVersion', Atlas_Tickets.getTicket((Id) input.get('id')).version);
        Atlas_Tickets.saveTicket(JSON.serialize(input));
    }

    // These fixtures simulate a prior export; production uses saveExport, tested below.
    static void stage(Id id, String value, String batch) {
        if (value == 'Exported') update new Atlas_Ticket__c(Id = id, Stage__c = value, Export_Batch__c = batch);
        else Atlas_Tickets.setStage(new List<Id>{ id }, value, batch, JSON.serialize(new Map<Id, String>{ id => Atlas_Tickets.getTicket(id).version }));
    }

    static void finish(Id id, String updateId, Boolean done) {
        if (!done) { Atlas_Tickets.completeUpdate(id, updateId, false); return; }
        Atlas_Tickets.Ticket t = Atlas_Tickets.getTicket(id);
        for (Object item : t.pendingUpdates) {
            Map<String, Object> u = (Map<String, Object>) item;
            if (u.get('id') != updateId) continue;
            for (String field : ((Map<String, Object>) u.get('changes')).keySet())
                Atlas_Tickets.completeUpdatePart(id, updateId, 'field:' + field, true, Atlas_Tickets.getTicket(id).version);
            List<Object> comments = (List<Object>) u.get('comments');
            for (Integer i = 0; i < comments.size(); i++)
                Atlas_Tickets.completeUpdatePart(id, updateId, 'comment:' + i, true, Atlas_Tickets.getTicket(id).version);
        }
    }

    static String batch() {
        return '{"projectKey":"DEMO","epics":[{"ref":"E1","summary":"Self-service","description":"Epic text","assigneeId":"' + person('Me Myself') + '"}],'
            + '"tickets":[{"ref":"T1","epicRef":"E1","summary":"Build the form","issueType":"Story","priority":"High","dueDate":"2026-11-02",'
            + '"dueDateSource":"agent","assigneeId":"' + person('Robin Report') + '"},{"ref":"T2","summary":"Unassigned chore","dueDate":""}]}';
    }

    @IsTest
    static void savesBatchesAndRevisesDrafts() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> first = apply(batch());
            List<Object> saved = (List<Object>) first.get('saved');
            System.assertEquals(3, saved.size());
            System.assert(((String) ((Map<String, Object>) saved[0]).get('atlasId')).startsWith('TKT-'));
            Atlas_Ticket__c story = [SELECT Id, Epic__c, Epic__r.Issue_Type__c, Stage__c, Due_Date__c, Project_Key__c FROM Atlas_Ticket__c WHERE Summary__c = 'Build the form'];
            System.assertEquals('Epic', story.Epic__r.Issue_Type__c);
            System.assertEquals(Date.newInstance(2026, 11, 2), story.Due_Date__c);
            System.assertEquals('DEMO', story.Project_Key__c);

            // The same ref in the same conversation revises the draft.
            apply(batch().replace('Build the form', 'Build the better form'));
            System.assertEquals(3, [SELECT COUNT() FROM Atlas_Ticket__c]);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Ticket__c WHERE Summary__c = 'Build the better form']);

            // Once a ticket left Draft, reusing its ref is an error and nothing is saved.
            stage(story.Id, 'Exported', 'batch-1');
            try {
                apply(batch().replace('Build the form', 'A new revision after export'));
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('has left Draft'), e.getMessage());
            }
            System.assertEquals('batch-1', [SELECT Export_Batch__c FROM Atlas_Ticket__c WHERE Id = :story.Id].Export_Batch__c);

            // New refs keep working in a continued conversation, including links to saved epics.
            String epicName = [SELECT Name FROM Atlas_Ticket__c WHERE Issue_Type__c = 'Epic'].Name;
            apply('{"tickets":[{"ref":"T3","summary":"Follow-up","epicTicket":"' + epicName + '"}]}');
            System.assertNotEquals(null, [SELECT Epic__c FROM Atlas_Ticket__c WHERE Summary__c = 'Follow-up'].Epic__c);
        }
    }

    @IsTest
    static void revisedDraftsReplaceBothEpicRepresentations() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            Atlas_Ticket__c story = [SELECT Id FROM Atlas_Ticket__c WHERE Summary__c = 'Build the form'];
            Atlas_Ticket__c epic = [SELECT Id, Name FROM Atlas_Ticket__c WHERE Issue_Type__c = 'Epic'];
            apply('{"tickets":[{"ref":"T1","summary":"External parent","epicKey":"DEMO-900"}]}');
            Atlas_Tickets.Ticket current = Atlas_Tickets.getTicket(story.Id);
            System.assertEquals(null, current.epicId, 'A Jira-only parent replaces the old lookup.');
            System.assertEquals('DEMO-900', current.epicKey);

            apply('{"tickets":[{"ref":"T1","summary":"Saved parent","epicTicket":"' + epic.Name + '"}]}');
            current = Atlas_Tickets.getTicket(story.Id);
            System.assertEquals(epic.Id, current.epicId);
            System.assertEquals(null, [SELECT Epic_Key__c FROM Atlas_Ticket__c WHERE Id = :story.Id].Epic_Key__c,
                'A saved parent must not retain the previous Jira-only key.');

            String reviewed = Atlas_Tickets.prepareBatch(conversation(), '{"batchId":"remove-parent","tickets":[{"ref":"T1","summary":"No parent"}]}');
            String receipt = Atlas_Tickets.applyBatch(conversation(), reviewed);
            current = Atlas_Tickets.getTicket(story.Id);
            System.assertEquals(null, current.epicId);
            System.assertEquals(null, current.epicKey);
            System.assertEquals(receipt, Atlas_Tickets.applyBatch(conversation(), reviewed));
            System.assertEquals(3, [SELECT COUNT() FROM Atlas_Ticket__c], 'Revisions and replay must not create duplicates.');
        }
    }

    @IsTest
    static void reviewedBatchesRejectChangedDraftsAndUpdates() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            Atlas_Ticket__c story = [SELECT Id, Name FROM Atlas_Ticket__c WHERE Summary__c = 'Build the form'];
            String draft = Atlas_Tickets.prepareBatch(conversation(), batch().replace('Build the form', 'Reviewed edit'));
            String updates = Atlas_Tickets.prepareBatch(conversation(), '{"updates":[{"target":"' + story.Name + '","changes":{"summary":"Reviewed update"}}]}');
            save('{"id":"' + story.Id + '","summary":"Teammate edit"}');
            for (String prepared : new List<String>{ draft, updates }) {
                try { Atlas_Tickets.applyBatch(conversation(), prepared); System.assert(false); }
                catch (AuraHandledException e) { System.assert(e.getMessage().contains('changed'), e.getMessage()); }
            }
            Atlas_Tickets.Ticket current = Atlas_Tickets.getTicket(story.Id);
            System.assertEquals('Teammate edit', current.summary);
            System.assertEquals(0, current.pendingCount);
        }
    }

    @IsTest
    static void reviewedBatchReceiptsIgnoreNewReviewVersions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String input = '{"batchId":"stable","tickets":[{"ref":"T","summary":"Original"}]}';
            String prepared = Atlas_Tickets.prepareBatch(conversation(), input);
            String first = Atlas_Tickets.applyBatch(conversation(), prepared);
            Atlas_Ticket__c ticket = [SELECT Id FROM Atlas_Ticket__c];
            save('{"id":"' + ticket.Id + '","summary":"Later edit"}');
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation(), prepared));
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation(), Atlas_Tickets.prepareBatch(conversation(), input)));
            System.assertEquals('Later edit', Atlas_Tickets.getTicket(ticket.Id).summary);
            System.assertEquals(1, [SELECT count() FROM Atlas_Ticket__c]);
            try { apply(input.replace('Original','Different content')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('batchId')); }
            try { Atlas_Tickets.applyBatch(conversation(), '{"tickets":[{"ref":"NEW","summary":"Unreviewed"}]}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Reopen')); }
        }
    }

    @IsTest
    static void batchCommitAndReplayIncludeOneDurableAcknowledgment() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = conversation();
            Atlas_Ticket__c target = new Atlas_Ticket__c(Summary__c = 'Existing', Jira_Key__c = 'DEMO-600');
            insert target;
            String input = '{"batchId":"atomic-handoff","tickets":[{"ref":"T","summary":"Saved draft"}],"updates":[{"target":"DEMO-600","comments":"Manual note"}]}';
            String prepared = Atlas_Tickets.prepareBatch(conversation(), input);
            String first = Atlas_Tickets.applyBatch(conversation(), prepared);
            Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(first);
            System.assertNotEquals(null, result.get('receiptId'));
            String acknowledgment = (String)result.get('acknowledgment');
            System.assertNotEquals(null, acknowledgment, 'The business commit must include its saved agent handoff.');
            System.assert(acknowledgment.contains((String)((Map<String,Object>)((List<Object>)result.get('saved'))[0]).get('atlasId')));
            System.assert(acknowledgment.contains((String)((Map<String,Object>)((List<Object>)result.get('updates'))[0]).get('updateId')));
            Map<String,Object> reopened = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(conversation()));
            System.assertEquals(acknowledgment, ((Map<String,Object>)((List<Object>)reopened.get('messages'))[0]).get('body'));
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation(), prepared));
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation(), Atlas_Tickets.prepareBatch(conversation(), input)));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c = :conversationId AND Kind__c = 'tickets']);
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Ticket__c]);
            System.assertEquals(1, Atlas_Tickets.getTicket(target.Id).pendingCount);
        }
    }

    @IsTest
    static void receiptOnlyBatchesRecoverTheirHandoffOnceWithoutReapplying() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String input = '{"batchId":"receipt-before-handoff","tickets":[{"ref":"T","summary":"Original"}]}';
            String title = 'Atlas atlas-batch-' + Atlas_Api.sha256(Blob.valueOf('receipt-before-handoff'));
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Later edit', Origin_Key__c = conversation() + ':T', Conversation__c = conversation());
            insert ticket;
            ticket = [SELECT Id, Name FROM Atlas_Ticket__c WHERE Id = :ticket.Id];
            String saved = JSON.serialize(new Map<String,Object>{'saved' => new List<Object>{new Map<String,Object>{'ref'=>'T','id'=>ticket.Id,'atlasId'=>ticket.Name,'issueType'=>'Task','summary'=>'Original'}},'updates'=>new List<Object>()});
            String prepared = Atlas_Tickets.prepareBatch(conversation(), input);
            Map<String,Object> reviewed = (Map<String,Object>)JSON.deserializeUntyped(prepared);
            // Match the prior business receipt's prepared-batch clone/remove pipeline,
            // rather than relying on the input map's JSON serialization order.
            Map<String,Object> content = reviewed.clone();
            content.remove('expectedVersions');
            content.remove('expectedIdentityVersions');
            String digest = Atlas_Api.sha256(Blob.valueOf(JSON.serialize(content)));
            ContentVersion receipt = new ContentVersion(Title = title, PathOnClient = 'batch-receipt.json', VersionData = Blob.valueOf(saved), Description = digest, FirstPublishLocationId = conversation());
            insert receipt;
            String response = Atlas_Tickets.applyBatch(conversation(), prepared);
            System.assertNotEquals(null, ((Map<String,Object>)JSON.deserializeUntyped(response)).get('acknowledgment'));
            System.assertEquals(response, Atlas_Tickets.applyBatch(conversation(), prepared));
            System.assertEquals(response, Atlas_Tickets.applyBatch(conversation(), Atlas_Tickets.prepareBatch(conversation(), input)));
            try { apply(input.replace('Original', 'Different content')); System.assert(false, 'A recovered receipt must still reject different content.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('batchId'), e.getMessage()); }
            receipt = [SELECT VersionData, Description FROM ContentVersion WHERE Id = :receipt.Id];
            System.assertEquals(saved, receipt.VersionData.toString(), 'Recovery must not rewrite the immutable business receipt.');
            System.assertEquals(digest, receipt.Description);
            System.assertEquals('Later edit', Atlas_Tickets.getTicket(ticket.Id).summary);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Ticket__c]);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'tickets']);
        }
    }

    @IsTest
    static void failedHandoffPermissionsRollBackTicketsAndReceipt() {
        User member;
        System.runAs(new User(Id=UserInfo.getUserId())) {
            String namespace = [SELECT NamespacePrefix FROM Organization LIMIT 1].NamespacePrefix;
            Id source = [SELECT Id FROM PermissionSet WHERE Name='Atlas_User' AND NamespacePrefix=:namespace LIMIT 1].Id;
            PermissionSet permissions = new PermissionSet(Name='Atlas_No_Message_Test', Label='Atlas no message test');
            insert permissions;
            String messageType = Atlas_Message__c.SObjectType.getDescribe().getName();
            List<ObjectPermissions> objects = new List<ObjectPermissions>();
            for (ObjectPermissions original : [SELECT SobjectType, PermissionsCreate, PermissionsRead, PermissionsEdit, PermissionsDelete, PermissionsViewAllRecords, PermissionsModifyAllRecords
                FROM ObjectPermissions WHERE ParentId=:source AND SobjectType!=:messageType]) {
                ObjectPermissions copy = original.clone(false, false, false, false);
                copy.ParentId = permissions.Id; objects.add(copy);
            }
            insert objects;
            List<FieldPermissions> fields = new List<FieldPermissions>();
            for (FieldPermissions original : [SELECT SobjectType, Field, PermissionsRead, PermissionsEdit FROM FieldPermissions WHERE ParentId=:source AND SobjectType!=:messageType]) {
                FieldPermissions copy = original.clone(false, false, false, false);
                copy.ParentId = permissions.Id; fields.add(copy);
            }
            insert fields;
            member = new User(Username='atlas-no-handoff-' + UserInfo.getOrganizationId() + '@example.com', LastName='Atlas no handoff',
                Email='atlas-no-handoff@example.com', Alias='atnohand', ProfileId=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id,
                TimeZoneSidKey='America/New_York', LocaleSidKey='en_US', EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US');
            insert member;
            insert new PermissionSetAssignment(AssigneeId=member.Id, PermissionSetId=permissions.Id);
        }
        System.runAs(member) {
            System.assert(Atlas_Ticket__c.SObjectType.getDescribe().isCreateable());
            System.assert(!Atlas_Message__c.SObjectType.getDescribe().isCreateable());
            Id id = Atlas_Data.saveConversation('{"title":"Atlas atomic failure","mode":"Task"}');
            String prepared = Atlas_Tickets.prepareBatch(id, '{"batchId":"denied-handoff","tickets":[{"ref":"T","summary":"Must roll back"}]}');
            try { Atlas_Tickets.applyBatch(id, prepared); System.assert(false, 'A failed durable acknowledgment must fail the batch.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().length() > 0); }
        }
        System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c WITH SYSTEM_MODE]);
        System.assertEquals(0, [SELECT COUNT() FROM Atlas_Message__c WITH SYSTEM_MODE]);
        System.assertEquals(0, [SELECT COUNT() FROM ContentVersion], 'Neither a business receipt nor a partial acknowledgment may survive.');
    }

    @IsTest
    static void ticketBatchesStillRequireAConversationBeforeAnyWrites() {
        System.runAs(Atlas_Mock.atlasUser()) {
            try { Atlas_Tickets.applyBatch(null, '{"tickets":[{"ref":"T","summary":"Not saved"}]}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('conversation')); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c]);
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Message__c]);
            System.assertEquals(0, [SELECT COUNT() FROM ContentVersion]);
        }
    }

    @IsTest
    static void rejectsBadEpicReferences() {
        System.runAs(Atlas_Mock.atlasUser()) {
            for (String bad : new List<String>{
                '{"tickets":[{"ref":"T1","summary":"x","epicRef":"NOPE"}]}',
                '{"tickets":[{"ref":"T1","summary":"x","epicTicket":"TKT-99999"}]}'
            }) {
                try {
                    apply(bad);
                    System.assert(false);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains('epic'), e.getMessage());
                }
            }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c]);
            // An unknown Jira epic key is kept as text until the epic is imported.
            apply('{"tickets":[{"ref":"T1","summary":"x","epicKey":"DEMO-9"}]}');
            System.assertEquals('DEMO-9', [SELECT Epic_Key__c FROM Atlas_Ticket__c].Epic_Key__c);
        }
    }

    @IsTest
    static void filtersForAgents() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            System.assertEquals(3, query('{}').get('count'));
            System.assertEquals(1, query('{"owner":"me"}').get('count'));
            System.assertEquals(1, query('{"owner":"reports"}').get('count'));
            System.assertEquals(2, query('{"owner":"team"}').get('count'));
            System.assertEquals(1, query('{"owner":"unassigned"}').get('count'));
            System.assertEquals(1, query('{"owner":["rob"]}').get('count'));
            System.assertEquals(1, query('{"owner":"jira-robin"}').get('count'));
            System.assertEquals(1, query('{"epicsOnly":true}').get('count'));
            System.assertEquals(1, query('{"text":"form","description":true,"limit":5}').get('count'));
            // Text is a bind, so an apostrophe matches as typed and LIKE wildcards are literal.
            update new Atlas_Ticket__c(Id = [SELECT Id FROM Atlas_Ticket__c WHERE Summary__c = 'Unassigned chore'].Id, Summary__c = 'Fix O\'Brien\'s chore');
            System.assertEquals(1, query('{"text":"O\'Brien"}').get('count'));
            System.assertEquals(0, query('{"text":"%"}').get('count'));
            System.assertEquals(0, query('{"text":"_"}').get('count'));
            System.assertEquals(3, query('{"stage":"Draft","conversation":"' + conversation() + '"}').get('count'));
            System.assertEquals(0, query('{"status":"Done"}').get('count'));
            String name = [SELECT Name FROM Atlas_Ticket__c WHERE Summary__c = 'Fix O\'Brien\'s chore'].Name;
            System.assertEquals(1, query('{"keys":["' + name + '"]}').get('count'));
            try {
                query('{"owner":"nobody"}');
                System.assert(false);
            } catch (Atlas_Api.AtlasException e) {
                System.assert(e.getMessage().contains('No person named'));
            }
            delete [SELECT Id FROM Atlas_Person__c];
            try {
                query('{"owner":"me"}');
                System.assert(false);
            } catch (Atlas_Api.AtlasException e) {
                System.assert(e.getMessage().contains('Add yourself'));
            }
        }
    }

    @IsTest
    static void editsFromTheBoard() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            Atlas_Ticket__c chore = [SELECT Id FROM Atlas_Ticket__c WHERE Summary__c = 'Unassigned chore'];
            save('{"id":"' + chore.Id + '","summary":"Chore","description":"","dueDate":"2026-12-01","assigneeId":"'
                + person('Robin Report') + '","jiraKey":"DEMO-7","epicId":"","reporterId":""}');
            Atlas_Tickets.Ticket t = Atlas_Tickets.getTicket(chore.Id);
            System.assertEquals('Chore', t.summary);
            System.assertEquals('DEMO-7', t.jiraKey);
            System.assertEquals('Robin Report', t.assigneeName);
            System.assertEquals(Date.newInstance(2026, 12, 1), t.dueDate);
            System.assertEquals(3, Atlas_Tickets.board(false).size());
            stage(chore.Id, 'Archived', null);
            System.assertEquals(2, Atlas_Tickets.board(false).size());
            System.assertEquals(3, Atlas_Tickets.board(true).size());
            Atlas_Tickets.saveTicket('{"summary":"Made by hand","stage":"Draft"}');
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Ticket__c WHERE Summary__c = 'Made by hand']);
        }
    }

    @IsTest
    static void queuesAndCompletesJiraUpdates() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            Atlas_Ticket__c story = [SELECT Id, Name FROM Atlas_Ticket__c WHERE Summary__c = 'Build the form'];
            save('{"id":"' + story.Id + '","jiraKey":"DEMO-1","stage":"In Jira"}');
            Map<String, Object> result = apply('{"updates":[{"target":"demo-1","changes":{"summary":"Renamed","priority":"Low","status":"Done",'
                + '"statusCategory":"Done","dueDate":"2026-12-24","dueDateNote":"Holiday","epicKey":"DEMO-0","assigneeId":"' + person('Me Myself') + '",'
                + '"description":"New text"},"comments":"Moved","reason":"Scope"},{"target":"' + story.Name + '","comments":"Second note"}]}');
            List<Object> updates = (List<Object>) result.get('updates');
            System.assertEquals(2, updates.size());
            Atlas_Tickets.Ticket t = Atlas_Tickets.getTicket(story.Id);
            System.assertEquals(2, t.pendingCount);

            finish(story.Id, (String) ((Map<String, Object>) updates[0]).get('updateId'), true);
            finish(story.Id, (String) ((Map<String, Object>) updates[1]).get('updateId'), false);
            Atlas_Ticket__c r = [SELECT Summary__c, Priority__c, Jira_Status_Category__c, Due_Date__c, Assignee__c FROM Atlas_Ticket__c WHERE Id = :story.Id];
            System.assertEquals('Renamed', r.Summary__c);
            System.assertEquals('Done', r.Jira_Status_Category__c);
            System.assertEquals(person('Me Myself'), r.Assignee__c);
            System.assertEquals(0, Atlas_Tickets.getTicket(story.Id).pendingCount);
            try {
                Atlas_Tickets.completeUpdatePart(story.Id, 'missing', 'comment:0', true, Atlas_Tickets.getTicket(story.Id).version);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('no longer exists'));
            }
            try {
                apply('{"updates":[{"target":"DEMO-404","comments":"x"}]}');
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('No ticket DEMO-404'));
            }
            // Finished history is retained; the separate overflow test checks Files storage.
        }
    }

    @IsTest
    static void aCaseOnlyEditSinceTheProposalIsStillABaselineConflict() {
        System.assert(Atlas_Tickets.sameValue('Ready', 'Ready'));
        System.assert(!Atlas_Tickets.sameValue('Ready', 'READY'));
        System.assert(Atlas_Tickets.sameValue(null, null));
        System.assert(Atlas_Tickets.sameValue(new Map<String, Object>{'a' => 'x', 'n' => 1}, new Map<String, Object>{'a' => 'x', 'n' => 1}));
        System.assert(!Atlas_Tickets.sameValue(new Map<String, Object>{'a' => 'x'}, new Map<String, Object>{'a' => 'X'}));
        System.assert(!Atlas_Tickets.sameValue(new Map<String, Object>{'a' => 'x'}, new Map<String, Object>{'b' => 'x'}));
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Original', Jira_Key__c = 'DEMO-93');
            insert ticket;
            Map<String, Object> result = apply('{"updates":[{"target":"DEMO-93","changes":{"summary":"Proposed"}}]}');
            String updateId = (String) ((Map<String, Object>) ((List<Object>) result.get('updates'))[0]).get('updateId');
            update new Atlas_Ticket__c(Id = ticket.Id, Summary__c = 'ORIGINAL');
            try {
                Atlas_Tickets.completeUpdatePart(ticket.Id, updateId, 'field:summary', true, Atlas_Tickets.getTicket(ticket.Id).version);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Baseline conflict for summary'), e.getMessage());
            }
            System.assertEquals('ORIGINAL', Atlas_Tickets.getTicket(ticket.Id).summary);
            delete ticket;
            try {
                Atlas_Tickets.getTicket(ticket.Id);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('deleted or is not shared'), e.getMessage());
            }
        }
    }

    @IsTest
    static void completedUpdatesCannotReplayOverLaterEdits() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Original', Jira_Key__c = 'DEMO-92');
            insert ticket;
            Map<String, Object> result = apply('{"updates":[{"target":"DEMO-92","changes":{"summary":"First edit"}}]}');
            String updateId = (String) ((Map<String, Object>) ((List<Object>) result.get('updates'))[0]).get('updateId');
            finish(ticket.Id, updateId, true);
            update new Atlas_Ticket__c(Id = ticket.Id, Summary__c = 'Later edit');
            finish(ticket.Id, updateId, true);
            System.assertEquals('Later edit', Atlas_Tickets.getTicket(ticket.Id).summary,
                'A retried completion must not replay old changes over newer work');
        }
    }

    @IsTest
    static void staleImportsCannotOverwriteCurrentTickets() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Newer', Jira_Key__c = 'DEMO-81',
                Stage__c = 'In Jira', Jira_Updated__c = Datetime.newInstanceGmt(2026, 10, 15, 12, 0, 0));
            insert ticket;
            Atlas_Tickets.importJira('[{"key":"DEMO-81","summary":"Older","updated":"2026-10-14T12:00:00.000Z"}]');
            System.assertEquals('Newer', [SELECT Summary__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Summary__c,
                'A stale Jira export must not roll a shared ticket back');
        }
    }

    @IsTest
    static void equalSourceImportsCannotUndoManualConfirmations() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String original = '[{"key":"DEMO-610","summary":"Snapshot title","priority":"Low","updated":"2026-10-14T12:00:00.000Z"}]';
            Atlas_Tickets.importJira(original);
            Id id = [SELECT Id FROM Atlas_Ticket__c WHERE Jira_Key__c = 'DEMO-610'].Id;
            apply('{"updates":[{"target":"DEMO-610","changes":{"summary":"Confirmed in Jira","priority":"High"}}]}');
            String updateId = (String)((Map<String,Object>)Atlas_Tickets.getTicket(id).pendingUpdates[0]).get('id');
            Atlas_Tickets.completeUpdatePart(id, updateId, 'field:summary', true, Atlas_Tickets.getTicket(id).version);
            Map<String,Object> row = (Map<String,Object>)((List<Object>)JSON.deserializeUntyped(original))[0];
            row.put('expectedVersion', Atlas_Tickets.getTicket(id).version);
            Id manifest = (Id)Atlas_Tickets.beginImport('["DEMO-610"]');
            String request = JSON.serialize(new Map<String,Object>{'manifestId'=>manifest,'chunk'=>0,'rows'=>new List<Object>{row}});
            Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Tickets.importJira(request));
            System.assertEquals(1, result.get('stale'), 'A new review of the same source snapshot is still stale after confirmation.');
            Atlas_Tickets.Ticket loaded = Atlas_Tickets.getTicket(id);
            System.assertEquals('Confirmed in Jira', loaded.summary);
            System.assertEquals('done', ((Map<String,Object>)((Map<String,Object>)loaded.pendingUpdates[0]).get('fieldStatus')).get('summary'));
            System.assertEquals(1, loaded.pendingCount, 'Independent pending parts remain available.');
            System.assertEquals(result.get('receiptId'), ((Map<String,Object>)JSON.deserializeUntyped(Atlas_Tickets.importJira(request))).get('receiptId'));
            Atlas_Tickets.importJira('[{"key":"DEMO-610","summary":"Genuinely newer","priority":"Low","updated":"2026-10-15T12:00:00.000Z"}]');
            System.assertEquals('Genuinely newer', Atlas_Tickets.getTicket(id).summary);
            Atlas_Tickets.completeUpdatePart(id, updateId, 'field:priority', true, Atlas_Tickets.getTicket(id).version);
            Atlas_Tickets.importJira('[{"key":"DEMO-610","priority":"Low","updated":"2026-10-15T12:00:00.000Z"}]');
            System.assertEquals('High', Atlas_Tickets.getTicket(id).priority, 'A later confirmation pins its new source baseline too.');
        }
    }

    @IsTest
    static void undatedImportsCannotUndoUndatedConfirmations() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Tickets.importJira('[{"key":"DEMO-611","summary":"Original"}]');
            Id id = [SELECT Id FROM Atlas_Ticket__c].Id;
            Map<String,Object> queued = apply('{"updates":[{"target":"DEMO-611","changes":{"summary":"Confirmed"}}]}');
            finish(id, (String)((Map<String,Object>)((List<Object>)queued.get('updates'))[0]).get('updateId'), true);
            Atlas_Tickets.importJira('[{"key":"DEMO-611","summary":"Original"}]');
            System.assertEquals('Confirmed', Atlas_Tickets.getTicket(id).summary);
            Atlas_Tickets.importJira('[{"key":"DEMO-611","summary":"Dated snapshot","updated":"2026-10-15T12:00:00.000Z"}]');
            System.assertEquals('Dated snapshot', Atlas_Tickets.getTicket(id).summary);
        }
    }

    @IsTest
    static void preMarkerChecklistHistoryProtectsItsSourceWithoutBlockingNewSnapshots() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String original = '[{"key":"DEMO-613","summary":"Original","updated":"2026-10-14T12:00:00.000Z"}]';
            Atlas_Tickets.importJira(original);
            Id id = [SELECT Id FROM Atlas_Ticket__c].Id;
            Map<String,Object> queued = apply('{"updates":[{"target":"DEMO-613","changes":{"summary":"Confirmed"}}]}');
            finish(id, (String)((Map<String,Object>)((List<Object>)queued.get('updates'))[0]).get('updateId'), true);
            // Retain the real checklist/history, but use the persisted shape from
            // before source-baseline tracking was introduced.
            Map<String,Object> p = Atlas_Tickets.getTicket(id).planning;
            p.remove('manualConfirmationBaseline');
            ((Map<String,Object>)p.get('lastImport')).remove('confirmationBaselineTracked');
            update new Atlas_Ticket__c(Id=id, Planning__c=JSON.serialize(p));
            System.assertEquals(1, ((Map<String,Object>)JSON.deserializeUntyped(Atlas_Tickets.importJira(original))).get('stale'));
            System.assertEquals('Confirmed', Atlas_Tickets.getTicket(id).summary);
            Atlas_Tickets.importJira('[{"key":"DEMO-613","summary":"Newer snapshot","updated":"2026-10-15T12:00:00.000Z"}]');
            Atlas_Tickets.importJira('[{"key":"DEMO-613","summary":"Enriched equal snapshot","updated":"2026-10-15T12:00:00.000Z"}]');
            System.assertEquals('Enriched equal snapshot', Atlas_Tickets.getTicket(id).summary,
                'Equal-source enrichment is still allowed once a genuinely newer import supersedes the confirmation.');
        }
    }

    @IsTest
    static void importsDoNotGuessBetweenDuplicateDrafts() {
        System.runAs(Atlas_Mock.atlasUser()) {
            insert new List<Atlas_Ticket__c>{
                new Atlas_Ticket__c(Summary__c = 'Same title', Issue_Type__c = 'Task', Project_Key__c = 'DEMO', Stage__c = 'Exported'),
                new Atlas_Ticket__c(Summary__c = 'Same title', Issue_Type__c = 'Task', Project_Key__c = 'DEMO', Stage__c = 'Exported')
            };
            try {
                Atlas_Tickets.importJira('[{"key":"DEMO-89","summary":"Same title","issueType":"Task","project":"DEMO"}]');
                System.assert(false, 'Ambiguity requires explicit review, not an automatic new duplicate');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('Ambiguous')); }
            Atlas_Tickets.importJira('[{"key":"DEMO-89","summary":"Same title","issueType":"Task","project":"DEMO","resolution":"new"}]');
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Ticket__c WHERE Jira_Key__c = null],
                'Ambiguous matches must leave both drafts untouched');
        }
    }

    @IsTest
    static void staleBoardEditsCannotOverwriteATeammate() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Teammate edit', Stage__c = 'Draft');
            insert ticket;
            try {
                Atlas_Tickets.saveTicket('{"id":"' + ticket.Id + '","summary":"Stale edit","expectedVersion":"old"}');
                System.assert(false, 'A stale editor must reload instead of overwriting the team');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('changed'), e.getMessage());
            }
            System.assertEquals('Teammate edit', [SELECT Summary__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Summary__c);
        }
    }

    @IsTest
    static void importsExplicitFieldValuesWithoutKeepingOldEpicLinks() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c epic = new Atlas_Ticket__c(Summary__c = 'Epic', Issue_Type__c = 'Epic', Jira_Key__c = 'DEMO-90');
            insert epic;
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Task', Jira_Key__c = 'DEMO-91',
                Description__c = 'Old description', Epic__c = epic.Id, Epic_Key__c = 'DEMO-90');
            insert ticket;
            Atlas_Tickets.importJira('[{"key":"DEMO-91","description":"New description","epicKey":""}]');
            Atlas_Tickets.Ticket imported = Atlas_Tickets.getTicket(ticket.Id);
            System.assertEquals('New description', imported.description);
            System.assertEquals(null, imported.epicId, 'An explicit empty Epic Link removes the old relationship');
            System.assertEquals(null, imported.epicKey);
        }
    }

    @IsTest
    static void importsJiraExports() {
        System.runAs(Atlas_Mock.atlasUser()) {
            apply(batch());
            Atlas_Ticket__c epic = [SELECT Id FROM Atlas_Ticket__c WHERE Issue_Type__c = 'Epic'];
            stage(epic.Id, 'Exported', 'b1');
            save('{"id":"' + [SELECT Id FROM Atlas_Ticket__c WHERE Summary__c = 'Unassigned chore'].Id + '","jiraKey":"DEMO-3"}');
            String rows = '[{"key":"demo-1","summary":"Self-service","issueType":"Epic","status":"In Review","statusCategory":"In Progress","project":"DEMO",'
                + '"updated":"2026-10-10T09:30:00.000Z","assigneeJiraId":"jira-me","epicName":"Self-service"},'
                + '{"key":"DEMO-2","summary":"Build the form","issueType":"Story","epicKey":"DEMO-1","dueDate":"2026-11-03","assigneeJiraId":"jira-robin","priority":"High"},'
                + '{"key":"DEMO-3","summary":"Chore","issueType":"Task","dueDate":"","statusCategory":"Done"},'
                + '{"key":"DEMO-4","summary":"Made in Jira","issueType":"Bug","epicKey":"DEMO-1"}]';
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Tickets.importJira(rows));
            System.assertEquals(1, result.get('matchedByKey'));
            System.assertEquals(2, result.get('matchedDrafts'));
            System.assertEquals(1, result.get('created'));
            Atlas_Ticket__c bug = [SELECT Epic__c, Stage__c FROM Atlas_Ticket__c WHERE Jira_Key__c = 'DEMO-4'];
            System.assertEquals(epic.Id, bug.Epic__c);
            System.assertEquals('In Jira', bug.Stage__c);
            Atlas_Ticket__c story = [SELECT Jira_Key__c, Due_Date__c FROM Atlas_Ticket__c WHERE Summary__c = 'Build the form'];
            System.assertEquals('DEMO-2', story.Jira_Key__c);
            System.assertEquals(Date.newInstance(2026, 11, 3), story.Due_Date__c);
            System.assertEquals(3, Atlas_Tickets.forConversation(conversation()).size());
            try {
                Atlas_Tickets.importJira('[{"key":"DEMO-9","dueDate":"not a date"}]');
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c WHERE Jira_Key__c = 'DEMO-9']);
            }
        }
    }

    @IsTest
    static void boardPagesCountPendingUpdatesWithoutReadingCurrentHistories() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c legacy = new Atlas_Ticket__c(Summary__c = 'Legacy history',
                Pending_Updates__c = '[{"status":"pending"},{"status":"pending"},{"status":"applied"}]');
            Atlas_Ticket__c current = new Atlas_Ticket__c(Summary__c = 'Counted history', Planning__c = '{"pendingCount":1}',
                Pending_Updates__c = '[{"status":"pending"},{"status":"pending"},{"status":"pending"}]');
            insert new List<Atlas_Ticket__c>{ legacy, current };
            Test.startTest();
            Map<Id, Atlas_Tickets.Ticket> board = new Map<Id, Atlas_Tickets.Ticket>();
            for (Atlas_Tickets.Ticket t : Atlas_Tickets.boardPage(false, null, 200).tickets) board.put(t.id, t);
            Test.stopTest();
            System.assertEquals(2, board.get(legacy.Id).pendingCount, 'Tickets saved before the stored count still count their history.');
            System.assertEquals(1, board.get(current.Id).pendingCount, 'The stored count is used; the history body is not read.');
            System.assertEquals(null, board.get(current.Id).pendingUpdates);
            for (Id id : board.keySet()) System.assertEquals(Atlas_Tickets.getTicket(id).version, board.get(id).version,
                'A board row and the full ticket must agree on the version used for safe saves.');
        }
    }
}
