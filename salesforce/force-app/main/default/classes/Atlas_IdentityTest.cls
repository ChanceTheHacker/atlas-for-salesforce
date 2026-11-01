@IsTest
private class Atlas_IdentityTest {
    static Map<String,Object> lookup(String term) {
        return (Map<String,Object>)JSON.deserializeUntyped(Atlas_Identity.lookup(term));
    }
    static User user(String sso) {
        User user = Atlas_Mock.atlasUser();
        System.runAs(new User(Id=UserInfo.getUserId())) { update new User(Id=user.Id, FederationIdentifier=sso); }
        return user;
    }
    static void configure() { Atlas_Data.saveSetting('identity', '{"ssoField":"FederationIdentifier"}'); }

    @IsTest static void linkedSsoAndNamesResolveAcrossBothSystems() {
        User me = user('jira-sso-123');
        System.runAs(me) {
            configure();
            Id person = Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'name'=>'Christopher Example', 'userId'=>me.Id,
                'aliases'=>new List<String>{'Chris', 'CJ', 'Chris from support', '  CHRIS  ', 'Christopher E'}}));
            Atlas_Data.Person saved = Atlas_Data.people()[0];
            System.assertEquals('jira-sso-123', saved.jiraId);
            System.assertEquals(4, saved.aliases.size());
            System.assertEquals(null, saved.identityWarning);
            for (String name : new List<String>{'Chris', 'CJ', 'jira-sso-123', String.valueOf(me.Id), String.valueOf(person)}) {
                Map<String,Object> result = lookup(name);
                System.assertEquals('resolved', result.get('status'), name + ': ' + JSON.serialize(result));
                Map<String,Object> match = (Map<String,Object>)result.get('resolved');
                System.assertEquals(String.valueOf(me.Id), match.get('userId'));
                System.assertEquals('jira-sso-123', match.get('jiraId'));
                System.assertEquals(String.valueOf(person), match.get('personId'));
            }
            Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Research.run('{"op":"users","term":"CJ"}'));
            System.assertEquals('resolved', result.get('status'));
            System.assert(((Map<String,Object>)JSON.deserializeUntyped(Atlas_Data.bootstrap())).containsKey('settings'));
        }
    }

    @IsTest static void unsavedUsersCanBeResearchedWithoutWritingPeople() {
        User me = user('sso-unlinked');
        System.runAs(me) {
            configure();
            Map<String,Object> result = lookup('sso-unlinked');
            System.assertEquals('resolved', result.get('status'));
            Map<String,Object> match = (Map<String,Object>)result.get('resolved');
            System.assertEquals(null, match.get('personId'));
            System.assertEquals('sso-unlinked', match.get('jiraId'));
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Person__c]);
        }
    }

    @IsTest static void aliasesHaveRoomWithoutLosingLegacyNames() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c legacy = new Atlas_Person__c(Name='Legacy', Aliases__c='Old name, Older name', Jira_Account_Id__c='legacy');
            insert as user legacy;
            System.assertEquals(2, Atlas_Data.people()[0].aliases.size());
            List<String> names = new List<String>();
            for (Integer i=0; i<40; i++) names.add('A long alternative name ' + i);
            Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'id'=>legacy.Id, 'name'=>'Legacy', 'jiraId'=>'legacy', 'aliases'=>names}));
            System.assertEquals(40, Atlas_Data.people()[0].aliases.size());
            Atlas_Data.confirmAlias(legacy.Id, 'Last nickname');
            System.assertEquals(41, Atlas_Data.people()[0].aliases.size());
            System.assertEquals('resolved', lookup('Last nickname').get('status'));
        }
    }

    @IsTest static void invalidFieldsAndDuplicateLinksAreRejected() {
        System.runAs(user('sso-one')) {
            for (String field : new List<String>{'Password', 'FederationIdentifier FROM User', 'IsActive', 'NotAField__c'}) {
                try { Atlas_Data.saveSetting('identity', JSON.serialize(new Map<String,Object>{'ssoField'=>field})); System.assert(false); }
                catch (AuraHandledException e) { System.assert(e.getMessage().contains('text field')); }
            }
            configure();
            Id person = Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'name'=>'First', 'userId'=>UserInfo.getUserId()}));
            try { Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'name'=>'Second', 'userId'=>UserInfo.getUserId()})); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('already links')); }
            try { Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'id'=>person,'name'=>'First','jiraId'=>'wrong','userId'=>UserInfo.getUserId()})); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('must match')); }
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Person__c]);
            System.assert(Atlas_Identity.fields().size() > 0);
        }
    }

    @IsTest static void collisionsNeverChooseAFirstPerson() {
        System.runAs(Atlas_Mock.atlasUser()) {
            insert as user new List<Atlas_Person__c>{
                new Atlas_Person__c(Name='Chris One', Aliases__c='Chris', Jira_Account_Id__c='jira-one'),
                new Atlas_Person__c(Name='Chris Two', Aliases__c='Chris', Jira_Account_Id__c='jira-two')};
            Map<String,Object> result = lookup('Chris');
            System.assertEquals('ambiguous', result.get('status'));
            System.assertEquals(null, result.get('resolved'));
        }
    }

    @IsTest static void completedTicketReceiptsSurviveIdentityEdits() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Id person = Atlas_Data.savePerson('{"name":"Chris","jiraId":"jira-chris","aliases":["CJ"]}');
            Id conversation = Atlas_Data.saveConversation('{"title":"Identity receipt","mode":"Task"}');
            String input = JSON.serialize(new Map<String,Object>{'batchId'=>'identity-replay','tickets'=>new List<Object>{
                new Map<String,Object>{'ref'=>'T1','summary'=>'Assigned once','assigneeId'=>person}}});
            String prepared = Atlas_Tickets.prepareBatch(conversation, input);
            String first = Atlas_Tickets.applyBatch(conversation, prepared);
            update as user new Atlas_Person__c(Id=person, Jira_Account_Id__c='jira-new-chris');
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation, prepared));
            System.assertEquals(first, Atlas_Tickets.applyBatch(conversation, Atlas_Tickets.prepareBatch(conversation, input)),
                'Review-only identity versions must not change the original business receipt.');
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Ticket__c]);
        }
    }

    @IsTest static void staleSavedSsoBlocksResolutionAndStaleEditorCannotOverwrite() {
        User me = user('current-sso');
        System.runAs(me) {
            configure();
            Atlas_Person__c person = new Atlas_Person__c(Name='Stale', User__c=me.Id, Jira_Account_Id__c='old-sso', Aliases__c='Old nickname');
            insert as user person;
            System.assertEquals('conflict', lookup('Old nickname').get('status'));
            System.assertNotEquals(null, Atlas_Data.people()[0].identityWarning);
            try { Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{'id'=>person.Id, 'version'=>'0','name'=>'Changed','userId'=>me.Id})); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('changed since')); }
            System.assertEquals('Stale', [SELECT Name FROM Atlas_Person__c WHERE Id=:person.Id].Name);
        }
    }

    @IsTest static void managerRoleResolvesWithoutJiraEscalationConfirmation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c manager = new Atlas_Person__c(Name='Role Lead', Active__c=true,
                User__c=UserInfo.getUserId(), Jira_Account_Id__c='role-lead', Atlas_Is_Manager__c=true);
            insert as user manager;
            System.assertEquals(false, Atlas_Jira.reviewManager().get('ready'));
            for (String term : new List<String>{'manager', ' MY   MANAGER '}) {
                Map<String,Object> result = lookup(term);
                System.assertEquals('resolved', result.get('status'), JSON.serialize(result));
                Map<String,Object> match = (Map<String,Object>)result.get('resolved');
                System.assertEquals(String.valueOf(manager.Id), match.get('personId'));
                System.assertEquals(String.valueOf(UserInfo.getUserId()), match.get('userId'));
                System.assertEquals(new Set<Id>{manager.Id}, Atlas_Tickets.liveOwnerIds(term));
            }
        }
    }

    @IsTest static void managerAliasesCannotCreateRolesOrOverrideCollisions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c literal = new Atlas_Person__c(Name='Literal Alias', Active__c=true,
                Aliases__c='manager, my manager', Jira_Account_Id__c='literal-alias');
            insert as user literal;
            System.assertEquals('conflict', lookup('manager').get('status'), 'An alias cannot grant the role.');
            Atlas_Person__c manager = new Atlas_Person__c(Name='Role Lead', Active__c=true,
                Jira_Account_Id__c='role-lead', Atlas_Is_Manager__c=true);
            insert as user manager;
            for (String term : new List<String>{'manager', 'my manager'}) {
                System.assertEquals('ambiguous', lookup(term).get('status'));
                try { Atlas_Tickets.liveOwnerIds(term); System.assert(false, 'Do not choose a colliding role.'); }
                catch (Atlas_Api.AtlasException e) { System.assert(e.getMessage().contains('not a unique')); }
            }
            update as user new Atlas_Person__c(Id=literal.Id, Aliases__c='ordinary nickname');
            System.assertEquals('resolved', lookup('manager').get('status'));
            Database.SaveResult rejected = Database.update(new Atlas_Person__c(Id=literal.Id, Atlas_Is_Manager__c=true), false, AccessLevel.USER_MODE);
            System.assertEquals(false, rejected.isSuccess(), 'A colliding Manager role must be rejected before it is saved.');
            System.assert(rejected.getErrors()[0].getMessage().contains('Only one Manager'), rejected.getErrors()[0].getMessage());
            System.assertEquals(false, [SELECT Atlas_Is_Manager__c FROM Atlas_Person__c WHERE Id=:literal.Id].Atlas_Is_Manager__c);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Person__c WHERE Atlas_Is_Manager__c=true]);
            for (String term : new List<String>{'manager', 'my manager'}) {
                Map<String,Object> result = lookup(term);
                System.assertEquals('resolved', result.get('status'));
                System.assertEquals(String.valueOf(manager.Id), ((Map<String,Object>)result.get('resolved')).get('personId'));
                System.assertEquals(new Set<Id>{manager.Id}, Atlas_Tickets.liveOwnerIds(term));
            }
        }
    }

    @IsTest static void legacyManagerAndInactiveManagerRolesFailSafely() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c manager = new Atlas_Person__c(Name='Legacy Role Lead', Active__c=true,
                Jira_Account_Id__c='legacy-role-lead');
            insert as user manager;
            insert as user new Atlas_Setting__c(Key__c='jira', Data__c=JSON.serialize(new Map<String,Object>{
                'reviewManagerPersonId'=>manager.Id, 'reviewManagerIdentityType'=>'accountId'}));
            System.assertEquals(String.valueOf(manager.Id), ((Map<String,Object>)lookup('my manager').get('resolved')).get('personId'));
            update as user new Atlas_Person__c(Id=manager.Id, Active__c=false);
            System.assertEquals('conflict', lookup('manager').get('status'));
            System.assertEquals(null, lookup('my manager').get('resolved'));
        }
    }

    @IsTest static void anAliasReclaimedFromAnInactivePersonResolvesToTheActiveOne() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Person__c former = new Atlas_Person__c(Name='Former Lead', Aliases__c='Support lead', Jira_Account_Id__c='jira-former', Active__c=false);
            insert as user former;
            Atlas_Data.savePerson(JSON.serialize(new Map<String,Object>{
                'name'=>'Current Lead', 'aliases'=>new List<String>{'Support lead'}, 'jiraId'=>'jira-current', 'active'=>true}));
            Map<String,Object> result = lookup('Support lead');
            System.assertEquals('resolved', result.get('status'), JSON.serialize(result));
            System.assertEquals('Current Lead', ((Map<String,Object>)result.get('resolved')).get('name'));
            System.assertEquals('not_found', lookup('Former Lead').get('status'), 'An inactive person no longer owns their name.');
            Map<String,Object> byId = lookup('jira-former');
            System.assertEquals('conflict', byId.get('status'), 'An explicit ID still finds the inactive person, flagged as inactive.');
        }
    }
}
