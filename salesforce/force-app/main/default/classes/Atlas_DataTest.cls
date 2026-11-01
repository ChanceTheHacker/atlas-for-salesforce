@IsTest
private class Atlas_DataTest {
    @IsTest
    static void orderedHistoryRetriesReuseFullMessagesAndRejectChangedBytes() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = Atlas_Data.saveConversation('{"title":"Atlas background history","mode":"Source"}');
            String full = 'x'.repeat(140000) + ' EXACT END';
            List<Object> batch = new List<Object>{
                new Map<String,Object>{'nonce'=>'incoming', 'direction'=>'From Agent', 'kind'=>'atlas-request', 'body'=>'query'},
                new Map<String,Object>{'nonce'=>'outgoing', 'direction'=>'To Agent', 'kind'=>'results', 'body'=>full}
            };
            String first = Atlas_Data.appendMessages(conversationId, JSON.serialize(batch));
            String second = Atlas_Data.appendMessages(conversationId, JSON.serialize(batch));
            System.assertEquals(first, second, 'A lost response must not duplicate messages');
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c=:conversationId]);
            Map<String,Object> conversation = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(conversationId));
            List<Object> history = (List<Object>)conversation.get('messages');
            System.assertEquals(full, ((Map<String,Object>)history[1]).get('body'));
            System.assertEquals(false, ((Map<String,Object>)history[1]).get('hasFullBody'), 'Already hydrated body needs no second server read');
            ((Map<String,Object>)batch[1]).put('body', 'changed');
            try { Atlas_Data.appendMessages(conversationId, JSON.serialize(batch)); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('original message')); }
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c=:conversationId]);
        }
    }

    @IsTest
    static void backgroundHistoryValidatesInputAndKeepsConversationsSeparate() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id first = Atlas_Data.saveConversation('{"title":"Atlas first history"}');
            Id second = Atlas_Data.saveConversation('{"title":"Atlas second history"}');
            String batch = '[{"nonce":"same","direction":"To Agent","kind":"results","body":"Exact"}]';
            Atlas_Data.appendMessages(first, batch);
            Atlas_Data.appendMessages(second, batch);
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Message__c]);
            for (String invalid : new List<String>{'[]', '[{"nonce":"","direction":"To Agent","kind":"results","body":"bad"}]',
                '[{"nonce":"invalid","direction":"other","kind":"results","body":"bad"}]'}) {
                try { Atlas_Data.appendMessages(first, invalid); System.assert(false); }
                catch (AuraHandledException e) { System.assertNotEquals(null, e.getMessage()); }
            }
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Message__c]);
        }
    }

    static String failure(String personJson) {
        try {
            Atlas_Data.savePerson(personJson);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        System.assert(false, 'Expected a failure for ' + personJson);
        return null;
    }

    @IsTest
    static void savesPeopleWithUniqueAliases() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id meId = Atlas_Data.savePerson('{"name":"  Me   Myself ","userId":"' + UserInfo.getUserId() + '","aliases":["Boss",""]}');
            Id reportId = Atlas_Data.savePerson('{"name":"Robin Report","jiraId":"712020:abc","aliases":["Rob","R. Report"],"managerId":"' + meId + '"}');
            List<Atlas_Data.Person> people = Atlas_Data.people();
            System.assertEquals(2, people.size());
            for (Atlas_Data.Person p : people) {
                if (p.id == meId) {
                    System.assert(p.isMe);
                    System.assertEquals('Me Myself', p.name);
                } else {
                    System.assert(p.isMyReport);
                    System.assertEquals(new List<String>{ 'Rob', 'R. Report' }, p.aliases);
                }
            }
            System.assert(failure('{"name":"Someone","aliases":["rob"]}').contains('already points to Robin Report'));
            System.assert(failure('{"name":"Other","jiraId":"712020:abc"}').contains('already has that Jira account ID'));
            System.assert(failure('{"name":""}').contains('Enter a name'));
            System.assert(failure('{"name":"Bad","jiraId":"has space"}').contains('exactly as Jira shows it'));
            System.assert(failure('{"name":"Long","aliases":["' + 'x'.repeat(256) + '"]}').contains('120 characters'));
            // Saving a person again with their own alias is fine.
            Atlas_Data.savePerson('{"id":"' + reportId + '","name":"Robin Report","aliases":["Rob"],"active":false}');
            System.assertEquals(false, [SELECT Active__c FROM Atlas_Person__c WHERE Id = :reportId].Active__c);
            System.assert(Atlas_Data.findUsers(UserInfo.getName().left(3)).size() > 0);
        }
    }

    @IsTest
    static void userSearchMatchesApostrophesAndTreatsWildcardsLiterally() {
        User tester = Atlas_Mock.atlasUser();
        User obrien = new User(Username = 'atlas-obrien-' + UserInfo.getOrganizationId() + '@example.com', LastName = 'O\'Brien Atlas',
            Email = 'atlas-obrien@example.com', Alias = 'atobrien', ProfileId = [SELECT ProfileId FROM User WHERE Id = :tester.Id].ProfileId,
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        System.runAs(new User(Id = UserInfo.getUserId())) { insert obrien; }
        System.runAs(tester) {
            System.assertEquals(1, Atlas_Data.findUsers('O\'Brien Atlas').size());
            System.assertEquals(0, Atlas_Data.findUsers('%').size());
        }
    }

    @IsTest
    static void identityMutationsShareOneSerializationRowAndRejectConflictingClaims() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id first = Atlas_Data.savePerson('{"name":"First writer","jiraId":"jira-first","aliases":["Shared identity"]}');
            List<Atlas_Setting__c> locks = [SELECT Id, Key__c FROM Atlas_Setting__c WHERE Key__c='people-lock'];
            System.assertEquals(1, locks.size(), 'Every identity scan/write must first hold the same unique-key serialization row.');
            Id lockId = locks[0].Id;
            update new Atlas_Setting__c(Id=lockId, Data__c='Preserve existing data');
            Id second = Atlas_Data.savePerson('{"name":"Second writer","jiraId":"jira-second"}');
            System.assert(failure('{"id":"' + second + '","name":"Second writer","jiraId":"jira-second","aliases":[" SHARED   IDENTITY "]}').contains('already points to First writer'));
            try { Atlas_Data.confirmAlias(second, 'shared identity'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('already points to First writer')); }
            Atlas_Data.savePerson('{"id":"' + first + '","name":"First writer","jiraId":"jira-first","aliases":["Shared identity"],"active":false}');
            Atlas_Data.confirmAlias(second, 'Shared identity');
            System.assert(failure('{"id":"' + first + '","name":"First writer","jiraId":"jira-first","aliases":["Shared identity"],"active":true}').contains('already points to Second writer'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Person__c WHERE Active__c=true AND Aliases__c='shared identity']);
            locks = [SELECT Id, Data__c FROM Atlas_Setting__c WHERE Key__c='people-lock'];
            System.assertEquals(1, locks.size());
            System.assertEquals(lockId, locks[0].Id, 'Creates, edits, alias confirmations and reactivation use one lock, not per-person or per-user locks.');
            System.assertEquals('Preserve existing data', locks[0].Data__c);
        }
    }

    @IsTest
    static void peopleSerializationIsSharedAcrossUsersNotScopedToTheCaller() {
        User first = Atlas_Mock.atlasUser();
        User second = new User(Username='atlas-second-writer-' + UserInfo.getOrganizationId() + '@example.com', LastName='Atlas second writer',
            Email='atlas-second-writer@example.com', Alias='atsecond', ProfileId=[SELECT ProfileId FROM User WHERE Id=:first.Id].ProfileId,
            TimeZoneSidKey='America/New_York', LocaleSidKey='en_US', EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US');
        System.runAs(new User(Id=UserInfo.getUserId())) {
            insert second;
            insert new PermissionSetAssignment(AssigneeId=second.Id,
                PermissionSetId=[SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId=:first.Id AND PermissionSet.Name='Atlas_User' LIMIT 1].PermissionSetId);
        }
        Id lockId;
        System.runAs(first) {
            Atlas_Data.savePerson('{"name":"First identity owner","jiraId":"jira-owner","aliases":["Shared across users"]}');
            lockId = [SELECT Id FROM Atlas_Setting__c WHERE Key__c='people-lock'].Id;
        }
        System.runAs(second) {
            Atlas_Data.savePerson('{"name":"Other identity owner","jiraId":"jira-other"}');
            System.assertEquals(lockId, [SELECT Id FROM Atlas_Setting__c WHERE Key__c='people-lock'].Id);
            System.assert(failure('{"name":"Third identity owner","jiraId":"jira-third","aliases":["shared across users"]}').contains('already points to First identity owner'));
        }
        System.assertEquals(2, [SELECT COUNT() FROM Atlas_Person__c WITH SYSTEM_MODE]);
        System.assertEquals(1, [SELECT COUNT() FROM Atlas_Setting__c WHERE Key__c='people-lock' WITH SYSTEM_MODE]);
    }

    @IsTest
    static void pagesCompletePeopleDirectory() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<Atlas_Person__c> rows = new List<Atlas_Person__c>();
            for (Integer i = 0; i < 205; i++) rows.add(new Atlas_Person__c(Name = 'Person ' + i, Active__c = i != 204));
            insert as user rows;
            Test.startTest();
            Atlas_Data.PeoplePage first = Atlas_Data.peoplePage(null);
            System.assertEquals(200, first.people.size());
            System.assertNotEquals(null, first.nextCursor);
            Atlas_Data.PeoplePage second = Atlas_Data.peoplePage(first.nextCursor);
            System.assertEquals(5, second.people.size());
            System.assertEquals(null, second.nextCursor);
            Set<String> ids = new Set<String>();
            for (Atlas_Data.Person p : first.people) System.assert(ids.add(p.id));
            for (Atlas_Data.Person p : second.people) System.assert(ids.add(p.id));
            System.assertEquals(205, ids.size());
            Map<String,Object> boot = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.bootstrap());
            System.assertEquals(first.nextCursor, boot.get('peopleCursor'));
            Map<String,Object> research = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Research.run(JSON.serialize(new Map<String,Object>{'op' => 'people', 'afterId' => first.nextCursor})));
            System.assertEquals(5, ((List<Object>) research.get('people')).size());
            try { Atlas_Data.people(); System.assert(false); }
            catch (Atlas_Api.AtlasException e) { System.assert(e.getMessage().contains('peoplePage')); }
            try { Atlas_Data.peoplePage(UserInfo.getUserId()); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('cursor')); }
            Test.stopTest();
        }
    }

    @IsTest
    static void storesTeamAndPersonalSettings() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Data.saveSetting('jira', '{"projectKey":"DEMO"}');
            Atlas_Data.saveSetting('mine', '{"replyLimit":100000}');
            Atlas_Data.saveSetting('jira', '{"projectKey":"ABC"}');
            Map<String, Object> boot = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Data.bootstrap());
            Map<String, Object> settings = (Map<String, Object>) boot.get('settings');
            System.assertEquals('{"projectKey":"ABC"}', settings.get('jira'));
            System.assertEquals('{"replyLimit":100000}', settings.get('mine'));
            System.assert(((Map<String, Object>) boot.get('objects')).get('ticket').toString().endsWith('Atlas_Ticket__c'));
            for (List<String> bad : new List<List<String>>{ new List<String>{ 'other', 'x' }, new List<String>{ 'jira', 'x'.repeat(131073) } }) {
                try {
                    Atlas_Data.saveSetting(bad[0], bad[1]);
                    System.assert(false);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().length() > 0);
                }
            }
        }
    }

    @IsTest
    static void messageHistoryUsesDatesBeforeIdsAndPagesTimestampTies() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = Atlas_Data.saveConversation('{"title":"Atlas chronological history","mode":"Source"}');
            List<Atlas_Message__c> rows = new List<Atlas_Message__c>();
            for (Integer i = 0; i < 82; i++) rows.add(new Atlas_Message__c(
                Conversation__c=conversationId, Direction__c='To Agent', Kind__c='test', Body__c='message ' + i));
            insert rows;
            Datetime latest = Datetime.now().addDays(-1);
            for (Integer i = 0; i < rows.size(); i++) Test.setCreatedDate(rows[i].Id,
                i < 2 ? latest : latest.addDays(i == 81 ? -2 : -1));
            Map<String,Object> conversation = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.getConversation(conversationId));
            List<Object> history = (List<Object>)conversation.get('messages');
            System.assertEquals(rows[1].Id, ((Map<String,Object>)history[39]).get('recordId'), 'Latest handoff wins, not highest ID');
            Id cursor = (Id)conversation.get('messageCursor');
            while (cursor != null) {
                Map<String,Object> page = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.messagePage(conversationId, cursor));
                List<Object> older = (List<Object>)page.get('messages');
                older.addAll(history);
                history = older;
                cursor = (Id)page.get('cursor');
            }
            List<Atlas_Message__c> expected = [SELECT Id FROM Atlas_Message__c
                WHERE Conversation__c=:conversationId ORDER BY CreatedDate, Id];
            System.assertEquals(expected.size(), history.size());
            for (Integer i = 0; i < expected.size(); i++)
                System.assertEquals(expected[i].Id, ((Map<String,Object>)history[i]).get('recordId'), 'Exact chronological traversal across ties');
            Id other = Atlas_Data.saveConversation('{"title":"Atlas other history"}');
            try { Atlas_Data.messagePage(other, rows[0].Id); System.assert(false, 'Cursor must belong to this conversation'); }
            catch (AuraHandledException e) { System.assertNotEquals(null, e.getMessage()); }
        }
    }

    @IsTest
    static void longMessagesSurviveReloadWithoutLosingTheirEnding() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = Atlas_Data.saveConversation('{"title":"Long reply","mode":"Source"}');
            String body = 'x'.repeat(140000) + ' END-OF-REPLY';
            Atlas_Data.addMessage(conversationId, 'To Agent', 'results', body);
            Map<String, Object> c = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Data.getConversation(conversationId));
            List<Object> messages = (List<Object>) c.get('messages');
            System.assertEquals(body, ((Map<String, Object>) messages[0]).get('body'));
        }
    }

    @IsTest
    static void draftsAndFullRequestsAreDurableAndRejectStaleTabs() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String request = 'r'.repeat(140000) + ' LAST REQUEST';
            Id id = Atlas_Data.saveConversation(JSON.serialize(new Map<String,Object>{'title' => 'Recovery', 'mode' => 'Task', 'request' => request}));
            Map<String,Object> c = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getConversation(id));
            System.assertEquals(request, c.get('request'));
            String state = JSON.serialize(new Map<String,Object>{'paste' => 'x'.repeat(140000) + ' END', 'questions' => new List<Object>{}});
            System.assertEquals(1, Atlas_Data.saveState(id, 0, state));
            System.assertEquals(1, Atlas_Data.saveState(id, 0, state), 'Identical retry must not create a version');
            Map<String,Object> saved = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getState(id));
            System.assertEquals('x'.repeat(140000) + ' END', ((Map<String,Object>)saved.get('data')).get('paste'));
            try { Atlas_Data.saveState(id, 0, '{"paste":"stale"}'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('another tab')); }
            System.assertEquals(2, Atlas_Data.saveState(id, 1, '{"paste":"next"}'));
        }
    }

    @IsTest
    static void pagesOlderHistoryAndConfirmsHumanAliases() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = Atlas_Data.saveConversation('{"title":"Paged","mode":"Source"}');
            List<Atlas_Message__c> rows = new List<Atlas_Message__c>();
            for (Integer i=0; i<41; i++) rows.add(new Atlas_Message__c(Conversation__c=id, Direction__c='To Agent', Kind__c='test', Body__c='message '+i));
            insert rows;
            Map<String,Object> c = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getConversation(id));
            System.assertEquals(40, ((List<Object>)c.get('messages')).size());
            Map<String,Object> page = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.messagePage(id, (Id)c.get('messageCursor')));
            System.assertEquals(1, ((List<Object>)page.get('messages')).size());
            System.assertEquals(null, page.get('cursor'));
            System.assert(Atlas_Data.conversationPage(null).contains('Paged'));
            Id person = Atlas_Data.savePerson('{"name":"Robin","jiraId":"jira-robin","aliases":[]}');
            Atlas_Data.confirmAlias(person, 'Rob');
            System.assert(Atlas_Data.people()[0].aliases.contains('Rob'));
            try { Atlas_Data.confirmAlias(person, 'bad,alias'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('one short alias')); }
        }
    }

    @IsTest
    static void checkedStartsRejectImmutableInputsBeforeWritesAndReplaySuccess() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Integer writes = Limits.getDmlStatements();
            String result = Atlas_Data.startConversationChecked(JSON.serialize(new Map<String,Object>{'title' => 'x'.repeat(81)}), 'prompt', 'long-title');
            System.assertEquals('ATLAS_START_INPUT_REJECTED', ((Map<String,Object>)JSON.deserializeUntyped(result)).get('code'));
            result = Atlas_Data.startConversationChecked('{"title":"Atlas oversized attachment"}', 'x'.repeat(1500000), 'long-prompt');
            System.assertEquals('ATLAS_START_INPUT_REJECTED', ((Map<String,Object>)JSON.deserializeUntyped(result)).get('code'));
            result = Atlas_Data.startConversationChecked('{"title":"Atlas malformed request","request":[]}', 'prompt', 'bad-request');
            System.assertEquals('ATLAS_START_INPUT_REJECTED', ((Map<String,Object>)JSON.deserializeUntyped(result)).get('code'));
            System.assertEquals(writes, Limits.getDmlStatements(), 'A safe-to-edit response must do no DML');
            System.assertEquals(0, [SELECT count() FROM Atlas_Conversation__c]);
            System.assertEquals(0, [SELECT count() FROM Atlas_Message__c]);
            String input = '{"title":"Atlas corrected draft","mode":"Task"}';
            String id = Atlas_Data.startConversationChecked(input, 'exact prompt', 'corrected');
            System.assertEquals(id, Atlas_Data.startConversationChecked(input, 'exact prompt', 'corrected'));
            System.assertEquals(1, [SELECT count() FROM Atlas_Conversation__c]);
            System.assertEquals(1, [SELECT count() FROM Atlas_Message__c]);
        }
    }

    @IsTest
    static void keepsConversationsAndMessages() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversationId = Atlas_Data.saveConversation('{"title":"  Fix   the layout ","request":"Please fix it","mode":"Source"}');
            Atlas_Data.addMessage(conversationId, 'To Agent', 'prompt', 'Hello agent');
            Atlas_Data.addMessage(conversationId, 'From Agent', 'atlas-request', 'x'.repeat(140000));
            Atlas_Data.saveConversation('{"id":"' + conversationId + '","title":"","status":"Closed"}');
            Map<String, Object> c = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Data.getConversation(conversationId));
            System.assertEquals('Untitled', c.get('title'));
            System.assertEquals('Closed', c.get('status'));
            List<Object> messages = (List<Object>) c.get('messages');
            System.assertEquals(2, messages.size());
            System.assertEquals('Hello agent', ((Map<String, Object>) messages[0]).get('body'));
            System.assertEquals('x'.repeat(140000), ((Map<String, Object>) messages[1]).get('body'));
            System.assertEquals('x'.repeat(140000), Atlas_Data.getMessage((Id) ((Map<String, Object>) messages[1]).get('recordId')));
            System.assertEquals(1, Atlas_Data.conversations().size());

            Id versionId = Atlas_Data.saveFile(conversationId, 'notes.txt', EncodingUtil.base64Encode(Blob.valueOf('hi')));
            System.assertEquals('Atlas notes', [SELECT Title FROM ContentVersion WHERE Id = :versionId].Title);
            try {
                Atlas_Data.getConversation(null);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().length() > 0);
            }
        }
    }

    @IsTest
    static void draftSavesKeepCaseChangesAndRemoveOnlyTheirOwnOldFiles() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id id = Atlas_Data.saveConversation('{"title":"Drafts","mode":"Task"}');
            System.assertEquals(1, Atlas_Data.saveState(id, 0, '{"paste":"hello"}'));
            System.assertEquals(2, Atlas_Data.saveState(id, 1, '{"paste":"HELLO"}'), 'A case-only edit is a real change');
            Map<String,Object> saved = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getState(id));
            System.assertEquals('HELLO', ((Map<String,Object>) saved.get('data')).get('paste'));

            String first = JSON.serialize(new Map<String,Object>{'paste' => 'a'.repeat(140000)});
            String second = JSON.serialize(new Map<String,Object>{'paste' => 'b'.repeat(140000)});
            System.assertEquals(3, Atlas_Data.saveState(id, 2, first));
            System.assertEquals(4, Atlas_Data.saveState(id, 3, second));
            System.assertEquals(1, [SELECT count() FROM ContentDocument WHERE Title = 'Atlas draft'], 'The replaced draft File is removed');
            saved = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getState(id));
            System.assertEquals('b'.repeat(140000), ((Map<String,Object>) saved.get('data')).get('paste'));

            System.assertEquals(5, Atlas_Data.saveState(id, 4, '{"paste":"small"}'));
            System.assertEquals(0, [SELECT count() FROM ContentDocument WHERE Title = 'Atlas draft'], 'A small draft no longer needs a File');

            // A recovery File that the draft points at belongs to someone else and stays.
            ContentVersion recovery = new ContentVersion(Title = 'Atlas draft', PathOnClient = 'draft.json', VersionData = Blob.valueOf('{"paste":"recovered"}'));
            insert recovery;
            Id recoveryDocument = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :recovery.Id].ContentDocumentId;
            update new Atlas_Conversation__c(Id = id, State_File__c = recovery.Id, UI_State__c = null);
            System.assertEquals(6, Atlas_Data.saveState(id, 5, '{"paste":"small again"}'));
            System.assertEquals(1, [SELECT count() FROM ContentDocument WHERE Id = :recoveryDocument]);
            System.assertEquals(1, [SELECT count() FROM ContentDocument WHERE Title = 'Atlas draft']);

            // A draft whose File was removed reads as empty instead of breaking the conversation.
            update new Atlas_Conversation__c(Id = id, State_File__c = recovery.Id, UI_State__c = null);
            delete new ContentDocument(Id = recoveryDocument);
            saved = (Map<String,Object>) JSON.deserializeUntyped(Atlas_Data.getState(id));
            System.assertEquals(0, ((Map<String,Object>) saved.get('data')).size());
        }
    }

    @IsTest
    static void reportsToMustBeAnotherPersonAndBlankMeansNone() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id person = Atlas_Data.savePerson('{"name":"Robin","jiraId":"jira-robin","aliases":[]}');
            System.assert(failure('{"name":"Wrong","managerId":"' + UserInfo.getUserId() + '"}').contains('must be a person'));
            System.assert(failure('{"id":"' + person + '","name":"Robin","jiraId":"jira-robin","managerId":"' + person + '"}').contains('cannot report to themselves'));
            Id other = Atlas_Data.savePerson('{"name":"Sam","managerId":""}');
            System.assertEquals(null, [SELECT Manager__c FROM Atlas_Person__c WHERE Id = :other].Manager__c);
        }
    }

    @IsTest
    static void confirmingAnAliasForARemovedPersonExplainsWhy() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id person = Atlas_Data.savePerson('{"name":"Gone","jiraId":"jira-gone","aliases":[]}');
            delete new Atlas_Person__c(Id = person);
            try { Atlas_Data.confirmAlias(person, 'G'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('no longer exists'), e.getMessage()); }
        }
    }
}
