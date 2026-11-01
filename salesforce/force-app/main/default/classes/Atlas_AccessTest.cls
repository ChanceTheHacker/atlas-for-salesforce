@IsTest
private class Atlas_AccessTest {
    static User reader(Boolean granted) {
        Profile minimum = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User user = new User(Username = 'atlas-access-' + granted + '-' + UserInfo.getOrganizationId() + '@example.com',
            LastName = 'Atlas access test', Email = 'atlas-access@example.com', Alias = 'ataccess', ProfileId = minimum.Id,
            TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
            if (granted) {
                String namespace = [SELECT NamespacePrefix FROM Organization LIMIT 1].NamespacePrefix;
                insert new PermissionSetAssignment(AssigneeId = user.Id,
                    PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Atlas_User' AND NamespacePrefix = :namespace LIMIT 1].Id);
            }
        }
        return user;
    }

    @IsTest
    static void deniedCrudAndFieldsNeverFallBackToSystemMode() {
        User denied = reader(false);
        Atlas_Ticket__c ticket = new Atlas_Ticket__c(Summary__c = 'Atlas secret ticket'); insert as system ticket;
        Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name = 'Atlas secret conversation', UI_State__c = '{"private":true}'); insert as system conversation;
        System.runAs(denied) {
            Boolean blocked = false;
            try { Atlas_Tickets.getTicket(ticket.Id); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Ticket reads must enforce object and field access');
            blocked = false;
            try { Atlas_Tickets.saveTicket('{"summary":"Atlas denied"}'); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Ticket creation must enforce CRUD/FLS');
            blocked = false;
            try { Atlas_Data.getState(conversation.Id); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Draft reads must enforce object and field access');
            blocked = false;
            try { Atlas_Data.saveConversation('{"title":"Atlas denied"}'); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Conversation creation must enforce CRUD/FLS');
            blocked = false;
            try { Atlas_Workspace.recordBody('Atlas_Ticket__c', ticket.Id); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Workspace export must not bypass object permissions');
        }
        System.assertEquals(1, [SELECT count() FROM Atlas_Ticket__c WITH SYSTEM_MODE]);
        System.assertEquals(1, [SELECT count() FROM Atlas_Conversation__c WITH SYSTEM_MODE]);
    }

    @IsTest
    static void permissionSetWorksWithoutAnAdminProfileAndKeepsLibrariesPrivate() {
        User member = reader(true);
        Atlas_Library__c privateLibrary = new Atlas_Library__c(Name = 'Atlas private to another user', Kind__c = 'draft'); insert as system privateLibrary;
        Atlas_Ticket__c sharedTicket = new Atlas_Ticket__c(Summary__c = 'Atlas shared ticket'); insert as system sharedTicket;
        System.runAs(member) {
            Test.startTest();
            Id conversation = Atlas_Data.startConversation('{"title":"Atlas member conversation","mode":"Task"}', 'Atlas member prompt', 'member-start');
            System.assert(Atlas_Data.getConversation(conversation).contains('Atlas member prompt'));
            System.assertEquals(1, Atlas_Data.saveState(conversation, 0, '{"draft":"Atlas kept"}'));
            Id savedFile = Atlas_Data.saveFile(conversation, 'member.txt', 'bWVtYmVy');
            System.assertEquals(savedFile, Atlas_Data.saveFile(conversation, 'member.txt', 'bWVtYmVy'));
            Atlas_Tickets.saveTicket('{"summary":"Atlas member ticket"}');
            Atlas_Tickets.Ticket own;
            for (Atlas_Tickets.Ticket row : Atlas_Tickets.board(false)) if (row.summary == 'Atlas member ticket') own = row;
            System.assertNotEquals(null, own);
            Atlas_Tickets.setStage(new List<Id>{own.id}, 'Archived', null, JSON.serialize(new Map<String,Object>{own.id => own.version}));
            System.assertEquals('Archived', Atlas_Tickets.getTicket(own.id).stage);
            System.assertEquals(sharedTicket.Id, Atlas_Tickets.getTicket(sharedTicket.Id).id);
            System.assert(Atlas_Workspace.recordBody('Atlas_Ticket__c', sharedTicket.Id).contains('Atlas shared ticket'));
            Boolean blocked = false;
            try { Atlas_Workspace.recordBody('Atlas_Library__c', privateLibrary.Id); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Accessible workspace export must still exclude private libraries belonging to others');
            Test.stopTest();
        }
    }

    @IsTest
    static void changesAndLibraryRespectDeniedPermissionsBeforeCallouts() {
        User denied = reader(false);
        Atlas_Change__c change = new Atlas_Change__c(Summary__c='Atlas restricted change', Status__c='Proposed', Revision__c=1); insert as system change;
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        System.runAs(denied) {
            Boolean blocked = false;
            try { Atlas_Changes.getChange(change.Id); } catch (Exception e) { blocked = true; }
            System.assert(blocked);
            blocked = false;
            try { Atlas_Changes.startBackup(null, null, 'Atlas denied', '[{"type":"ApexClass","name":"Foo"}]'); } catch (Exception e) { blocked = true; }
            System.assert(blocked);
            System.assertEquals(0, Atlas_Mock.calls, 'Denied access must stop before contacting metadata APIs');
            blocked = false;
            try { Atlas_Changes.decide(change.Id, 1, false, 'No', 'Default'); } catch (Exception e) { blocked = true; }
            System.assert(blocked);
            blocked = false;
            try { Atlas_Library.saveEntry(null, 'Atlas denied', 'draft', 0, '{}'); } catch (Exception e) { blocked = true; }
            System.assert(blocked);
        }
        System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id=:change.Id WITH SYSTEM_MODE].Status__c);
    }

    @IsTest
    static void permittedMembersCanReviewChangesAndPersistPrivateLibraryVersions() {
        User member = reader(true);
        System.runAs(member) {
            Schema.DescribeSObjectResult libraryAccess = Atlas_Library__c.SObjectType.getDescribe();
            System.assert(libraryAccess.isAccessible(), 'Permission set must grant Library read access');
            System.assert(libraryAccess.isCreateable(), 'Permission set must grant Library create access');
            System.assert(libraryAccess.isUpdateable(), 'Permission set must grant Library update access');
            Atlas_Change__c change = new Atlas_Change__c(Summary__c='Atlas member change', Status__c='Proposed', Revision__c=1); insert change;
            System.assert(Atlas_Changes.getChange(change.Id).contains('Atlas member change'));
            Atlas_Changes.decide(change.Id, 1, false, 'Atlas keep original source', 'Default');
            System.assert(Atlas_Changes.getChange(change.Id).contains('Rejected'));
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name = 'Atlas member source'); insert conversation;
            Atlas_Change__c linked = new Atlas_Change__c(Conversation__c = conversation.Id, Status__c = 'Proposed', Revision__c = 1); insert linked;
            Atlas_Changes.decide(linked.Id, 1, false, 'Atlas reject with handoff', 'Default');
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c = :conversation.Id AND Kind__c = 'decision']);
            Map<String,Object> saved = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Library.saveEntry(null, 'Atlas member draft', 'draft', 0, '{"value":"original"}'));
            Id libraryId = (Id)saved.get('id');
            Atlas_Library.saveEntry(libraryId, 'Atlas member draft', 'draft', 1, '{"value":"next"}');
            System.assert(Atlas_Library.loadEntry(libraryId).contains('next'));
            System.assert(Atlas_Library.loadVersion(libraryId, (Id)saved.get('versionId')).contains('original'));
        }
    }

    @IsTest
    static void changeHistoryPagesBeyondTheLegacyLimit() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<Atlas_Change__c> records = new List<Atlas_Change__c>();
            for (Integer i=0; i<205; i++) records.add(new Atlas_Change__c(Summary__c='Atlas paged '+i));
            insert records;
            Set<Id> seen = new Set<Id>(); Id cursor;
            do {
                Map<String,Object> page = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Changes.changePage(cursor));
                List<Object> items = (List<Object>)page.get('items');
                System.assert(items.size() <= 50);
                for (Object item : items) System.assert(seen.add((Id)((Map<String,Object>)item).get('id')));
                cursor = (Id)page.get('nextCursor');
            } while (cursor != null);
            System.assertEquals(205, seen.size());
            try { Atlas_Changes.listChanges(); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('complete change history')); }
        }
    }

    @IsTest
    static void researchCannotDescribeOrResolvePeopleWithoutTheirPermissions() {
        User denied = reader(false);
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        System.runAs(denied) {
            String type = Atlas_Person__c.SObjectType.getDescribe().getName();
            Map<String,Object> listResult = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Research.run('{"op":"describe"}'));
            System.assert(!JSON.serialize(listResult.get('objects')).contains(type + ' |'), 'Object inventory must omit inaccessible schema');
            for (String request : new List<String>{
                JSON.serialize(new Map<String,Object>{'op' => 'describe', 'object' => type}),
                '{"op":"activity","who":"team"}', '{"op":"activity","who":"hidden-person"}'
            }) {
                Boolean blocked = false;
                try { Atlas_Research.run(request); } catch (Exception e) { blocked = true; }
                System.assert(blocked, 'Research must not use system-mode schema or person access');
            }
            System.assertEquals(0, Atlas_Mock.calls, 'Denied research must stop before API calls');
        }
        User member = reader(true);
        System.runAs(member) {
            Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Research.run('{"op":"describe","object":"User"}'));
            Map<String,Schema.SObjectField> fields = User.SObjectType.getDescribe().fields.getMap();
            for (Object item : (List<Object>)result.get('fields')) {
                String name = (String)((Map<String,Object>)item).get('name');
                System.assert(fields.get(name).getDescribe().isAccessible(), 'No inaccessible field or formula may escape describe');
            }
        }
    }

    @IsTest
    static void generatedFilesRequireAccessibleNativeParentsAndBoundedPayloads() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Boolean blocked = false;
            try { Atlas_Data.saveFile(UserInfo.getUserId(), 'test.txt', 'dGVzdA=='); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'Arbitrary parent types are forbidden');
            Atlas_Conversation__c conversation = new Atlas_Conversation__c(Name = 'Atlas file parent'); insert conversation;
            Id fileId = Atlas_Data.saveFile(conversation.Id, 'test.txt', 'dGVzdA==');
            System.assert([SELECT Title FROM ContentVersion WHERE Id = :fileId].Title.startsWith('Atlas '));
            System.assertEquals(fileId, Atlas_Data.saveFile(conversation.Id, 'test.txt', 'dGVzdA=='), 'A lost save response must replay the existing File');
            System.assertNotEquals(fileId, Atlas_Data.saveFile(conversation.Id, 'test.txt', 'bmV4dA=='), 'Changed bytes remain a separate immutable File');
            System.assertNotEquals(fileId, Atlas_Data.saveFile(conversation.Id, 'Test.txt', 'dGVzdA=='), 'Filename case is part of the exact request');
            Atlas_Conversation__c other = new Atlas_Conversation__c(Name = 'Atlas other file parent'); insert other;
            System.assertNotEquals(fileId, Atlas_Data.saveFile(other.Id, 'test.txt', 'dGVzdA=='), 'A receipt cannot cross parents');
            System.assertEquals(3, [SELECT count() FROM ContentVersion WHERE FirstPublishLocationId = :conversation.Id]);
        }
    }

    @IsTest
    static void aChangeCannotReportToAConversationThePersonCanOnlyRead() {
        User granted = reader(true);
        Atlas_Conversation__c conversation;
        System.runAs(Atlas_Mock.atlasUser()) {
            conversation = new Atlas_Conversation__c(Name = 'Atlas shared to read', Mode__c = 'Source', Status__c = 'Open');
            insert conversation;
            insert new Atlas_Conversation__Share(ParentId = conversation.Id, UserOrGroupId = granted.Id, AccessLevel = 'Read');
        }
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        System.runAs(granted) {
            try {
                Atlas_Changes.startBackup(conversation.Id, null, 'Fix Foo', '[{"type":"ApexClass","name":"Foo"}]');
                System.assert(false, 'The outcome could never be posted back, which would strand the deployment');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('You can read this conversation but not add to it'), e.getMessage()); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Change__c]);
        }
    }
}
