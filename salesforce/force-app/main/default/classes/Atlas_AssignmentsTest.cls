@IsTest
private class Atlas_AssignmentsTest {
    static Id conversation() { return Atlas_Data.saveConversation('{"title":"Assignment review","mode":"Task"}'); }
    static Id person() { return Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'name'=>'Christopher Test','aliases'=>new List<String>{'Chris'},'jiraId'=>'jira-chris','userId'=>UserInfo.getUserId()})); }
    static Case example(Id owner) {
        Case record = new Case(Subject='Atlas synthetic assignment test', Status='New', Origin='Web', OwnerId=owner);
        insert as user record; return record;
    }
    static String prepare(Id conversation, Id record) {
        return Atlas_Assignments.prepare(conversation, JSON.serialize(new List<Object>{new Map<String,Object>{'caseId'=>record,'assignee'=>'Chris','reason'=>'Requested support owner'}}));
    }
    @IsTest static void approvalAndLostResponseRetryApplyOnlyOnce() {
        Id original = UserInfo.getUserId();
        System.runAs(Atlas_Mock.atlasUser()) {
            person(); Id conversation=conversation(); Case record=example(original);
            String review=prepare(conversation,record.Id);
            System.assertEquals(original,[SELECT OwnerId FROM Case WHERE Id=:record.Id].OwnerId,'Preparing never changes ownership.');
            String result=Atlas_Assignments.decide(conversation,review,true,'Approved','receipt1');
            System.assert(result.contains('"status" : "applied"'),result);
            System.assertEquals(UserInfo.getUserId(),[SELECT OwnerId FROM Case WHERE Id=:record.Id].OwnerId);
            Integer before=Limits.getDmlStatements();
            System.assertEquals(result,Atlas_Assignments.decide(conversation,review,true,'Approved','receipt1'));
            System.assertEquals(before,Limits.getDmlStatements(),'Retry must not rerun owner automation.');
            System.assertEquals(1,[SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c=:conversation AND Kind__c='case-assignment']);
            try { Atlas_Assignments.decide(conversation,review,false,'Rejected instead','receipt1'); System.assert(false); }
            catch(AuraHandledException e) { System.assert(e.getMessage().contains('different review')); }
        }
    }
    @IsTest static void rejectingNeverChangesTheCase() {
        Id original=UserInfo.getUserId();
        System.runAs(Atlas_Mock.atlasUser()) {
            person();Id conversation=conversation();Case record=example(original);
            String result=Atlas_Assignments.decide(conversation,prepare(conversation,record.Id),false,'Not this person','reject1');
            System.assert(result.contains('"status" : "rejected"'));
            System.assertEquals(original,[SELECT OwnerId FROM Case WHERE Id=:record.Id].OwnerId);
        }
    }
    @IsTest static void changedCaseOrIdentityProducesADurableNotAppliedResult() {
        Id original=UserInfo.getUserId();
        System.runAs(Atlas_Mock.atlasUser()) {
            Id person=person(), conversation=conversation();Case record=example(original);
            String review=prepare(conversation,record.Id);
            List<Object> rows=(List<Object>)JSON.deserializeUntyped(review);
            ((Map<String,Object>)rows[0]).put('version','0');
            String stale=JSON.serialize(rows);
            String result=Atlas_Assignments.decide(conversation,stale,true,'Review','stale1');
            System.assert(result.contains('not_applied'));System.assert(result.contains('Case changed'));
            System.assertEquals(result,Atlas_Assignments.decide(conversation,stale,true,'Review','stale1'));
            update as user new Atlas_Person__c(Id=person,Jira_Account_Id__c='new-jira');
            result=Atlas_Assignments.decide(conversation,review,true,'Review','stale2');
            System.assert(result.contains('not_applied'));System.assert(result.contains('identity mapping changed'));
            update as user new Atlas_Person__c(Id=person,Active__c=false);
            result=Atlas_Assignments.decide(conversation,review,true,'Review','inactive');
            System.assert(result.contains('not_applied'));System.assertEquals(original,[SELECT OwnerId FROM Case WHERE Id=:record.Id].OwnerId);
        }
    }
    @IsTest static void rejectedOwnerLicenseProducesADurableNotAppliedResult() {
        User reviewer = Atlas_Mock.atlasUser();
        User chatter = new User(ProfileId=[SELECT Id FROM Profile WHERE UserType='CsnOnly' LIMIT 1].Id,
            Username='atlas-case-license-' + System.now().getTime() + '@example.invalid', Email='atlas-case@example.invalid',
            LastName='Atlas Chatter fixture', Alias='atcase', TimeZoneSidKey='America/New_York', LocaleSidKey='en_US',
            EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US');
        System.runAs(new User(Id=UserInfo.getUserId())) { insert chatter; }
        System.runAs(reviewer) {
            Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'name'=>'Christopher Test','aliases'=>new List<String>{'Chris'},'jiraId'=>'chatter-case','userId'=>chatter.Id}));
            Id conversation=conversation(); Case record=example(reviewer.Id);
            String review=prepare(conversation,record.Id);
            String result=Atlas_Assignments.decide(conversation,review,true,'Review','license1');
            System.assert(result.contains('not_applied'), result);
            System.assertEquals(reviewer.Id,[SELECT OwnerId FROM Case WHERE Id=:record.Id].OwnerId);
            Integer before=Limits.getDmlStatements();
            System.assertEquals(result,Atlas_Assignments.decide(conversation,review,true,'Review','license1'));
            System.assertEquals(before,Limits.getDmlStatements(),'A known failed assignment is a receipt, not an endless uncertain retry.');
        }
    }
    @IsTest static void investigationCannotPrepareOrApproveCaseAssignments() {
        Id original = UserInfo.getUserId();
        System.runAs(Atlas_Mock.atlasUser()) {
            person();
            Id task = conversation();
            Id investigation = Atlas_Data.saveConversation('{"title":"Support investigation","mode":"support-tickets"}');
            Case record = example(original);
            // Use a real, otherwise valid review with a different owner. Invalid
            // fixture input or a no-op assignment must not make this test pass.
            String review = prepare(task, record.Id);
            Integer dml = Limits.getDmlStatements();
            try { prepare(investigation, record.Id); System.assert(false, 'Support Tickets cannot prepare ownership changes.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets'), e.getMessage()); }
            try { Atlas_Assignments.decide(investigation, review, true, 'Approve', 'cross-conversation'); System.assert(false, 'Support Tickets cannot approve an externally prepared review.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets'), e.getMessage()); }
            System.assertEquals(dml, Limits.getDmlStatements(), 'Neither rejected entry point may write records or receipts.');
            System.assertEquals(original, [SELECT OwnerId FROM Case WHERE Id = :record.Id].OwnerId);
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c = :investigation]);
        }
    }

    @IsTest static void approvalRechecksStoredModeAfterLegacyRelink() {
        Id original = UserInfo.getUserId();
        System.runAs(Atlas_Mock.atlasUser()) {
            person();
            Id id = conversation();
            Case record = example(original);
            String review = prepare(id, record.Id);
            // Simulate an imported or administratively relinked old review.
            // saveConversation intentionally forbids this mode transition.
            update as user new Atlas_Conversation__c(Id = id, Mode__c = 'support-tickets');
            Integer dml = Limits.getDmlStatements();
            try { Atlas_Assignments.decide(id, review, true, 'Approve old review', 'legacy-review'); System.assert(false, 'Approval must recheck the stored mode.'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Support Tickets'), e.getMessage()); }
            System.assertEquals(dml, Limits.getDmlStatements());
            System.assertEquals(original, [SELECT OwnerId FROM Case WHERE Id = :record.Id].OwnerId);
            String rejected = Atlas_Assignments.decide(id, review, false, 'Discard old review', 'reject-legacy');
            System.assert(rejected.contains('"status" : "rejected"'), 'The user can still discard a legacy review.');
            System.assertEquals(original, [SELECT OwnerId FROM Case WHERE Id = :record.Id].OwnerId);
        }
    }

    @IsTest static void invalidAndAmbiguousRequestsCannotPrepareAssignments() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id conversation=conversation();Case record=example(UserInfo.getUserId());
            for(String request:new List<String>{'[]','[{"caseId":"'+UserInfo.getUserId()+'"}]','[{"caseId":"'+record.Id+'","assignee":"Nobody","reason":"Unknown"}]','[{"caseId":"'+record.Id+'","assignee":"Chris","reason":""}]'}) {
                try {Atlas_Assignments.prepare(conversation,request);System.assert(false);}
                catch(AuraHandledException e) {System.assertNotEquals(null,e.getMessage());}
            }
            person();String review=prepare(conversation,record.Id);
            try {Atlas_Assignments.decide(conversation,review,true,'','');System.assert(false);}
            catch(AuraHandledException e) {System.assert(e.getMessage().contains('receipt'));}
            String result=Atlas_Assignments.decide(conversation,review,true,'Already owned','noop');
            System.assert(result.contains('"status" : "applied"'));
        }
    }
}
