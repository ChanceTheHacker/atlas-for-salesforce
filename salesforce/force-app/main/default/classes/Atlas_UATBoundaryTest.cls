@IsTest
private class Atlas_UATBoundaryTest {
    static Map<String, Object> intake(String componentType) {
        return new Map<String, Object>{'componentType' => componentType, 'apiName' => 'Order_Flow',
            'goal' => 'Verify that the approved order path handles valid and invalid values.',
            'testing' => componentType == 'Other' ? 'Run the documented QA steps and capture the result.' : ''};
    }

    static Id uatConversation(String request) {
        return (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String, Object>{
            'title' => 'Order checkout UAT', 'mode' => 'uat', 'request' => request, 'uat' => intake('Flow')
        }));
    }

    @IsTest
    static void uatIntakeIsLosslessVersionedAndModeImmutable() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String request = 'Check the end-to-end checkout path. ';
            for (Integer i = 0; i < 150; i++) request += 'Context ';
            Map<String, Object> details = intake('Flow');
            Id id = (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String, Object>{
                'title' => 'Order checkout UAT', 'mode' => 'uat', 'request' => request, 'uat' => details
            }));
            Atlas_Conversation__c saved = [SELECT Mode__c, Request__c, Request_File__c FROM Atlas_Conversation__c WHERE Id = :id];
            System.assertEquals('uat', saved.Mode__c);
            System.assertNotEquals(null, saved.Request_File__c, 'The complete versioned envelope should use the existing request File for long intake.');
            String raw = [SELECT VersionData FROM ContentVersion WHERE Id = :saved.Request_File__c].VersionData.toString();
            Map<String, Object> envelope = (Map<String, Object>)JSON.deserializeUntyped(raw);
            System.assertEquals('atlas-uat-intake', envelope.get('type'));
            System.assertEquals('1', String.valueOf(envelope.get('version')));
            System.assertEquals(request, envelope.get('request'));
            Map<String, Object> storedDetails = (Map<String, Object>)envelope.get('uat');
            System.assertEquals('Flow', storedDetails.get('componentType'));
            System.assertEquals('Order_Flow', storedDetails.get('apiName'));
            System.assertEquals(details.get('goal'), storedDetails.get('goal'));

            Map<String, Object> response = (Map<String, Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(id));
            System.assertEquals(request, response.get('request'), 'The browser receives the plain request, not the storage envelope.');
            System.assertEquals('Flow', ((Map<String, Object>)response.get('uat')).get('componentType'));
            System.assertEquals('Order_Flow', ((Map<String, Object>)response.get('uat')).get('apiName'));

            Atlas_Data.saveConversation(JSON.serialize(new Map<String, Object>{'id' => id, 'request' => 'Clarified checkout scope.'}));
            response = (Map<String, Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(id));
            System.assertEquals('Clarified checkout scope.', response.get('request'));
            System.assertEquals('Flow', ((Map<String, Object>)response.get('uat')).get('componentType'), 'Saving a request without nested UAT data must preserve the prior intake.');
            System.assertEquals('Order_Flow', ((Map<String, Object>)response.get('uat')).get('apiName'));

            try {
                Atlas_Data.saveConversation(JSON.serialize(new Map<String, Object>{'id' => id, 'mode' => 'Source'}));
                System.assert(false, 'A saved UAT conversation cannot change modes.');
            } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('cannot change modes')); }
            System.assert(Atlas_Data.isUATConversation(id));
            System.assertEquals(false, Atlas_Data.isUATConversation(null));
            System.assertEquals(false, Atlas_Data.isSupportTicketsConversation(null));
            Atlas_Data.assertSourceChangesAllowed(null);
            Id defaultMode = (Id)Atlas_Data.saveConversation('{"title":"No explicit mode"}');
            System.assertEquals('Task', Atlas_Data.conversationMode(defaultMode), 'A missing mode keeps Salesforce’s existing Task default.');
            String reservedEnvelope = '{"type":"atlas-uat-intake","version":99,"request":"not the original request","uat":{}}';
            Id sourceMode = (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title'=>'Source JSON review','mode'=>'Source','request'=>reservedEnvelope}));
            Map<String,Object> sourceResponse = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(sourceMode));
            System.assertEquals(reservedEnvelope, sourceResponse.get('request'), 'Non-UAT requests that resemble an envelope stay literal.');

            Map<String, Object> invalid = new Map<String, Object>{'title' => 'Invalid UAT', 'mode' => 'uat', 'request' => 'Test this.',
                'uat' => new Map<String, Object>{'componentType' => 'Other', 'apiName' => 'Unknown', 'goal' => 'Check this', 'testing' => ''}};
            try { Atlas_Data.saveConversation(JSON.serialize(invalid)); System.assert(false, 'Other components need testing instructions.'); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('testing instructions')); }
            String oversized = 'x'.repeat(30001);
            Map<String,Object> rejected = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.startConversationChecked(
                JSON.serialize(new Map<String,Object>{'title'=>'Oversized UAT','mode'=>'uat','request'=>oversized,'uat'=>intake('Flow')}), 'Initial QA request', 'uat-too-large'));
            System.assertEquals('ATLAS_START_INPUT_REJECTED', rejected.get('code'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Conversation__c WHERE Mode__c = 'uat'], 'Invalid UAT starts must create no conversation.');
        }
    }

    @IsTest
    static void uatBlocksSourceChangesCaseAssignmentsAndQueuedDeployments() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = uatConversation('Check the production-like QA path.');
            Integer calls = Limits.getCallouts();
            try { Atlas_Changes.startBackup(id, null, 'No source backup', '[{"type":"ApexClass","name":"Example"}]'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            try { Atlas_Assignments.prepare(id, '[]'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            try { Atlas_Assignments.decide(id, '[]', true, 'Approve', 'uat-case-approval'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }

            Atlas_Change__c proposal = new Atlas_Change__c(Conversation__c = id, Status__c = 'Proposed', Revision__c = 1);
            insert as user proposal;
            try { Atlas_Changes.propose(proposal.Id, '{}'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            try { Atlas_Changes.decide(proposal.Id, 1, true, null, 'Default'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            try { Atlas_Changes.startRestore(proposal.Id, '[]', 'Default', false, '{}'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(calls, Limits.getCallouts(), 'Rejected UAT requests must not call Salesforce source APIs.');

            for (String status : new List<String>{'Deploying', 'Restoring'}) {
                Atlas_Change__c queued = new Atlas_Change__c(Conversation__c = id, Status__c = status, Revision__c = 1);
                insert as user queued;
                Atlas_Changes.executeDeployment(queued.Id, null, 0);
                Atlas_Change__c result = [SELECT Status__c, Result__c, Deploy_Id__c FROM Atlas_Change__c WHERE Id = :queued.Id];
                System.assertEquals('Failed', result.Status__c);
                System.assert(result.Result__c.contains('UAT'));
                System.assertEquals(null, result.Deploy_Id__c);
            }
            System.assertEquals(calls, Limits.getCallouts(), 'Queued UAT deploy and restore jobs must stop before callouts.');
        }
    }

    @IsTest
    static void uatBlocksTicketMutationsImportsAndRecovery() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = uatConversation('Test the order flow with a QA account.');
            String batch = '{"projectKey":"DEMO","tickets":[{"ref":"UAT-1","issueType":"Task","summary":"UAT proposal","description":"QA only"}]}';
            try { Atlas_Tickets.prepareBatch(conversationId, batch); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            try { Atlas_Tickets.applyBatch(conversationId, batch); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Ticket__c WHERE Conversation__c = :conversationId]);

            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Before import', Issue_Type__c = 'Task',
                Jira_Key__c = 'DEMO-100', Project_Key__c = 'DEMO', Stage__c = 'In Jira', Origin_Key__c = String.valueOf(conversationId) + ':UAT-100',
                Conversation__c = conversationId, Import_Revision__c = 0);
            insert as user ticket;
            try { Atlas_Tickets.importJira('[{"key":"DEMO-100","summary":"After import","issueType":"Task"}]'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals('Before import', [SELECT Summary__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Summary__c);

            String legacyWorkspace = 'legacy-uattest-workspace', legacyId = 'legacy-uattest-ticket';
            String legacyOrigin = 'legacy:' + Atlas_Api.sha256(Blob.valueOf(JSON.serialize(new List<String>{legacyWorkspace,legacyId})));
            Atlas_Ticket__c legacyTicket = new Atlas_Ticket__c(Summary__c='Legacy UAT ticket', Issue_Type__c='Task',
                Project_Key__c='DEMO', Stage__c='In Jira', Jira_Key__c='DEMO-101', Origin_Key__c=legacyOrigin,
                Conversation__c=conversationId, Planning__c='{}');
            insert as user legacyTicket;
            String legacyBatch = JSON.serialize(new Map<String,Object>{'workspaceId'=>legacyWorkspace,'phase'=>'links',
                'items'=>new List<Object>{new Map<String,Object>{'id'=>legacyId,'blockedBy'=>new List<Object>()}}});
            try { Atlas_Tickets.importLegacy(legacyBatch); System.assert(false, 'Legacy link migration cannot change UAT-linked tickets.'); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals('{}',[SELECT Planning__c FROM Atlas_Ticket__c WHERE Id=:legacyTicket.Id].Planning__c);

            Atlas_Tickets.Ticket dto = Atlas_Tickets.getTicket(ticket.Id);
            try {
                Atlas_Tickets.saveTicket(JSON.serialize(new Map<String, Object>{'id' => ticket.Id, 'expectedVersion' => dto.version, 'summary' => 'Direct edit'}));
                System.assert(false, 'Direct ticket edits must use the persisted conversation mode.');
            } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals('Before import', [SELECT Summary__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Summary__c);
            Atlas_Tickets.Ticket ticketDto = Atlas_Tickets.getTicket(ticket.Id);
            try {
                Atlas_Tickets.completeUpdatePart(ticket.Id, 'UAT-block', 'field:summary', true, ticketDto.version);
                System.assert(false, 'UAT-linked Jira checklist items cannot be completed.');
            } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }

            Id taskConversationId = (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title'=>'Ordinary task mode','mode'=>'Task'}));
            String pendingBefore = [SELECT Pending_Updates__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Pending_Updates__c;
            Map<String,Object> updateBatch = new Map<String,Object>{'projectKey'=>'DEMO','updates'=>new List<Object>{new Map<String,Object>{
                'target'=>'DEMO-100','reason'=>'Review a proposed summary correction.','changes'=>new Map<String,Object>{'summary'=>'Task-mode edit'}}}};
            String prepared = Atlas_Tickets.prepareBatch(taskConversationId, JSON.serialize(updateBatch));
            try { Atlas_Tickets.applyBatch(taskConversationId, prepared); System.assert(false, 'A Task batch cannot change a UAT-linked ticket.'); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(pendingBefore, [SELECT Pending_Updates__c FROM Atlas_Ticket__c WHERE Id = :ticket.Id].Pending_Updates__c);

            Map<String,Object> archive = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Library.saveEntry(null,
                'Atlas UAT recovery source', 'workspace', 0, '{"type":"atlas-native-workspace","version":1}'));
            String source = JSON.serialize(new Map<String, Object>{'type' => 'Atlas_Ticket__c', 'id' => String.valueOf(ticket.Id),
                'values' => new Map<String, Object>{'Conversation__c' => String.valueOf(conversationId)}});
            Map<String,Object> recoveryReferences = new Map<String,Object>{String.valueOf(conversationId)=>String.valueOf(conversationId)};
            try { Atlas_WorkspaceRecovery.prepareRecord((Id)archive.get('id'), (Id)archive.get('versionId'), source, '{}', JSON.serialize(recoveryReferences)); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Library__c WHERE Name LIKE 'Atlas native recovery %']);
        }
    }

    @IsTest
    static void recoveryChecksMappedTicketDestinationAtPrepareAndApply() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id sourceTask = (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title'=>'Source Task conversation','mode'=>'Task'}));
            Id mappedTask = (Id)Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title'=>'Destination Task conversation','mode'=>'Task'}));
            Id mappedUat = uatConversation('Verify the mapped recovery destination.');
            Map<String,Object> archive = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Library.saveEntry(null,
                'Atlas UAT mapping test archive', 'workspace', 0, '{"type":"atlas-native-workspace","version":1}'));
            Map<String,Object> values = new Map<String,Object>{'Origin_Key__c'=>'foreign-ticket:1','Conversation__c'=>String.valueOf(sourceTask),
                'Summary__c'=>'Recovered QA ticket','Description__c'=>'Evidence retained from another organization.','Issue_Type__c'=>'Task',
                'Project_Key__c'=>'DEMO','Stage__c'=>'Draft'};
            String source = JSON.serialize(new Map<String,Object>{'type'=>'Atlas_Ticket__c','id'=>'portable-ticket-id','values'=>values});

            Map<String,Object> uatReferences = new Map<String,Object>{String.valueOf(sourceTask)=>String.valueOf(mappedUat)};
            try {
                Atlas_WorkspaceRecovery.prepareRecord((Id)archive.get('id'),(Id)archive.get('versionId'),source,'{}',JSON.serialize(uatReferences));
                System.assert(false,'A Task-mode source cannot be restored into a UAT-linked ticket.');
            } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(0,[SELECT COUNT() FROM Atlas_Library__c WHERE Name LIKE 'Atlas native recovery %']);

            String foreignConversationId = 'conversation-from-another-org';
            values.put('Conversation__c',foreignConversationId);
            source = JSON.serialize(new Map<String,Object>{'type'=>'Atlas_Ticket__c','id'=>'portable-ticket-id','values'=>values});
            Map<String,Object> allowedReferences = new Map<String,Object>{foreignConversationId=>String.valueOf(mappedTask)};
            Map<String,Object> prepared = (Map<String,Object>)JSON.deserializeUntyped(Atlas_WorkspaceRecovery.prepareRecord(
                (Id)archive.get('id'),(Id)archive.get('versionId'),source,'{}',JSON.serialize(allowedReferences)));
            Map<String,Object> review = (Map<String,Object>)JSON.deserializeUntyped(Atlas_WorkspaceRecovery.reviewRecord((Id)prepared.get('id')));
            Map<String,Object> projected = (Map<String,Object>)review.get('fields');
            System.assertEquals(String.valueOf(mappedTask),String.valueOf(projected.get('Conversation__c')));
            System.assertEquals(0,((List<Object>)review.get('conflicts')).size(), 'A missing cross-org source ID is valid when its destination is accessible and allowed.');

            update new Atlas_Conversation__c(Id=mappedTask,Mode__c='uat');
            try {
                Atlas_WorkspaceRecovery.applyRecord((Id)prepared.get('id'),(Id)review.get('versionId'),(String)review.get('digest'));
                System.assert(false,'Apply must recheck the currently mapped destination mode.');
            } catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('UAT')); }
            System.assertEquals(0,[SELECT COUNT() FROM Atlas_Ticket__c WHERE Origin_Key__c='foreign-ticket:1']);
        }
    }
}
