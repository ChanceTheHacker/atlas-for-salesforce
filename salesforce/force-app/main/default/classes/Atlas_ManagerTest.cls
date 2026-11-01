@IsTest
private class Atlas_ManagerTest {
    @TestSetup static void setup() { Atlas_Mock.atlasUser(); }
    static Atlas_Person__c person(String name, Boolean manager) {
        Atlas_Person__c p = new Atlas_Person__c(Name=name, Active__c=true, Jira_Account_Id__c=name.replace(' ', '-'),
            Atlas_Is_Manager__c=manager, Atlas_Jira_Identity_Type__c='accountId');
        insert as user p;
        return p;
    }
    static Map<String,Object> edit(Atlas_Person__c p, Boolean manager) {
        return new Map<String,Object>{'id'=>p.Id, 'name'=>p.Name, 'jiraId'=>p.Jira_Account_Id__c,
            'active'=>true, 'isManager'=>manager, 'aliases'=>new List<String>{'Casey'}};
    }
    static void legacy(Id id, String type) {
        Atlas_Data.saveSetting('jira',JSON.serialize(new Map<String,Object>{'projectKey'=>'DEMO',
            'reviewManagerPersonId'=>id, 'reviewManagerIdentityType'=>type, 'legacyOption'=>'keep'}));
    }
    static Map<String,Object> batch(Id assignee) {
        return new Map<String,Object>{'projectKey'=>'DEMO','tickets'=>new List<Object>{new Map<String,Object>{
            'ref'=>'bug-1','issueType'=>'Bug','summary'=>'Suspected bug','description'=>'Evidence for Manager review.', 'assigneeId'=>assignee}}};
    }

    @IsTest static void managerUsesTheOrdinaryPersonIdentityAndAliases() {
        System.runAs(Atlas_Mock.atlasUser()) {
            System.assertEquals(false,Atlas_Jira.canConfigure(),'Manager does not require connection administrator permission.');
            Atlas_Data.saveSetting('jira','{"projectKey":"DEMO"}');
            Id id=Atlas_Data.savePerson('{"name":"Casey Manager","jiraId":"cloud-casey","aliases":["Casey"],"isManager":true,"jiraIdentityType":"accountId","active":true}');
            Map<String,Object> manager=Atlas_Jira.reviewManager();
            System.assertEquals(String.valueOf(id),manager.get('personId'));
            System.assertEquals('cloud-casey',manager.get('jiraId'));
            System.assertEquals(true,manager.get('ready'));
            Atlas_Data.Person dto=Atlas_Data.people()[0];
            System.assertEquals(true,dto.isManager);
            System.assertEquals('accountId',dto.jiraIdentityType);
            for (String term : new List<String>{'Casey','manager','my manager'}) {
                Map<String,Object> found=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Identity.lookup(term));
                System.assertEquals('resolved',found.get('status'),term);
                System.assertEquals(String.valueOf(id),String.valueOf(((Map<String,Object>)found.get('resolved')).get('personId')));
            }
            System.assertEquals(0,Limits.getCallouts());
            System.assertEquals(0,[SELECT count() FROM ContentVersion]);
        }
    }
    @IsTest static void duplicateManagersAreRejectedIncludingNativeBulkWrites() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c first=person('First',true), second=person('Second',false);
            second.Atlas_Is_Manager__c=true;
            Database.SaveResult result=Database.update(second,false,AccessLevel.USER_MODE);
            System.assertEquals(false,result.isSuccess());
            System.assert(result.getErrors()[0].getMessage().contains('Only one Manager'));
            try { Atlas_Data.savePerson(JSON.serialize(edit(second,true))); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('Only one Manager')); }
            System.assertEquals(String.valueOf(first.Id),Atlas_Jira.reviewManager().get('personId'));
            first.Atlas_Is_Manager__c=false; update as user first;
            List<Atlas_Person__c> both=new List<Atlas_Person__c>{new Atlas_Person__c(Id=first.Id,Atlas_Is_Manager__c=true),second};
            List<Database.SaveResult> results=Database.update(both,false,AccessLevel.USER_MODE);
            System.assertEquals(false,results[0].isSuccess());
            System.assertEquals(false,results[1].isSuccess());
            System.assertEquals(0,[SELECT count() FROM Atlas_Person__c WHERE Atlas_Is_Manager__c=true]);
        }
    }
    @IsTest static void legacySelectionMigratesOnlyWhenExplicitlySaved() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c p=person('Legacy',false);
            legacy(p.Id,'accountId');
            Atlas_Data.saveSetting('jira','{"projectKey":"DEMO","defaultPriority":"High","legacyOption":"keep"}');
            Atlas_Data.confirmAlias(p.Id,'Casey');
            System.assertEquals(String.valueOf(p.Id),Atlas_Jira.legacyManagerSetting().get('reviewManagerPersonId'));
            System.assertEquals(false,[SELECT Atlas_Is_Manager__c FROM Atlas_Person__c WHERE Id=:p.Id].Atlas_Is_Manager__c);
            System.assertEquals(true,Atlas_Data.people()[0].isManager);
            Atlas_Data.savePerson(JSON.serialize(edit(p,true)));
            Atlas_Person__c migrated=[SELECT Atlas_Is_Manager__c,Atlas_Jira_Identity_Type__c FROM Atlas_Person__c WHERE Id=:p.Id];
            System.assertEquals(true,migrated.Atlas_Is_Manager__c);
            System.assertEquals('accountId',migrated.Atlas_Jira_Identity_Type__c);
            System.assertEquals('',Atlas_Jira.legacyManagerSetting().get('reviewManagerPersonId'));
            System.assertEquals('keep',Atlas_Jira.legacyManagerSetting().get('legacyOption'));
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            Atlas_Data.savePerson(JSON.serialize(edit(p,false)));
            System.assertEquals('unconfigured',Atlas_Jira.reviewManager().get('status'));
        }
    }
    @IsTest static void legacyConflictsAndUnconfirmedIdentityStaySafe() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c first=person('Legacy',false), second=person('Other',false);
            legacy(first.Id,'');
            second.Atlas_Is_Manager__c=true;
            Database.SaveResult rejected=Database.update(second,false,AccessLevel.USER_MODE);
            System.assertEquals(false,rejected.isSuccess());
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'));
            Atlas_Data.savePerson(JSON.serialize(edit(first,true)));
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'),'Migration must not invent confirmation.');
            try { legacy(second.Id,'accountId'); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('different Manager')); }
            System.assertEquals(String.valueOf(first.Id),Atlas_Jira.reviewManager().get('personId'));
        }
    }
    @IsTest static void anExplicitReplacementCanRecoverADeletedLegacyManagerAtomically() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c old=person('Deleted',false), existing=person('Existing',false);
            legacy(old.Id,'accountId');
            delete as user old;
            System.assertEquals('unavailable',Atlas_Jira.reviewManager().get('status'));
            Map<String,Object> input=new Map<String,Object>{'name'=>'Replacement','jiraId'=>existing.Jira_Account_Id__c,
                'active'=>true,'isManager'=>true};
            try { Atlas_Data.savePerson(JSON.serialize(input)); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('Jira account ID')); }
            System.assertEquals(String.valueOf(old.Id),Atlas_Jira.legacyManagerSetting().get('reviewManagerPersonId'),
                'A failed replacement must roll back clearing the legacy selection.');
            input.put('jiraId','replacement-id');
            Id replacement=Atlas_Data.savePerson(JSON.serialize(input));
            System.assertEquals('',Atlas_Jira.legacyManagerSetting().get('reviewManagerPersonId'));
            System.assertEquals('keep',Atlas_Jira.legacyManagerSetting().get('legacyOption'));
            System.assertEquals(String.valueOf(replacement),Atlas_Jira.reviewManager().get('personId'));
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'),
                'The replacement must never inherit the deleted person\'s confirmation.');
            System.assertEquals(0,[SELECT count() FROM ContentVersion]);
        }
    }
    @IsTest static void identityChangesInvalidateConfirmationButAliasChangesDoNot() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c p=person('Manager',true);
            Atlas_Data.confirmAlias(p.Id,'Casey');
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            p.Jira_Account_Id__c='changed-cloud-id'; update as user p;
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'));
            p.Atlas_Jira_Identity_Type__c='accountId'; update as user p;
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            p.User__c=UserInfo.getUserId(); update as user p;
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'));
            p.Atlas_Is_Manager__c=false; update as user p;
            legacy(p.Id,'accountId');
            p.Jira_Account_Id__c='legacy-changed'; update as user p;
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'));
            System.assertEquals('',Atlas_Jira.legacyManagerSetting().get('reviewManagerIdentityType'));
        }
    }
    @IsTest static void readinessChecksIdentityTypeActivityAndLinkedIdentity() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c p=person('Manager',true);
            Atlas_Data.saveSetting('jira','{"apiVersion":"2","projectKey":"DEMO"}');
            System.assertEquals('identity_type_mismatch',Atlas_Jira.reviewManager().get('status'));
            p.Atlas_Jira_Identity_Type__c='name'; update as user p;
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            p.Active__c=false; update as user p;
            System.assertEquals('inactive',Atlas_Jira.reviewManager().get('status'));
            p.Active__c=true; p.Jira_Account_Id__c=null; update as user p;
            System.assertEquals('missing_jira_id',Atlas_Jira.reviewManager().get('status'));
            p.Jira_Account_Id__c='saved'; p.User__c=UserInfo.getUserId(); update as user p;
            Atlas_Data.saveSetting('identity','{"ssoField":"FederationIdentifier"}');
            System.assertEquals('identity_warning',Atlas_Jira.reviewManager().get('status'));
        }
    }
    @IsTest static void managerRoleIsNotGrantedByAnAliasAndConflictsNeverPickAWinner() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c impostor=person('Other',false);
            impostor.Alias_List__c='["manager","my manager"]'; update as user impostor;
            System.assertEquals('unconfigured',Atlas_Jira.reviewManager().get('status'));
            Map<String,Object> found=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Identity.lookup('manager'));
            System.assertNotEquals('resolved',found.get('status'));
            person('Actual',true);
            found=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Identity.lookup('manager'));
            System.assertEquals('ambiguous',found.get('status'));
        }
    }
    @IsTest static void aPreparedBugCannotKeepAnObsoleteManagerOrIdentity() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Data.saveSetting('jira','{"projectKey":"DEMO"}');
            Atlas_Person__c p=person('Manager',true), other=person('Developer',false);
            Id conversation=Atlas_Data.saveConversation('{"title":"Manager regression","mode":"support-tickets"}');
            String prepared=Atlas_Tickets.prepareBatch(conversation,JSON.serialize(batch(p.Id)));
            try { Atlas_Tickets.prepareBatch(conversation,JSON.serialize(batch(other.Id))); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('configured manager')); }
            p.Atlas_Is_Manager__c=false; update as user p;
            try { Atlas_Tickets.applyBatch(conversation,prepared); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('configured manager')); }
            p.Atlas_Is_Manager__c=true; update as user p;
            prepared=Atlas_Tickets.prepareBatch(conversation,JSON.serialize(batch(p.Id)));
            p.Jira_Account_Id__c='replacement'; update as user p;
            try { Atlas_Tickets.applyBatch(conversation,prepared); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('configured manager')); }
            System.assertEquals(0,[SELECT count() FROM Atlas_Ticket__c]);
            System.assertEquals(0,[SELECT count() FROM ContentVersion]);
            System.assertEquals(0,Limits.getCallouts());
        }
    }
}
