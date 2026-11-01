@IsTest
private class Atlas_JiraSettingsTest {
    @TestSetup static void setup() {
        User administrator=Atlas_Mock.atlasUser();
        User ordinary=new User(Username='atlas-jira-member-'+UserInfo.getOrganizationId()+'@example.com',LastName='Jira Member',Email='member@example.com',Alias='atjiram',
            ProfileId=[SELECT ProfileId FROM User WHERE Id=:administrator.Id].ProfileId,TimeZoneSidKey='America/New_York',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
        System.runAs(new User(Id=UserInfo.getUserId())) {
            insert ordinary;
            insert new PermissionSetAssignment(AssigneeId=ordinary.Id,PermissionSetId=[SELECT Id FROM PermissionSet WHERE Name='Atlas_User' LIMIT 1].Id);
        }
        System.runAs(administrator) { Atlas_JiraTest.settings(true,true,'3'); }
    }
    static User member() { return [SELECT Id FROM User WHERE Alias='atjiram' LIMIT 1]; }
    static Atlas_Setting__c setting() { return [SELECT Id,Key__c,Data__c FROM Atlas_Setting__c WHERE Key__c='jira']; }
    static Atlas_Setting__c storedSetting() { return [SELECT Id,Key__c,Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH SYSTEM_MODE]; }
    static Map<String,Object> value(Atlas_Setting__c row) { return (Map<String,Object>)JSON.deserializeUntyped(row.Data__c); }
    @IsTest static void managerSettingWorksForOrdinaryUsersWithoutChangingTheConnection() {
        System.runAs(member()) {
            Atlas_Person__c manager=new Atlas_Person__c(Name='Review Manager',Active__c=true,Jira_Account_Id__c='cloud-manager'); insert manager;
            Map<String,Object> data=value(setting()); Object revision=data.get('connectionRevision');
            data.put('reviewManagerPersonId',manager.Id); data.put('reviewManagerIdentityType','accountId'); data.put('legacyOption','preserved');
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals(revision,value(setting()).get('connectionRevision'));
            System.assertEquals('preserved',value(setting()).get('legacyOption'));
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            System.assertEquals('cloud-manager',Atlas_Jira.reviewManager().get('jiraId'));
            System.assertEquals('accountId',Atlas_Jira.reviewManager().get('identityType'));
            manager.Active__c=false; update manager;
            System.assertEquals('inactive',Atlas_Jira.reviewManager().get('status'));
            System.assertEquals('',Atlas_Jira.reviewManager().get('jiraId'));
            data.put('defaultPriority','High'); Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals('High',value(setting()).get('defaultPriority'),'An inactive saved manager does not block unrelated settings.');
            data.put('reviewManagerPersonId',''); Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals('unconfigured',Atlas_Jira.reviewManager().get('status'));
            System.assertEquals('',value(setting()).get('reviewManagerIdentityType'));
            System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void olderSavesAndArchivesPreserveTheConfiguredManager() {
        System.runAs(member()) {
            Atlas_Person__c manager=new Atlas_Person__c(Name='Saved Manager',Active__c=true,Jira_Account_Id__c='cloud-manager'); insert manager;
            Map<String,Object> data=value(setting()); Object revision=data.get('connectionRevision');
            data.put('reviewManagerPersonId',manager.Id); data.put('reviewManagerIdentityType','accountId');
            data.put('legacyOption',new Map<String,Object>{'keep'=>true});
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            data.remove('reviewManagerPersonId'); data.remove('reviewManagerIdentityType');
            data.put('defaultPriority','High');
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals(String.valueOf(manager.Id),value(setting()).get('reviewManagerPersonId'));
            System.assertEquals('accountId',value(setting()).get('reviewManagerIdentityType'));
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            // Archive import and direct record updates use the trigger rather than the interactive save.
            manager.Active__c=false; update manager;
            Atlas_Setting__c restored=setting(); restored.Data__c=JSON.serialize(data); update restored;
            Map<String,Object> exported=value(setting());
            System.assertEquals(String.valueOf(manager.Id),exported.get('reviewManagerPersonId'));
            System.assertEquals('accountId',exported.get('reviewManagerIdentityType'));
            System.assertEquals(revision,exported.get('connectionRevision'));
            System.assertEquals(true,((Map<String,Object>)exported.get('legacyOption')).get('keep'));
            System.assertEquals('inactive',Atlas_Jira.reviewManager().get('status'));
            data.put('reviewManagerPersonId','');
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals('',value(setting()).get('reviewManagerPersonId'));
            System.assertEquals('',value(setting()).get('reviewManagerIdentityType'));
            System.assertEquals(0,Limits.getCallouts(),'Saving or restoring settings never sends Jira requests.');
        }
    }
    @IsTest static void omittedConfirmationIsPreservedOnlyForTheSameManager() {
        String legacy='{ "projectKey": "DEMO", "customOption": true }';
        System.assertEquals(legacy,Atlas_Jira.validateSettingPreservingManager(legacy,new Map<String,Object>()),
            'An unconfigured legacy CSV setting keeps its original serialized shape.');
        System.runAs(member()) {
            Atlas_Person__c first=new Atlas_Person__c(Name='First Manager',Active__c=true,Jira_Account_Id__c='first'); insert first;
            Atlas_Person__c second=new Atlas_Person__c(Name='Second Manager',Active__c=true,Jira_Account_Id__c='second'); insert second;
            for (String version : new List<String>{'2','3'}) {
                String identityType=version=='2' ? 'name' : 'accountId';
                Map<String,Object> before=new Map<String,Object>{'reviewManagerPersonId'=>String.valueOf(first.Id),'reviewManagerIdentityType'=>identityType};
                Map<String,Object> incoming=new Map<String,Object>{'apiVersion'=>version,'projectKey'=>'DEMO'};
                Map<String,Object> kept=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Jira.validateSettingPreservingManager(JSON.serialize(incoming),before));
                System.assertEquals(String.valueOf(first.Id),kept.get('reviewManagerPersonId'));
                System.assertEquals(identityType,kept.get('reviewManagerIdentityType'));
                incoming.put('reviewManagerPersonId',String.valueOf(first.Id));
                kept=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Jira.validateSettingPreservingManager(JSON.serialize(incoming),before));
                System.assertEquals(identityType,kept.get('reviewManagerIdentityType'));
                incoming.put('reviewManagerIdentityType','');
                kept=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Jira.validateSettingPreservingManager(JSON.serialize(incoming),before));
                System.assertEquals('',kept.get('reviewManagerIdentityType'),'An explicit unconfirmed choice is not overwritten.');
                incoming.remove('reviewManagerIdentityType'); incoming.put('reviewManagerPersonId',String.valueOf(second.Id));
                kept=(Map<String,Object>)JSON.deserializeUntyped(Atlas_Jira.validateSettingPreservingManager(JSON.serialize(incoming),before));
                System.assertEquals(String.valueOf(second.Id),kept.get('reviewManagerPersonId'));
                System.assertEquals(null,kept.get('reviewManagerIdentityType'),'A new person cannot inherit confirmation.');
            }
            for (String invalid : new List<String>{null,'',' ','null','[]','{"reviewManagerIdentityType":true}','{"password":"not-a-real-secret"}'}) {
                try { Atlas_Jira.validateSettingPreservingManager(invalid,new Map<String,Object>{'reviewManagerPersonId'=>String.valueOf(first.Id),'reviewManagerIdentityType'=>'accountId'}); System.assert(false,invalid); }
                catch (Atlas_Api.AtlasException expected) { System.assertNotEquals(null,expected.getMessage()); }
            }
        }
    }
    @IsTest static void managerIdentityIsExplicitInManualCloudAndDataCenterModes() {
        System.runAs(Atlas_Mock.atlasUser()) { delete setting(); }
        System.runAs(member()) {
            Atlas_Person__c manager=new Atlas_Person__c(Name='Manual Manager',Active__c=true); insert manager;
            Map<String,Object> data=new Map<String,Object>{'projectKey'=>'DEMO','reviewManagerPersonId'=>manager.Id};
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals(false,Atlas_Jira.config().connected);
            System.assertEquals('missing_jira_id',Atlas_Jira.reviewManager().get('status'));
            manager.Jira_Account_Id__c='manager.username'; update manager;
            System.assertEquals('unconfirmed_identity',Atlas_Jira.reviewManager().get('status'));
            data.put('reviewManagerIdentityType','name'); Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals('identity_type_mismatch',Atlas_Jira.reviewManager().get('status'));
            data.put('apiVersion','2'); Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals(true,Atlas_Jira.reviewManager().get('ready'));
            System.assertEquals('name',Atlas_Jira.reviewManager().get('identityType'));
            System.assertEquals('manager.username',Atlas_Jira.reviewManager().get('jiraId'));
            System.assertEquals(0,Limits.getCallouts());
        }
    }
    @IsTest static void managerValidationAndRecoveryFailClosedWithoutGuessing() {
        System.runAs(member()) {
            for (String bad : new List<String>{'{"reviewManagerPersonId":42}','{"reviewManagerPersonId":"a name"}','{"reviewManagerIdentityType":"email"}','{"reviewManagerIdentityType":"AccountId"}','{"reviewManagerIdentityType":true}',
                JSON.serialize(new Map<String,Object>{'reviewManagerPersonId'=>UserInfo.getUserId()})}) {
                try { Atlas_Jira.validateSetting(bad); System.assert(false,bad); }
                catch (Atlas_Api.AtlasException expected) { System.assertNotEquals(null,expected.getMessage()); }
            }
            Atlas_Person__c inactive=new Atlas_Person__c(Name='Inactive review manager',Active__c=false); insert inactive;
            Map<String,Object> data=value(setting()); data.put('reviewManagerPersonId',inactive.Id);
            try { Atlas_Data.saveSetting('jira',JSON.serialize(data)); System.assert(false); }
            catch (AuraHandledException expected) { System.assert(expected.getMessage().contains('active')); }
            // An archive may reference a person absent in the destination. Preserve that reference,
            // but never silently select a similarly named person or route an escalation to them.
            Id absent=inactive.Id; delete inactive;
            data.put('reviewManagerIdentityType','accountId');
            Atlas_Setting__c saved=setting(); saved.Data__c=JSON.serialize(data); update saved;
            System.assertEquals(String.valueOf(absent),value(setting()).get('reviewManagerPersonId'));
            System.assertEquals('unavailable',Atlas_Jira.reviewManager().get('status'));
            System.assertEquals(false,Atlas_Jira.reviewManager().get('ready'));
            System.assertEquals('',Atlas_Jira.reviewManager().get('jiraId'));
        }
    }
    @IsTest static void linkedIdentityWarningsBlockManagerRouting() {
        System.runAs(member()) {
            Atlas_Person__c manager=new Atlas_Person__c(Name='Linked review manager',Active__c=true,Jira_Account_Id__c='saved-jira-id',User__c=UserInfo.getUserId()); insert manager;
            Atlas_Data.saveSetting('identity','{"ssoField":"FederationIdentifier"}');
            Map<String,Object> data=value(setting()); data.put('reviewManagerPersonId',manager.Id); data.put('reviewManagerIdentityType','accountId');
            Atlas_Data.saveSetting('jira',JSON.serialize(data));
            System.assertEquals('identity_warning',Atlas_Jira.reviewManager().get('status'));
            System.assertEquals(false,Atlas_Jira.reviewManager().get('ready'));
            System.assertEquals('',Atlas_Jira.reviewManager().get('jiraId'));
        }
    }
    @IsTest static void ordinaryUsersCannotEditConnectionsOrRevisionsDirectly() {
        System.runAs(member()) {
            System.assertEquals(false,Atlas_Jira.canConfigure());
            for (String key : new List<String>{'writeEnabled','namedCredential','apiBaseUrl','connectionRevision'}) {
                Atlas_Setting__c row=setting(); Map<String,Object> data=value(row);
                data.put(key,key=='writeEnabled' ? (Object)false : (Object)(key=='apiBaseUrl' ? 'https://other.example' : 'Changed'));
                row.Data__c=JSON.serialize(data);
                try { update row; System.assert(false,key); }
                catch (DmlException expected) { System.assert(expected.getMessage().contains('permission') || expected.getMessage().contains('administrator')); }
            }
            Atlas_Setting__c row=setting(); String original=value(row).get('connectionRevision').toString();
            Map<String,Object> data=value(row); data.put('projectKey','OTHER'); row.Data__c=JSON.serialize(data);
            update row;
            System.assertEquals(original,value(setting()).get('connectionRevision'));
        }
    }
    @IsTest static void deleteAndRenameOutAreProtected() {
        System.runAs(member()) {
            Atlas_Setting__c row=setting();
            try { delete row; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('administrator')); }
            row.Key__c='renamed';
            try { update row; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('administrator')); }
        }
    }
    @IsTest static void insertAndRenameIntoJiraAreProtectedButManualSettingsWork() {
        String connected=storedSetting().Data__c;
        System.runAs(Atlas_Mock.atlasUser()) { delete setting(); }
        System.runAs(member()) {
            try { insert new Atlas_Setting__c(Name='jira',Key__c='jira',Data__c=connected); System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('administrator') || expected.getMessage().contains('permission')); }
            Atlas_Setting__c renamed=new Atlas_Setting__c(Name='other',Key__c='other',Data__c=connected); insert renamed;
            renamed.Key__c='jira';
            try { update renamed; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('administrator') || expected.getMessage().contains('permission')); }
            Atlas_Data.saveSetting('jira','{"projectKey":"DEMO","siteUrl":"https://manual.example"}');
            System.assertEquals(false,Atlas_Jira.config().connected);
            Atlas_Data.saveSetting('jira','{"projectKey":"NEXT","siteUrl":"https://other-manual.example","readEnabled":false,"writeEnabled":false}');
            System.assertEquals('NEXT',value(setting()).get('projectKey'));
        }
    }
    @IsTest static void undeleteRequiresPermissionAndRotatesRevision() {
        Atlas_Setting__c row=storedSetting(); String original=(String)value(row).get('connectionRevision');
        System.runAs(Atlas_Mock.atlasUser()) { delete row; }
        System.runAs(member()) {
            try { undelete row; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('administrator')); }
        }
        System.runAs(Atlas_Mock.atlasUser()) {
            undelete row;
            System.assertNotEquals(original,value(setting()).get('connectionRevision'));
        }
    }
    @IsTest static void uppercaseJiraAndCaseOnlyRenamesRemainProtected() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Setting__c row=setting(); row.Key__c='JIRA'; update row;
            System.assertEquals(true,Atlas_Jira.config().connected);
        }
        System.runAs(member()) {
            Atlas_Setting__c row=setting(); row.Key__c='jira';
            try { update row; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('permission')); }
            row=setting(); Map<String,Object> data=value(row); data.put('writeEnabled',false); row.Data__c=JSON.serialize(data);
            try { update row; System.assert(false); }
            catch (DmlException expected) { System.assert(expected.getMessage().contains('permission')); }
        }
    }
    @IsTest static void disableEnableCannotRestoreReviewedFingerprint() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String fingerprint=Atlas_Jira.config().fingerprint;
            Atlas_Setting__c row=setting(); Map<String,Object> data=value(row); String revision=(String)data.get('connectionRevision');
            data.put('writeEnabled',false); row.Data__c=JSON.serialize(data); update row;
            data.put('writeEnabled',true); data.put('connectionRevision',revision); row.Data__c=JSON.serialize(data); update row;
            System.assertNotEquals(fingerprint,Atlas_Jira.config().fingerprint);
            System.assertNotEquals(revision,value(setting()).get('connectionRevision'));
        }
    }
}
