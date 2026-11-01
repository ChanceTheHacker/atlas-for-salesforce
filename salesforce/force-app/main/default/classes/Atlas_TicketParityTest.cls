@IsTest
private class Atlas_TicketParityTest {
    static Map<String,Object> parsed(String raw) { return (Map<String,Object>)JSON.deserializeUntyped(raw); }
    static Map<String,Object> apply(Id conversation, String raw) {
        return parsed(Atlas_Tickets.applyBatch(conversation, Atlas_Tickets.prepareBatch(conversation, raw)));
    }
    static String exportInput(Id ticket, String phase) {
        return JSON.serialize(new Map<String,Object>{'phase'=>phase, 'batch'=>'reviewed', 'csv'=>'Summary\r\n"Exact CSV"\r\n',
            'versions'=>new Map<Id,String>{ticket=>Atlas_Tickets.getTicket(ticket).version}});
    }

    @IsTest
    static void planningIsIndependentAndBoardPagesHaveNoSilentCap() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<Atlas_Ticket__c> rows = new List<Atlas_Ticket__c>();
            for (Integer i=0;i<205;i++) rows.add(new Atlas_Ticket__c(Summary__c='Ticket '+i, Stage__c='Draft', Jira_Status__c='Open'));
            insert rows;
            Atlas_Tickets.BoardPage first = Atlas_Tickets.boardPage(false,null,200);
            System.assertEquals(200,first.tickets.size());
            System.assertEquals(5,Atlas_Tickets.boardPage(false,first.nextCursor,200).tickets.size());
            try { Atlas_Tickets.board(false); System.assert(false); }
            catch (Atlas_Api.AtlasException e) { System.assert(e.getMessage().contains('complete')); }
            Id id = rows[0].Id;
            Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>id, 'expectedVersion'=>Atlas_Tickets.getTicket(id).version,
                'planning'=>new Map<String,Object>{'lane'=>'Blocked','blockerNote'=>'Waiting for review','dependencies'=>new List<Id>{rows[1].Id}, 'followUp'=>'2026-11-02','snooze'=>'2026-11-01'}}));
            Atlas_Tickets.Ticket ticket = Atlas_Tickets.getTicket(id);
            System.assertEquals('Blocked',ticket.planning.get('lane'));
            System.assertEquals('Open',ticket.jiraStatus);
            try { Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>id,'expectedVersion'=>ticket.version,'planning'=>new Map<String,Object>{'lane'=>'Not a lane'}})); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('planning lane')); }
            try { Atlas_Tickets.setStage(new List<Id>{id},'Exported','unsafe','{}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('exact saved CSV')); }
        }
    }

    @IsTest
    static void exactExportsPersistBeforeStagesAndChildrenNeedConfirmedParents() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c epic = new Atlas_Ticket__c(Summary__c='Parent', Issue_Type__c='Epic', Project_Key__c='DEMO', Stage__c='Draft');
            insert epic;
            Atlas_Ticket__c child = new Atlas_Ticket__c(Summary__c='Child', Issue_Type__c='Story', Project_Key__c='DEMO', Stage__c='Draft', Epic__c=epic.Id);
            insert child;
            try { Atlas_Tickets.saveExport(exportInput(child.Id,'children')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Unresolved parent')); }
            System.assertEquals('Draft',Atlas_Tickets.getTicket(child.Id).stage);
            Map<String,Object> exported = parsed(Atlas_Tickets.saveExport(exportInput(epic.Id,'epics')));
            Id fileId = (Id)exported.get('fileId');
            System.assertEquals('Summary\r\n"Exact CSV"\r\n',[SELECT VersionData FROM ContentVersion WHERE Id=:fileId].VersionData.toString());
            System.assertEquals('Exported',Atlas_Tickets.getTicket(epic.Id).stage);
            update new Atlas_Ticket__c(Id=epic.Id,Jira_Key__c='DEMO-1',Stage__c='In Jira');
            try { Atlas_Tickets.saveExport(exportInput(child.Id,'children')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Epic key changed')); }
            Map<String,Object> ready = parsed(exportInput(child.Id,'children'));
            ready.put('parentKeys',new Map<Id,String>{child.Id=>'DEMO-1'});
            Atlas_Tickets.saveExport(JSON.serialize(ready));
            System.assertEquals('Exported',Atlas_Tickets.getTicket(child.Id).stage);
            try { Atlas_Tickets.saveExport(exportInput(child.Id,'children')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Only uncreated')); }
            Atlas_Tickets.saveExport(exportInput(child.Id,'snapshot'));
            System.assertEquals('Exported',Atlas_Tickets.getTicket(child.Id).stage);
            Map<String,Object> history = parsed(Atlas_Tickets.ticketFiles(child.Id,null));
            System.assertEquals(4,((List<Object>)history.get('files')).size());
        }
    }

    @IsTest
    static void archiveRoundTripsPreserveCreationExportHistory() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c='Already exported', Issue_Type__c='Epic', Stage__c='Draft');
            insert ticket;
            String input = exportInput(ticket.Id, 'epics');
            Map<String,Object> receipt = parsed(Atlas_Tickets.saveExport(input));
            Atlas_Tickets.Ticket exported = Atlas_Tickets.getTicket(ticket.Id);
            for (String stage : new List<String>{'Archived','Archived','Draft'}) {
                Atlas_Tickets.setStage(new List<Id>{ticket.Id}, stage, null,
                    JSON.serialize(new Map<Id,String>{ticket.Id=>Atlas_Tickets.getTicket(ticket.Id).version}));
            }
            Atlas_Tickets.Ticket restored = Atlas_Tickets.getTicket(ticket.Id);
            System.assertEquals('Exported', restored.stage, 'Unarchive cannot make an exported ticket uncreated.');
            System.assertEquals(exported.exportedAt, restored.exportedAt);
            System.assertEquals(exported.exportFileId, restored.exportFileId);
            System.assertEquals(exported.planning.get('latestExportReceipt'), restored.planning.get('latestExportReceipt'));
            Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>ticket.Id,'expectedVersion'=>restored.version,'stage'=>'Draft'}));
            System.assertEquals('Exported', Atlas_Tickets.getTicket(ticket.Id).stage, 'The editor cannot bypass the lifecycle safeguard.');
            try { Atlas_Tickets.saveExport(exportInput(ticket.Id, 'epics')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Only uncreated')); }
            System.assertEquals(receipt, parsed(Atlas_Tickets.saveExport(input)), 'The original CSV remains safely replayable.');
            // Protect records archived before pre-archive lifecycle tracking existed too.
            update new Atlas_Ticket__c(Id=ticket.Id, Stage__c='Archived', Planning__c='{}');
            Atlas_Tickets.setStage(new List<Id>{ticket.Id}, 'Draft', null,
                JSON.serialize(new Map<Id,String>{ticket.Id=>Atlas_Tickets.getTicket(ticket.Id).version}));
            System.assertEquals('Exported', Atlas_Tickets.getTicket(ticket.Id).stage);
            update new Atlas_Ticket__c(Id=ticket.Id, Stage__c='Draft');
            try { Atlas_Tickets.saveExport(exportInput(ticket.Id, 'epics')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Only uncreated')); }
            System.assertEquals(2, [SELECT COUNT() FROM ContentVersion], 'No replacement export or receipt is created.');
        }
    }

    @IsTest
    static void ordinaryArchiveRoundTripsKeepDraftAndJiraStates() {
        System.runAs(Atlas_Mock.atlasUser()) {
            for (String stage : new List<String>{'Draft','In Jira'}) {
                Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c=stage, Stage__c=stage, Jira_Key__c=stage == 'In Jira' ? 'DEMO-612' : null);
                insert ticket;
                Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>ticket.Id,'expectedVersion'=>Atlas_Tickets.getTicket(ticket.Id).version,'stage'=>'Archived'}));
                Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>ticket.Id,'expectedVersion'=>Atlas_Tickets.getTicket(ticket.Id).version,'stage'=>'Draft'}));
                System.assertEquals(stage, Atlas_Tickets.getTicket(ticket.Id).stage);
            }
        }
    }

    @IsTest
    static void archivedDraftAndExportedSavesHonorNewJiraKeysAndBlockAgentRevision() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name='Unarchive with confirmed Jira keys'); insert conversation;
            Integer fixtureIndex = 700;
            for (String originalStage : new List<String>{'Draft','Exported'}) {
                String original = JSON.serialize(new Map<String,Object>{'projectKey'=>'DEMO','tickets'=>new List<Object>{
                    new Map<String,Object>{'ref'=>originalStage,'summary'=>'Original ' + originalStage,'issueType'=>'Task'}
                }});
                Map<String,Object> created = apply(conversation.Id, original);
                Id id = (Id)((Map<String,Object>)((List<Object>)created.get('saved'))[0]).get('id');
                if (originalStage == 'Exported') Atlas_Tickets.saveExport(exportInput(id, 'children'));
                Atlas_Tickets.Ticket before = Atlas_Tickets.getTicket(id);
                Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>id,'expectedVersion'=>before.version,'stage'=>'Archived'}));
                Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>id,'expectedVersion'=>Atlas_Tickets.getTicket(id).version,
                    'jiraKey'=>' demo-' + fixtureIndex + ' ','stage'=>'In Jira'}));
                Atlas_Tickets.Ticket saved = Atlas_Tickets.getTicket(id);
                System.assertEquals('In Jira', saved.stage, 'A new key supplied during unarchive is the effective lifecycle authority.');
                System.assertEquals('DEMO-' + fixtureIndex, saved.jiraKey);
                System.assertEquals(before.exportedAt, saved.exportedAt);
                System.assertEquals(before.exportFileId, saved.exportFileId);
                System.assertEquals(before.planning.get('latestExportReceipt'), saved.planning.get('latestExportReceipt'));
                System.assert(!saved.planning.containsKey('preArchiveStage'));
                try {
                    apply(conversation.Id, original.replace('Original ', 'Agent replacement '));
                    System.assert(false, 'The same ref cannot revise a ticket that is now in Jira.');
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains('has left Draft (it is In Jira)'), e.getMessage());
                    System.assert(e.getMessage().contains('send an update'), e.getMessage());
                }
                System.assertEquals(saved.version, Atlas_Tickets.getTicket(id).version);
                fixtureIndex++;
            }
        }
    }

    @IsTest
    static void archivedSaveDistinguishesOmittedAndClearedJiraKeyPatches() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c='Preserve export history', Issue_Type__c='Epic', Stage__c='Draft'); insert ticket;
            Atlas_Tickets.saveExport(exportInput(ticket.Id, 'epics'));
            Atlas_Tickets.Ticket exported = Atlas_Tickets.getTicket(ticket.Id);
            for (String patch : new List<String>{'omitted','null','empty','whitespace','bulk'}) {
                update new Atlas_Ticket__c(Id=ticket.Id, Stage__c='Archived', Jira_Key__c='DEMO-712', Planning__c=JSON.serialize(exported.planning));
                Atlas_Tickets.Ticket archived = Atlas_Tickets.getTicket(ticket.Id);
                if (patch == 'bulk') Atlas_Tickets.setStage(new List<Id>{ticket.Id}, 'Draft', null, JSON.serialize(new Map<Id,String>{ticket.Id=>archived.version}));
                else {
                    Map<String,Object> edit = new Map<String,Object>{'id'=>ticket.Id,'expectedVersion'=>archived.version,'stage'=>'Draft'};
                    if (patch != 'omitted') edit.put('jiraKey', patch == 'null' ? null : patch == 'empty' ? '' : ' ');
                    Atlas_Tickets.saveTicket(JSON.serialize(edit));
                }
                Atlas_Tickets.Ticket saved = Atlas_Tickets.getTicket(ticket.Id);
                Boolean retained = patch == 'omitted' || patch == 'bulk';
                System.assertEquals(retained ? 'DEMO-712' : null, saved.jiraKey, patch);
                System.assertEquals(retained ? 'In Jira' : 'Exported', saved.stage, patch);
                System.assertEquals(exported.exportFileId, saved.exportFileId);
                System.assertEquals(exported.exportedAt, saved.exportedAt);
                System.assertEquals(exported.planning.get('latestExportReceipt'), saved.planning.get('latestExportReceipt'));
                if (!retained) {
                    try { Atlas_Tickets.saveExport(exportInput(ticket.Id, 'epics')); System.assert(false); }
                    catch (AuraHandledException e) { System.assert(e.getMessage().contains('Only uncreated'), e.getMessage()); }
                }
            }
        }
    }

    @IsTest
    static void unchangedCompositeParentBaselinesAllowChecklistConfirmation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name='Unchanged parent baselines'); insert conversation;
            Atlas_Ticket__c epic = new Atlas_Ticket__c(Summary__c='Parent', Issue_Type__c='Epic', Jira_Key__c='DEMO-720', Stage__c='In Jira'); insert epic;
            Integer fixtureIndex = 721;
            for (String association : new List<String>{'lookup','raw','none'}) {
                Atlas_Ticket__c child = new Atlas_Ticket__c(Summary__c=association, Jira_Key__c='DEMO-' + fixtureIndex, Stage__c='In Jira',
                    Epic__c=association == 'lookup' ? epic.Id : null, Epic_Key__c=association == 'raw' ? 'DEMO-720' : null); insert child;
                apply(conversation.Id, JSON.serialize(new Map<String,Object>{'updates'=>new List<Object>{
                    new Map<String,Object>{'target'=>child.Jira_Key__c,'changes'=>new Map<String,Object>{'epicKey'=>'DEMO-724'}}
                }}));
                Atlas_Tickets.Ticket reviewed = Atlas_Tickets.getTicket(child.Id);
                Map<String,Object> proposal = (Map<String,Object>)reviewed.pendingUpdates[0];
                Map<String,Object> baseline = (Map<String,Object>)((Map<String,Object>)proposal.get('baseline')).get('epicKey');
                System.assertEquals(association == 'lookup' ? epic.Id : null, baseline.get('epicId'));
                System.assertEquals(association == 'raw' ? 'DEMO-720' : null, baseline.get('rawKey'));
                System.assertEquals(association == 'none' ? null : 'DEMO-720', baseline.get('effectiveKey'));
                Atlas_Tickets.completeUpdatePart(child.Id, (String)proposal.get('id'), 'field:epicKey', true, reviewed.version);
                Atlas_Tickets.Ticket saved = Atlas_Tickets.getTicket(child.Id);
                System.assertEquals(null, saved.epicId);
                System.assertEquals('DEMO-724', saved.epicKey);
                System.assertEquals(0, saved.pendingCount);
                Map<String,Object> completed = (Map<String,Object>)saved.pendingUpdates[0];
                System.assertEquals('done', completed.get('status'));
                System.assertEquals('done', ((Map<String,Object>)completed.get('fieldStatus')).get('epicKey'));
                fixtureIndex++;
            }
        }
    }

    @IsTest
    static void exactExportRetriesReuseFilesWithoutRevertingLaterChanges() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c='Replay', Issue_Type__c='Epic', Stage__c='Draft');
            insert ticket;
            String input = exportInput(ticket.Id, 'epics');
            Map<String,Object> first = parsed(Atlas_Tickets.saveExport(input));
            String version = Atlas_Tickets.getTicket(ticket.Id).version;
            System.assertEquals(first, parsed(Atlas_Tickets.saveExport(input)));
            System.assertEquals(version, Atlas_Tickets.getTicket(ticket.Id).version);
            System.assertEquals(2, [SELECT count() FROM ContentVersion]);
            update new Atlas_Ticket__c(Id=ticket.Id, Summary__c='Later teammate edit', Jira_Key__c='DEMO-77', Stage__c='In Jira');
            System.assertEquals(first, parsed(Atlas_Tickets.saveExport(input)));
            System.assertEquals('Later teammate edit', Atlas_Tickets.getTicket(ticket.Id).summary);
            System.assertEquals('In Jira', Atlas_Tickets.getTicket(ticket.Id).stage);
            System.assertEquals(2, [SELECT count() FROM ContentVersion]);
            try { Atlas_Tickets.saveExport(input.replace('Exact CSV','Different CSV')); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().length() > 0); }
        }
    }

    @IsTest
    static void importReceiptsReplayAndUnknownAssigneesRequireDecisions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id manifest = (Id)Atlas_Tickets.beginImport('["DEMO-11","DEMO-12"]');
            Map<String,Object> input = new Map<String,Object>{'manifestId'=>manifest,'chunk'=>0,
                'rows'=>new List<Object>{new Map<String,Object>{'key'=>'DEMO-11','summary'=>'Imported','assigneeJiraId'=>'unknown',
                    'raw'=>new Map<String,Object>{'columns'=>new List<String>{'Custom','Custom'},'values'=>new List<String>{' A ','B'}}}}};
            Map<String,Object> failed = parsed(Atlas_Tickets.importJira(JSON.serialize(input)));
            System.assertEquals(false,failed.get('applied'));
            System.assertNotEquals(null,failed.get('receiptId'));
            System.assertEquals(0,[SELECT count() FROM Atlas_Ticket__c]);
            Map<String,Object> row = (Map<String,Object>)((List<Object>)input.get('rows'))[0];
            row.put('assigneeResolution','keep');
            Map<String,Object> saved = parsed(Atlas_Tickets.importJira(JSON.serialize(input)));
            System.assertEquals(true,saved.get('applied'));
            System.assertEquals(saved.get('receiptId'),parsed(Atlas_Tickets.importJira(JSON.serialize(input))).get('receiptId'));
            Id id = [SELECT Id FROM Atlas_Ticket__c].Id;
            Atlas_Tickets.Ticket ticket = Atlas_Tickets.getTicket(id);
            System.assertEquals('unknown',ticket.planning.get('unresolvedAssignee'));
            System.assertEquals(' A ',((List<Object>)((Map<String,Object>)ticket.raw).get('values'))[0]);
            row.put('summary','Different replay');
            System.assertEquals(false,parsed(Atlas_Tickets.importJira(JSON.serialize(input))).get('applied'));
            System.assertEquals('Imported',Atlas_Tickets.getTicket(id).summary);
            input.put('chunk',1); row.put('key','DEMO-99');
            System.assertEquals(false,parsed(Atlas_Tickets.importJira(JSON.serialize(input))).get('applied'));
            for (String bad : new List<String>{'["DEMO-1","DEMO-1"]','["not a key"]'}) {
                try { Atlas_Tickets.beginImport(bad); System.assert(false); }
                catch (AuraHandledException e) { System.assert(e.getMessage().contains('Invalid or duplicate')); }
            }
        }
    }

    @IsTest
    static void checklistPreservesMentionsAndRejectsConflictingBaselines() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name='Checklist',Mode__c='Task'); insert conversation;
            Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c='Original',Jira_Key__c='DEMO-31',Stage__c='In Jira'); insert ticket;
            apply(conversation.Id,'{"updates":[{"target":"DEMO-31","changes":{"summary":"Proposed"},"comments":[{"text":"Please review","mentions":[{"name":"Reviewer","userId":"confirmed"}]}]}]}');
            Atlas_Tickets.Ticket loaded = Atlas_Tickets.getTicket(ticket.Id);
            Map<String,Object> proposal = (Map<String,Object>)loaded.pendingUpdates[0];
            String updateId=(String)proposal.get('id');
            System.assertEquals('confirmed',((Map<String,Object>)((List<Object>)((Map<String,Object>)((List<Object>)proposal.get('comments'))[0]).get('mentions'))[0]).get('userId'));
            update new Atlas_Ticket__c(Id=ticket.Id,Summary__c='Teammate edit');
            try { Atlas_Tickets.completeUpdatePart(ticket.Id,updateId,'field:summary',true,Atlas_Tickets.getTicket(ticket.Id).version); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Baseline conflict')); }
            Atlas_Tickets.completeUpdatePart(ticket.Id,updateId,'field:summary',false,Atlas_Tickets.getTicket(ticket.Id).version);
            System.assertEquals(1,Atlas_Tickets.getTicket(ticket.Id).pendingCount);
            Atlas_Tickets.completeUpdatePart(ticket.Id,updateId,'comment:0',true,Atlas_Tickets.getTicket(ticket.Id).version);
            loaded=Atlas_Tickets.getTicket(ticket.Id);
            System.assertEquals(0,loaded.pendingCount);
            System.assertEquals('Teammate edit',loaded.summary);
            System.assertEquals(1,loaded.pendingUpdates.size());
        }
    }

    @IsTest
    static void parentChecklistsDetectLookupIdentityAndEffectiveKeyChanges() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name='Parent baselines'); insert conversation;
            Atlas_Ticket__c epic = new Atlas_Ticket__c(Summary__c='Saved parent', Issue_Type__c='Epic', Jira_Key__c='DEMO-620'); insert epic;
            Atlas_Ticket__c child = new Atlas_Ticket__c(Summary__c='Child', Jira_Key__c='DEMO-621'); insert child;
            apply(conversation.Id, '{"updates":[{"target":"DEMO-621","changes":{"epicKey":"DEMO-622"}}]}');
            String updateId = (String)((Map<String,Object>)Atlas_Tickets.getTicket(child.Id).pendingUpdates[0]).get('id');
            Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>child.Id,'expectedVersion'=>Atlas_Tickets.getTicket(child.Id).version,'epicId'=>epic.Id}));
            System.assertEquals(null, [SELECT Epic_Key__c FROM Atlas_Ticket__c WHERE Id=:child.Id].Epic_Key__c,
                'This is a lookup-only change, not a raw key edit.');
            try { Atlas_Tickets.completeUpdatePart(child.Id, updateId, 'field:epicKey', true, Atlas_Tickets.getTicket(child.Id).version); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Baseline conflict')); }
            System.assertEquals(epic.Id, Atlas_Tickets.getTicket(child.Id).epicId);
            Atlas_Tickets.completeUpdatePart(child.Id, updateId, 'field:epicKey', false, Atlas_Tickets.getTicket(child.Id).version);
            apply(conversation.Id, '{"batchId":"effective-parent","updates":[{"target":"DEMO-621","changes":{"epicKey":"DEMO-622"}}]}');
            updateId = (String)((Map<String,Object>)Atlas_Tickets.getTicket(child.Id).pendingUpdates[1]).get('id');
            update new Atlas_Ticket__c(Id=epic.Id, Jira_Key__c='DEMO-623');
            try { Atlas_Tickets.completeUpdatePart(child.Id, updateId, 'field:epicKey', true, Atlas_Tickets.getTicket(child.Id).version); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Baseline conflict')); }
            System.assertEquals('DEMO-623', Atlas_Tickets.getTicket(child.Id).epicKey);
        }
    }

    @IsTest
    static void boardParentChoicesReplaceBothRepresentationsAndExportTheChosenParent() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Ticket__c first = new Atlas_Ticket__c(Summary__c='First parent', Issue_Type__c='Epic', Jira_Key__c='DEMO-630', Stage__c='In Jira');
            Atlas_Ticket__c second = new Atlas_Ticket__c(Summary__c='Second parent', Issue_Type__c='Epic', Jira_Key__c='DEMO-631', Stage__c='In Jira');
            insert new List<Atlas_Ticket__c>{first,second};
            for (String choice : new List<String>{'key','lookup','none'}) {
                Atlas_Ticket__c child = new Atlas_Ticket__c(Summary__c=choice, Issue_Type__c='Task', Stage__c='Draft', Project_Key__c='DEMO',
                    Epic__c=first.Id, Epic_Key__c='DEMO-630');
                insert child;
                Map<String,Object> edit = new Map<String,Object>{'id'=>child.Id,'expectedVersion'=>Atlas_Tickets.getTicket(child.Id).version};
                if (choice == 'key') edit.put('epicKey', 'DEMO-631');
                else if (choice == 'lookup') { edit.put('epicId', second.Id); edit.put('epicKey', 'DEMO-630'); }
                else edit.put('epicId', '');
                Atlas_Tickets.saveTicket(JSON.serialize(edit));
                Atlas_Tickets.Ticket saved = Atlas_Tickets.getTicket(child.Id);
                Atlas_Ticket__c stored = [SELECT Epic__c, Epic_Key__c FROM Atlas_Ticket__c WHERE Id=:child.Id];
                System.assertEquals(choice == 'lookup' ? second.Id : null, stored.Epic__c);
                System.assertEquals(choice == 'key' ? 'DEMO-631' : null, stored.Epic_Key__c);
                System.assertEquals(choice == 'none' ? null : 'DEMO-631', saved.epicKey);
                Map<String,Object> request = parsed(exportInput(child.Id, 'children'));
                if (choice != 'none') request.put('parentKeys', new Map<Id,String>{child.Id=>'DEMO-631'});
                Atlas_Tickets.saveExport(JSON.serialize(request));
                System.assertEquals('Exported', Atlas_Tickets.getTicket(child.Id).stage);
            }
        }
    }

    @IsTest
    static void customFieldsUseIndependentBaselinesAndRemainInTheMirror() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c conversation=new Atlas_Conversation__c(Name='Custom fields'); insert conversation;
            apply(conversation.Id,'{"tickets":[{"ref":"T1","summary":"Custom draft","customFields":{"Team":" A "}}]}');
            Id id=[SELECT Id FROM Atlas_Ticket__c].Id;
            Atlas_Tickets.Ticket ticket=Atlas_Tickets.getTicket(id);
            System.assertEquals(' A ',((Map<String,Object>)ticket.planning.get('customFields')).get('Team'));
            update new Atlas_Ticket__c(Id=id,Jira_Key__c='DEMO-701',Stage__c='In Jira');
            apply(conversation.Id,'{"updates":[{"target":"DEMO-701","changes":{"customFields":{"Team":"B","Other":"New"}}}]}');
            ticket=Atlas_Tickets.getTicket(id);
            String updateId=(String)((Map<String,Object>)ticket.pendingUpdates[0]).get('id');
            Atlas_Tickets.saveTicket(JSON.serialize(new Map<String,Object>{'id'=>id,'expectedVersion'=>ticket.version,'customFields'=>new Map<String,Object>{'Team'=>'Teammate'}}));
            try { Atlas_Tickets.completeUpdatePart(id,updateId,'field:custom:Team',true,Atlas_Tickets.getTicket(id).version); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Baseline conflict')); }
            Atlas_Tickets.completeUpdatePart(id,updateId,'field:custom:Other',true,Atlas_Tickets.getTicket(id).version);
            Atlas_Tickets.completeUpdatePart(id,updateId,'field:custom:Team',false,Atlas_Tickets.getTicket(id).version);
            ticket=Atlas_Tickets.getTicket(id);
            System.assertEquals('Teammate',((Map<String,Object>)ticket.planning.get('customFields')).get('Team'));
            System.assertEquals('New',((Map<String,Object>)ticket.planning.get('customFields')).get('Other'));
            System.assertEquals(0,ticket.pendingCount);
        }
    }

    @IsTest
    static void agentPagesAndWorkspaceOriginsDoNotSilentlyCollide() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<Atlas_Ticket__c> rows=new List<Atlas_Ticket__c>();
            for (Integer i=0;i<21;i++) rows.add(new Atlas_Ticket__c(Summary__c='Paged '+i,Stage__c='Draft'));
            insert rows;
            Map<String,Object> request=new Map<String,Object>{'description'=>true,'limit'=>500};
            Integer seen=0;
            for (Integer i=0;i<3;i++) {
                Map<String,Object> page=parsed(Atlas_Tickets.agentQuery(request));
                seen+=((List<Object>)page.get('tickets')).size();
                System.assertEquals(i<2,page.get('hasMore'));
                request.put('cursor',page.get('nextCursor'));
            }
            System.assertEquals(21,seen);
            String content='"phase":"records","items":[{"id":"same","summary":"Recovered","kind":"Task"}]';
            Atlas_Tickets.importLegacy('{"workspaceId":"one",'+content+'}');
            Atlas_Tickets.importLegacy('{"workspaceId":"two",'+content+'}');
            System.assertEquals(2,[SELECT count() FROM Atlas_Ticket__c WHERE Summary__c='Recovered']);
        }
    }

    @IsTest
    static void legacyMigrationRetainsHistoryAndResolvesCrossChunkRelationships() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c person = new Atlas_Person__c(Name='Known',Jira_Account_Id__c='jira-known'); insert person;
            Map<String,Object> parent = new Map<String,Object>{'id'=>'parent','summary'=>'Parent','kind'=>'Epic','assignee'=>'known'};
            Map<String,Object> child = new Map<String,Object>{'id'=>'child','summary'=>'Child','epicId'=>'parent','blockedBy'=>new List<String>{'parent'},'assignee'=>'unknown','lane'=>'Blocked'};
            Map<String,Object> input = new Map<String,Object>{'workspaceId'=>'fixture-workspace','phase'=>'records','items'=>new List<Object>{parent,child},
                'settings'=>new Map<String,Object>{'project'=>'DEMO'},'userMappings'=>new List<Object>{new Map<String,Object>{'alias'=>'known','userId'=>'jira-known'}},
                'jiraUpdates'=>new List<Object>{new Map<String,Object>{'id'=>'u','ticketId'=>'child','state'=>'pending',
                    'before'=>new Map<String,Object>{'summary'=>'Child'},'after'=>new Map<String,Object>{'summary'=>'Proposed'},'comments'=>new List<Object>{'note'}}},
                'batches'=>new List<Object>{new Map<String,Object>{'csv'=>'Summary\n"Exact old export"'}}};
            Map<String,Object> saved = parsed(Atlas_Tickets.importLegacy(JSON.serialize(input)));
            System.assertEquals(2,saved.get('saved'));
            System.assertEquals(1,saved.get('unresolved'));
            System.assertEquals(2,parsed(Atlas_Tickets.importLegacy(JSON.serialize(input))).get('skipped'));
            input.put('phase','links');
            System.assertEquals(2,parsed(Atlas_Tickets.importLegacy(JSON.serialize(input))).get('saved'));
            System.assertEquals(2,parsed(Atlas_Tickets.importLegacy(JSON.serialize(input))).get('skipped'));
            Atlas_Ticket__c epic=[SELECT Id,Assignee__c FROM Atlas_Ticket__c WHERE Summary__c='Parent'];
            Atlas_Tickets.Ticket task=Atlas_Tickets.getTicket([SELECT Id FROM Atlas_Ticket__c WHERE Summary__c='Child'].Id);
            System.assertEquals(person.Id,epic.Assignee__c);
            System.assertEquals(epic.Id,task.epicId);
            System.assertEquals(epic.Id,((List<Object>)task.planning.get('dependencies'))[0]);
            System.assertEquals('unknown',task.planning.get('unresolvedAssignee'));
            System.assertEquals(1,task.pendingCount);
            System.assertEquals(1,task.pendingUpdates.size());
            System.assertEquals('Blocked',task.planning.get('lane'));
            System.assertNotEquals(null,task.planning.get('legacyFile'));
        }
    }
}
