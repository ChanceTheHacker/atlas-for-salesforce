/**
 * Start-up data, people, settings and conversations for the Atlas component.
 */
public with sharing class Atlas_Data {
    public static final Integer MAX_BODY = 131072;
    static final String UAT_INTAKE_TYPE = 'atlas-uat-intake';
    static final Integer UAT_INTAKE_VERSION = 1;
    static final Set<String> CONVERSATION_MODES = new Set<String>{'Source', 'Task', 'Files', 'support-tickets', 'uat'};
    static final Set<String> UAT_COMPONENT_TYPES = new Set<String>{'Flow', 'Apex', 'LWC', 'Other'};

    public static String aliasKey(String value) {
        return value == null ? '' : value.normalizeSpace().toLowerCase();
    }

    /** Aliases are stored comma separated. */
    public static Set<String> aliases(String raw) {
        Set<String> keys = new Set<String>();
        if (raw == null) return keys;
        for (String part : raw.split('[,;\\n]')) {
            if (String.isNotBlank(part)) keys.add(aliasKey(part));
        }
        return keys;
    }

    public class Person {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String jiraId;
        @AuraEnabled public List<String> aliases = new List<String>();
        @AuraEnabled public String userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String email;
        @AuraEnabled public String loginName;
        @AuraEnabled public String ssoId;
        @AuraEnabled public String identityWarning;
        @AuraEnabled public String version;
        @AuraEnabled public String managerId;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Boolean isMe = false;
        @AuraEnabled public Boolean isMyReport = false;
        @AuraEnabled public Boolean isManager = false;
        @AuraEnabled public String jiraIdentityType;
    }

    public static List<Person> people() {
        PeoplePage page = peoplePage(null);
        if (page.nextCursor != null) throw new Atlas_Api.AtlasException('Use peoplePage to read the complete people directory.');
        return page.people;
    }

    public class PeoplePage {
        @AuraEnabled public List<Person> people = new List<Person>();
        @AuraEnabled public String nextCursor;
    }

    @AuraEnabled
    public static PeoplePage peoplePage(Id afterId) {
        if (afterId != null && afterId.getSObjectType() != Atlas_Person__c.SObjectType)
            throw Atlas_Api.fail(new Atlas_Api.AtlasException('Invalid people cursor.'));
        Map<String,Object> legacyManager = Atlas_Jira.legacyManagerSetting();
        String legacyId = (String)legacyManager.get('reviewManagerPersonId');
        String query = 'SELECT Id, Name, Jira_Account_Id__c, Atlas_Is_Manager__c, Atlas_Jira_Identity_Type__c, Aliases__c, Alias_List__c, LastModifiedDate, User__c, User__r.Name, Manager__c, Manager__r.User__c, Active__c'
            + ' FROM Atlas_Person__c' + (afterId == null ? '' : ' WHERE Id > :afterId') + ' ORDER BY Id LIMIT 201';
        List<Atlas_Person__c> records = Database.query(query, AccessLevel.USER_MODE);
        PeoplePage page = new PeoplePage();
        if (records.size() > 200) {
            records.remove(200);
            page.nextCursor = records[199].Id;
        }
        for (Atlas_Person__c record : records) {
            Person p = new Person();
            p.id = record.Id;
            p.name = record.Name;
            p.jiraId = record.Jira_Account_Id__c;
            p.isManager = record.Atlas_Is_Manager__c || String.valueOf(record.Id) == legacyId;
            p.jiraIdentityType = record.Atlas_Is_Manager__c ? record.Atlas_Jira_Identity_Type__c
                : String.valueOf(record.Id) == legacyId ? (String)legacyManager.get('reviewManagerIdentityType') : record.Atlas_Jira_Identity_Type__c;
            p.aliases = Atlas_Identity.names(record);
            p.version = String.valueOf(record.LastModifiedDate.getTime());
            p.userId = record.User__c;
            p.userName = record.User__r?.Name;
            p.managerId = record.Manager__c;
            p.active = record.Active__c;
            p.isMe = record.User__c == UserInfo.getUserId();
            p.isMyReport = record.Manager__r?.User__c == UserInfo.getUserId();
            page.people.add(p);
        }
        Atlas_Identity.enrich(page.people);
        return page;
    }

    @AuraEnabled
    public static String bootstrap() {
        try {
            Organization org = [SELECT Id, Name, IsSandbox, OrganizationType, NamespacePrefix FROM Organization WITH USER_MODE LIMIT 1];
            Map<String, Object> settings = new Map<String, Object>();
            for (Atlas_Setting__c setting : [
                SELECT Key__c, Data__c FROM Atlas_Setting__c
                WHERE Key__c IN ('jira', 'jira-mapping', 'identity') OR Key__c = :userKey() WITH USER_MODE
            ]) {
                settings.put(setting.Key__c == userKey() ? 'mine' : setting.Key__c, setting.Data__c);
            }
            PeoplePage directory = peoplePage(null);
            return JSON.serialize(new Map<String, Object>{
                'user' => new Map<String, Object>{ 'id' => UserInfo.getUserId(), 'name' => UserInfo.getName() },
                'org' => new Map<String, Object>{
                    'id' => org.Id, 'name' => org.Name, 'isSandbox' => org.IsSandbox, 'edition' => org.OrganizationType,
                    'namespace' => org.NamespacePrefix, 'domain' => Url.getOrgDomainUrl().toExternalForm()
                },
                'objects' => new Map<String, Object>{
                    'ticket' => Schema.SObjectType.Atlas_Ticket__c.getName(),
                    'person' => Schema.SObjectType.Atlas_Person__c.getName(),
                    'change' => Schema.SObjectType.Atlas_Change__c.getName(),
                    'conversation' => Schema.SObjectType.Atlas_Conversation__c.getName()
                },
                'people' => directory.people,
                'peopleCursor' => directory.nextCursor,
                'settings' => settings,
                'conversations' => conversations()
            });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    // ---------------------------------------------------------------- people

    // The unique external key also serializes the first concurrent insert. A lock
    // conflict fails before the scan/write; it must never fall back to unlocked DML.
    public static void lockPeople() {
        try {
            upsert as user new Atlas_Setting__c(Name='Atlas people lock', Key__c='people-lock') Key__c;
            Atlas_Setting__c serial = [SELECT Id FROM Atlas_Setting__c WHERE Key__c='people-lock' WITH USER_MODE FOR UPDATE];
        } catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE || e.getDmlType(0) == StatusCode.UNABLE_TO_LOCK_ROW)
                throw new Atlas_Api.AtlasException('Another person save is in progress. Retry after it finishes; no identity was changed.');
            throw e;
        }
    }

    /**
     * Why this person would clash with someone already saved: the same Salesforce user, or a
     * name or alias that would then point to two active people. Null when there is no clash.
     * Shared by saving and by workspace recovery; call it after lockPeople.
     */
    public static String personConflict(Id recordId, String name, List<String> aliasList, Id userId, Boolean active) {
        Set<String> mine = new Set<String>();
        for (String alias : aliasList) mine.add(aliasKey(alias));
        mine.add(aliasKey(name));
        for (Atlas_Person__c other : [SELECT Name, Aliases__c, Alias_List__c, User__c, Active__c FROM Atlas_Person__c WHERE Id != :recordId WITH USER_MODE]) {
            if (userId != null && other.User__c == userId) return 'This Salesforce user already links to ' + other.Name + '. Edit that person and add their other names there.';
            if (!other.Active__c || active == false) continue;
            Set<String> theirs = new Set<String>();
            for (String alias : Atlas_Identity.names(other)) theirs.add(aliasKey(alias));
            theirs.add(aliasKey(other.Name));
            theirs.retainAll(mine);
            if (!theirs.isEmpty()) return '"' + new List<String>(theirs)[0] + '" already points to ' + other.Name + '. Each name or alias must identify one person.';
        }
        return null;
    }

    @AuraEnabled
    public static String savePerson(String personJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(personJson);
            String name = String.valueOf(input.get('name') ?? '').normalizeSpace();
            String jiraId = String.valueOf(input.get('jiraId') ?? '').trim();
            List<String> aliasList = Atlas_Identity.cleanNames((List<Object>)(input.get('aliases') ?? new List<Object>()));
            Id userId = (Id)input.get('userId');
            if (userId != null) {
                if (userId.getSObjectType() != User.SObjectType) throw new Atlas_Api.AtlasException('Choose a Salesforce User, not another record type.');
                String field = Atlas_Identity.fieldName();
                User linked = Atlas_Identity.users(new Set<Id>{userId}, field).get(userId);
                if (linked == null) throw new Atlas_Api.AtlasException('That Salesforce user is not accessible.');
                if (field != null) {
                    String sso = Atlas_Identity.sso(linked, field);
                    if (String.isBlank(sso)) throw new Atlas_Api.AtlasException('The configured SSO field is empty for this Salesforce user.');
                    if (String.isNotBlank(jiraId) && jiraId != sso) throw new Atlas_Api.AtlasException('Jira ID must match the selected Salesforce user\'s SSO field. Review the value before saving.');
                    jiraId = sso;
                    List<User> duplicates = Database.query('SELECT Id FROM User WHERE ' + field + ' = :jiraId LIMIT 2', AccessLevel.USER_MODE);
                    if (duplicates.size() > 1) throw new Atlas_Api.AtlasException('More than one Salesforce user has this SSO ID. Resolve that conflict before linking.');
                }
                if (String.isBlank(name)) name = linked.Name;
            }
            if (String.isBlank(name) || name.length() > 80) throw new Atlas_Api.AtlasException('Enter a name of at most 80 characters.');
            if (String.isNotBlank(jiraId) && !Pattern.matches('[^\\s,=+@-][^\\s,]{0,127}', jiraId)) {
                throw new Atlas_Api.AtlasException('Enter the Jira account ID exactly as Jira shows it (no spaces or commas).');
            }
            String joined = String.join(aliasList, ', ');
            Id recordId = (Id) input.get('id');
            // A cleared Reports To arrives as an empty string; that means no manager, not an invalid Id.
            Id managerId = String.isBlank((String) input.get('managerId')) ? null : (Id) input.get('managerId');
            if (managerId != null && managerId.getSObjectType() != Atlas_Person__c.SObjectType) throw new Atlas_Api.AtlasException('Reports To must be a person in Atlas.');
            if (managerId != null && managerId == recordId) throw new Atlas_Api.AtlasException('A person cannot report to themselves.');
            lockPeople();
            if (recordId != null && input.get('version') != null) {
                Atlas_Person__c current = [SELECT LastModifiedDate FROM Atlas_Person__c WHERE Id = :recordId WITH USER_MODE FOR UPDATE];
                if (String.valueOf(current.LastModifiedDate.getTime()) != (String)input.get('version'))
                    throw new Atlas_Api.AtlasException('This person changed since you opened the editor. Reload and review; nothing was overwritten.');
            }
            String clash = personConflict(recordId, name, aliasList, userId, input.get('active') != false);
            if (clash != null) throw new Atlas_Api.AtlasException(clash);
            Atlas_Person__c record = new Atlas_Person__c(
                Id = recordId,
                Name = name,
                Jira_Account_Id__c = String.isBlank(jiraId) ? null : jiraId,
                Aliases__c = joined.length() <= 255 ? joined : null,
                Alias_List__c = JSON.serialize(aliasList),
                User__c = userId,
                Manager__c = managerId,
                Active__c = input.get('active') != false
            );
            if (input.containsKey('isManager')) {
                if (!(input.get('isManager') instanceof Boolean)) throw new Atlas_Api.AtlasException('Manager must be true or false.');
                record.Atlas_Is_Manager__c = (Boolean)input.get('isManager');
            }
            if (input.containsKey('jiraIdentityType')) {
                String identityType = (String)input.get('jiraIdentityType');
                if (String.isNotBlank(identityType) && !identityType.equals('accountId') && !identityType.equals('name'))
                    throw new Atlas_Api.AtlasException('Confirm the Jira ID as a Cloud account ID or Data Center username, or leave it unconfirmed.');
                record.Atlas_Jira_Identity_Type__c = String.isBlank(identityType) ? null : identityType;
            }
            // A deleted legacy person cannot be edited in People. A new explicit role save may
            // replace only a globally absent person, never someone merely hidden by sharing.
            if (input.get('isManager') == true) Atlas_Jira.clearMissingLegacyManager();
            upsert as user record;
            // Only an explicit person-role save consumes the old selection. Old clients and alias
            // confirmations omit this property and therefore cannot silently clear or migrate it.
            if (input.containsKey('isManager')) Atlas_Jira.migrateManager(record.Id, (Boolean)input.get('isManager'), input.containsKey('jiraIdentityType'));
            return record.Id;
        } catch (DmlException e) {
            Database.rollback(sp);
            String message = e.getDmlType(0) == StatusCode.DUPLICATE_VALUE
                ? 'Another person already has that Jira account ID.' : e.getDmlMessage(0);
            throw Atlas_Api.fail(new Atlas_Api.AtlasException(message));
        } catch (Exception e) {
            Database.rollback(sp);
            throw Atlas_Api.fail(e);
        }
    }

    /** Finds Salesforce users for linking a person. */
    @AuraEnabled
    public static List<Map<String, String>> findUsers(String term) {
        // A bind variable needs no quote escaping (O'Brien must match); only LIKE wildcards are escaped.
        String needle = '%' + (term == null ? '' : term.trim()).replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (User user : [SELECT Id, Name, Username FROM User WHERE IsActive = true AND (Name LIKE :needle OR Username LIKE :needle) WITH USER_MODE ORDER BY Name LIMIT 20]) {
            result.add(new Map<String, String>{ 'id' => user.Id, 'name' => user.Name, 'username' => user.Username });
        }
        return result;
    }

    // ---------------------------------------------------------------- settings

    static String userKey() {
        return 'user:' + UserInfo.getUserId();
    }

    /** Team settings ("jira", "jira-mapping") or my own ("mine"). */
    @AuraEnabled
    public static void saveSetting(String key, String data) {
        try {
            if (key != 'jira' && key != 'jira-mapping' && key != 'mine' && key != 'identity') throw new Atlas_Api.AtlasException('Unknown setting ' + key);
            if (key == 'jira') data = Atlas_Jira.validateConnectionSetting(data);
            if (key == 'identity') {
                Map<String,Object> config = String.isBlank(data) ? new Map<String,Object>() : (Map<String,Object>)JSON.deserializeUntyped(data);
                data = JSON.serialize(new Map<String,Object>{'ssoField' => Atlas_Identity.validateField((String)config.get('ssoField'))});
            }
            if (data != null && data.length() > MAX_BODY) {
                throw new Atlas_Api.AtlasException('This setting is too large (' + data.length() + ' characters; the limit is ' + MAX_BODY + ').');
            }
            String stored = key == 'mine' ? userKey() : key;
            upsert as user new Atlas_Setting__c(Name = stored, Key__c = stored, Data__c = data) Key__c;
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    // ---------------------------------------------------------------- conversations

    public static String conversationMode(Id conversationId) {
        if (conversationId == null) return null;
        List<Atlas_Conversation__c> rows = [SELECT Mode__c FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE];
        if (rows.isEmpty()) throw new Atlas_Api.AtlasException('That conversation is missing or is not shared with you. Reload it before continuing.');
        return rows[0].Mode__c;
    }

    public static Boolean isSupportTicketsConversation(Id conversationId) {
        return conversationId != null && conversationMode(conversationId) == 'support-tickets';
    }

    public static Boolean isUATConversation(Id conversationId) {
        return conversationId != null && conversationMode(conversationId) == 'uat';
    }

    public static void assertSourceChangesAllowed(Id conversationId) {
        String mode = conversationMode(conversationId);
        if (mode == 'support-tickets') throw new Atlas_Api.AtlasException(
            'Support Tickets investigates without changing Salesforce. Read source through research, and send suspected bugs for manager review in Jira.');
        if (mode == 'uat') throw new Atlas_Api.AtlasException(
            'UAT conversations can research and save test documents, but cannot back up, propose, deploy, or restore Salesforce source.');
    }

    public static void assertTicketMutationsAllowed(Id conversationId) {
        if (conversationId == null) return;
        assertTicketMutationsAllowed(new Set<Id>{conversationId});
    }

    public static void assertTicketMutationsAllowed(Id conversationId, Atlas_Conversation__c savedConversation) {
        if (conversationId == null) return;
        if (savedConversation == null || savedConversation.Id != conversationId) throw new Atlas_Api.AtlasException(
            'Atlas could not verify the saved mode for this conversation. Nothing was changed.');
        assertTicketModeAllowed(savedConversation.Mode__c);
    }

    static void assertTicketModeAllowed(String mode) {
        if (mode == 'uat') throw new Atlas_Api.AtlasException(
            'UAT conversations can research and save test documents, but cannot create or change local tickets.');
    }

    public static void assertTicketMutationsAllowed(Set<Id> conversationIds) {
        if (conversationIds == null || conversationIds.isEmpty()) return;
        List<Atlas_Conversation__c> conversations = [SELECT Id, Mode__c FROM Atlas_Conversation__c
            WHERE Id IN :conversationIds WITH USER_MODE];
        if (conversations.size() != conversationIds.size()) throw new Atlas_Api.AtlasException(
            'Atlas could not verify the saved mode for every conversation. Nothing was changed.');
        for (Atlas_Conversation__c conversation : conversations) assertTicketModeAllowed(conversation.Mode__c);
    }

    public static void assertJiraWritesAllowed(Id conversationId) {
        if (isUATConversation(conversationId)) throw new Atlas_Api.AtlasException(
            'UAT conversations can research and save test documents, but cannot write to Jira.');
    }

    static Map<String, Object> validateUatIntake(Object raw) {
        if (!(raw instanceof Map<String, Object>)) throw new Atlas_Api.AtlasException('UAT intake must include componentType, apiName, goal and testing fields.');
        Map<String, Object> input = (Map<String, Object>)raw;
        Set<String> allowed = new Set<String>{'componentType', 'apiName', 'goal', 'testing'};
        for (String key : input.keySet()) if (!allowed.contains(key)) throw new Atlas_Api.AtlasException('Unsupported UAT intake field: ' + key + '.');
        String componentType = input.get('componentType') instanceof String ? (String)input.get('componentType') : null;
        String apiName = input.get('apiName') instanceof String ? (String)input.get('apiName') : null;
        String goal = input.get('goal') instanceof String ? (String)input.get('goal') : null;
        String testing = input.get('testing') == null ? '' : input.get('testing') instanceof String ? (String)input.get('testing') : null;
        if (!UAT_COMPONENT_TYPES.contains(componentType)) throw new Atlas_Api.AtlasException('Choose Flow, Apex, LWC or Other for the UAT component type.');
        if (String.isBlank(apiName) || apiName.length() > 255) throw new Atlas_Api.AtlasException('UAT apiName is required and must be at most 255 characters.');
        if (String.isBlank(goal) || goal.length() > 2000) throw new Atlas_Api.AtlasException('UAT goal is required and must be at most 2,000 characters.');
        if (testing == null || testing.length() > 2000) throw new Atlas_Api.AtlasException('UAT testing must be text of at most 2,000 characters.');
        if (componentType == 'Other' && String.isBlank(testing)) throw new Atlas_Api.AtlasException('UAT testing instructions are required for Other components.');
        return new Map<String, Object>{'componentType' => componentType, 'apiName' => apiName, 'goal' => goal, 'testing' => testing};
    }

    static String uatEnvelope(String request, Map<String, Object> uat) {
        return JSON.serialize(new Map<String, Object>{'type' => UAT_INTAKE_TYPE, 'version' => UAT_INTAKE_VERSION, 'request' => request, 'uat' => uat});
    }

    static Map<String, Object> decodeConversationRequest(String stored) {
        Map<String, Object> result = new Map<String, Object>{'request' => stored};
        if (stored == null) return result;
        Object parsed;
        try { parsed = JSON.deserializeUntyped(stored); }
        catch (Exception notJson) { return result; }
        if (!(parsed instanceof Map<String, Object>)) return result;
        Map<String, Object> envelope = (Map<String, Object>)parsed;
        if (envelope.get('type') != UAT_INTAKE_TYPE) return result;
        if (String.valueOf(envelope.get('version')) != String.valueOf(UAT_INTAKE_VERSION)
            || !(envelope.get('request') instanceof String) || !(envelope.get('uat') instanceof Map<String, Object>))
            throw new Atlas_Api.AtlasException('Saved UAT intake is incomplete or uses an unsupported version; preserve the original recovery export before editing it.');
        result.put('request', envelope.get('request'));
        result.put('uat', validateUatIntake(envelope.get('uat')));
        return result;
    }

    static String savedRequest(Atlas_Conversation__c conversation) {
        if (conversation.Request_File__c == null) return conversation.Request__c;
        return [SELECT VersionData FROM ContentVersion WHERE Id = :conversation.Request_File__c WITH USER_MODE].VersionData.toString();
    }

    public static List<Map<String, Object>> conversations() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Atlas_Conversation__c c : [
            SELECT Id, Name, Mode__c, Status__c, LastModifiedDate FROM Atlas_Conversation__c
            WHERE OwnerId = :UserInfo.getUserId() WITH USER_MODE ORDER BY LastModifiedDate DESC LIMIT 50
        ]) {
            result.add(new Map<String, Object>{
                'id' => c.Id, 'title' => c.Name, 'mode' => c.Mode__c, 'status' => c.Status__c, 'updated' => c.LastModifiedDate
            });
        }
        return result;
    }

    @AuraEnabled
    public static String conversationPage(Id afterId) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        Id owner = UserInfo.getUserId();
        String query = 'SELECT Id, Name, Mode__c, Status__c, LastModifiedDate FROM Atlas_Conversation__c WHERE OwnerId = :owner'
            + (afterId == null ? '' : ' AND Id < :afterId') + ' ORDER BY Id DESC LIMIT 50';
        for (Atlas_Conversation__c c : Database.query(query, AccessLevel.USER_MODE)) result.add(new Map<String, Object>{
            'id' => c.Id, 'title' => c.Name, 'mode' => c.Mode__c, 'status' => c.Status__c, 'updated' => c.LastModifiedDate
        });
        return JSON.serialize(new Map<String, Object>{'rows' => result,
            'cursor' => result.size() == 50 ? result[49].get('id') : null});
    }

    /** Only immutable input failures unlock editing. No DML or callouts precede this response;
     * these same inputs could not have committed through startConversation on an earlier try.
     * All permission, governor, DML and transport failures still throw and keep the retry pinned. */
    @AuraEnabled
    public static String startConversationChecked(String conversationJson, String prompt, String nonce) {
        String problem;
        try {
            Map<String,Object> input = (Map<String,Object>)JSON.deserializeUntyped(conversationJson);
            if (input == null) problem = 'Conversation JSON must be an object.';
            else if (String.valueOf(input.get('title') ?? '').normalizeSpace().length() > 80) problem = 'Conversation title exceeds 80 characters; shorten it without losing your request.';
            else if (input.get('request') != null && ((String)input.get('request')).length() > 1500000) problem = 'Request exceeds 1,500,000 characters. Split it or save context separately.';
            String mode = input == null || input.get('mode') == null ? null : String.valueOf(input.get('mode'));
            if (problem == null && mode != null && !CONVERSATION_MODES.contains(mode)) problem = 'Choose a supported Atlas conversation mode.';
            if (problem == null && mode == 'uat') {
                String request = (String)input.get('request');
                if (String.isBlank(request) || request.length() > 30000) problem = 'UAT request is required and must be at most 30,000 characters.';
                else validateUatIntake(input.get('uat'));
            } else if (problem == null && input != null && input.containsKey('uat')) problem = 'UAT intake is only valid for UAT conversations.';
            String suffix = '\nConversation requestId: 000000000000000000. Include this requestId in every JSON reply.';
            if (problem == null && prompt != null && prompt.length() + suffix.length() > 1500000) problem = 'The first message, including attachments, exceeds 1,500,000 characters. Remove an attachment or split the context; nothing was started.';
            if (problem == null && (String.isBlank(nonce) || nonce.length() > 80)) problem = 'A valid creation receipt is required. Correct the draft and retry Start.';
        } catch (Atlas_Api.AtlasException e) { problem = e.getMessage(); }
        catch (Exception e) { problem = 'Conversation JSON has invalid field types. Correct or recover the draft before retrying.'; }
        if (problem != null) return JSON.serialize(new Map<String,Object>{'code' => 'ATLAS_START_INPUT_REJECTED', 'message' => problem});
        return startConversation(conversationJson, prompt, nonce);
    }

    /** Conversation and initial prompt commit together; response-loss retries return the same record. */
    @AuraEnabled
    public static String startConversation(String conversationJson, String prompt, String nonce) {
        try {
            if (String.isBlank(nonce) || nonce.length() > 80) throw new Atlas_Api.AtlasException('A creation receipt is required. Reload the new conversation form.');
            String key = Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId() + ':' + nonce + ':' + conversationJson + ':' + prompt));
            List<Atlas_Conversation__c> existing = [SELECT Id FROM Atlas_Conversation__c WHERE Creation_Key__c = :key WITH USER_MODE];
            if (!existing.isEmpty()) return existing[0].Id;
            Map<String,Object> input = (Map<String,Object>)JSON.deserializeUntyped(conversationJson);
            input.remove('id');
            Id id = saveConversation(JSON.serialize(input));
            update as user new Atlas_Conversation__c(Id = id, Creation_Key__c = key);
            addMessage(id, 'To Agent', 'prompt', prompt + '\nConversation requestId: ' + id + '. Include this requestId in every JSON reply.');
            return id;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String saveConversation(String conversationJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(conversationJson);
            if (input == null) throw new Atlas_Api.AtlasException('Conversation JSON must be an object.');
            String title = String.valueOf(input.get('title') ?? '').normalizeSpace();
            if (input.containsKey('request') && input.get('request') != null && !(input.get('request') instanceof String))
                throw new Atlas_Api.AtlasException('Conversation request must be plain text.');
            String request = (String) input.get('request');
            Id id = (Id)input.get('id');
            if (title.length() > 80) throw new Atlas_Api.AtlasException('Conversation title exceeds 80 characters; shorten it without losing your request.');
            if (request != null && request.length() > 1500000) throw new Atlas_Api.AtlasException('Request exceeds 1,500,000 characters. Split the source documents; nothing was saved.');

            Atlas_Conversation__c current;
            if (id != null) {
                List<Atlas_Conversation__c> rows = [SELECT Id, Mode__c, Request__c, Request_File__c FROM Atlas_Conversation__c
                    WHERE Id = :id WITH USER_MODE FOR UPDATE];
                if (rows.isEmpty()) throw new Atlas_Api.AtlasException('That conversation is missing or is not shared with you. Reload it before continuing.');
                current = rows[0];
            }
            if (input.containsKey('mode') && input.get('mode') != null && !(input.get('mode') instanceof String))
                throw new Atlas_Api.AtlasException('Conversation mode must be a supported text value.');
            String requestedMode = input.containsKey('mode') ? (String)input.get('mode') : null;
            if (requestedMode != null && !CONVERSATION_MODES.contains(requestedMode)) throw new Atlas_Api.AtlasException('Choose a supported Atlas conversation mode.');
            if (current != null && input.containsKey('mode') && current.Mode__c != requestedMode)
                throw new Atlas_Api.AtlasException('A conversation cannot change modes after it starts. Start a new conversation instead.');
            String mode = input.containsKey('mode') ? requestedMode : current?.Mode__c;
            if (input.containsKey('uat') && mode != 'uat') throw new Atlas_Api.AtlasException('UAT intake is only valid for UAT conversations.');

            Atlas_Conversation__c record = new Atlas_Conversation__c(Id = id);
            if (id == null || input.containsKey('title')) record.Name = String.isBlank(title) ? 'Untitled' : title;
            if (input.containsKey('mode')) record.Mode__c = requestedMode;
            if (input.containsKey('status')) record.Status__c = (String) input.get('status');

            Boolean saveRequest = false;
            String requestToStore;
            if (mode == 'uat' && (id == null || input.containsKey('request') || input.containsKey('uat'))) {
                Map<String, Object> prior = current == null ? new Map<String, Object>() : decodeConversationRequest(savedRequest(current));
                String fullRequest = input.containsKey('request') ? request : (String)prior.get('request');
                Object intakeInput = input.containsKey('uat') ? input.get('uat') : prior.get('uat');
                if (String.isBlank(fullRequest) || fullRequest.length() > 30000)
                    throw new Atlas_Api.AtlasException('UAT request is required and must be at most 30,000 characters.');
                Map<String, Object> intake = validateUatIntake(intakeInput);
                requestToStore = uatEnvelope(fullRequest, intake);
                saveRequest = true;
            } else if (input.containsKey('request')) {
                requestToStore = request;
                saveRequest = true;
            }
            if (saveRequest) {
                if (requestToStore != null && requestToStore.length() > 1500000) throw new Atlas_Api.AtlasException('Request exceeds 1,500,000 characters. Split the source documents; nothing was saved.');
                record.Request__c = requestToStore == null ? null : requestToStore.left(1000);
                record.Request_File__c = null;
            }
            upsert as user record;
            if (saveRequest && requestToStore != null && requestToStore.length() > 1000) {
                Boolean uatEnvelope = mode == 'uat';
                ContentVersion file = new ContentVersion(Title = uatEnvelope ? 'Atlas UAT intake' : 'Atlas complete request',
                    PathOnClient = uatEnvelope ? 'uat-intake.json' : 'request.txt', VersionData = Blob.valueOf(requestToStore), FirstPublishLocationId = record.Id);
                insert as user file;
                update as user new Atlas_Conversation__c(Id = record.Id, Request_File__c = file.Id);
            }
            return record.Id;
        } catch (Exception e) {
            Database.rollback(sp);
            throw Atlas_Api.fail(e);
        }
    }

    @AuraEnabled
    public static String getConversation(Id conversationId) {
        try {
            Atlas_Conversation__c c = [
                SELECT Id, Name, Mode__c, Status__c, Request__c, Request_File__c, CreatedDate,
                    (SELECT Id, Name, Direction__c, Kind__c, Body__c, Body_File__c, CreatedDate FROM Messages__r ORDER BY CreatedDate DESC, Id DESC LIMIT 40)
                FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE
            ];
            // The query returns the newest 40; the component shows them oldest first.
            List<Map<String, Object>> messages = new List<Map<String, Object>>();
            List<Atlas_Message__c> newestFirst = c.Messages__r;
            for (Integer i = newestFirst.size() - 1; i >= 0; i--) {
                Atlas_Message__c m = newestFirst[i];
                messages.add(new Map<String, Object>{
                    'id' => m.Name, 'recordId' => m.Id, 'direction' => m.Direction__c, 'kind' => m.Kind__c,
                    'body' => i == 0 && m.Body_File__c != null ? messageBody(m) : m.Body__c,
                    'hasFullBody' => i != 0 && m.Body_File__c != null, 'created' => m.CreatedDate
                });
            }
            List<Map<String, Object>> changes = new List<Map<String, Object>>();
            for (Atlas_Change__c change : [
                SELECT Id, Name, Status__c, Summary__c FROM Atlas_Change__c WHERE Conversation__c = :conversationId WITH USER_MODE ORDER BY CreatedDate
            ]) {
                changes.add(new Map<String, Object>{ 'id' => change.Id, 'name' => change.Name, 'status' => change.Status__c, 'summary' => change.Summary__c });
            }
            String storedRequest = savedRequest(c);
            Map<String, Object> saved = c.Mode__c == 'uat' ? decodeConversationRequest(storedRequest) : new Map<String, Object>{'request' => storedRequest};
            Map<String, Object> response = new Map<String, Object>{
                'id' => c.Id, 'title' => c.Name, 'mode' => c.Mode__c, 'status' => c.Status__c,
                'request' => saved.get('request'), 'created' => c.CreatedDate, 'messages' => messages, 'changes' => changes,
                'messageCursor' => newestFirst.size() == 40 ? newestFirst[39].Id : null,
                'tickets' => Atlas_Tickets.forConversation(conversationId)
            };
            if (c.Mode__c == 'uat' && saved.containsKey('uat')) response.put('uat', saved.get('uat'));
            return JSON.serialize(response);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    static String messageBody(Atlas_Message__c message) {
        if (message.Body_File__c == null) return message.Body__c;
        return [SELECT VersionData FROM ContentVersion WHERE Id = :message.Body_File__c WITH USER_MODE].VersionData.toString();
    }

    @AuraEnabled
    public static String getMessage(Id messageId) {
        try {
            return messageBody([SELECT Body__c, Body_File__c FROM Atlas_Message__c WHERE Id = :messageId WITH USER_MODE]);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    @AuraEnabled
    public static void addMessage(Id conversationId, String direction, String kind, String body) {
        try {
            String text = body == null ? '' : body;
            if (text.length() > 1500000) throw new Atlas_Api.AtlasException('This message exceeds 1,500,000 characters. Keep the reply and request smaller batches. Nothing was saved.');
            Atlas_Message__c message = new Atlas_Message__c(
                Conversation__c = conversationId, Direction__c = direction, Kind__c = kind, Body__c = text.left(1000)
            );
            insert as user message;
            if (text.length() > 1000) {
                ContentVersion file = new ContentVersion(Title = 'Atlas message', PathOnClient = 'message.txt',
                    VersionData = Blob.valueOf(text), FirstPublishLocationId = message.Id);
                insert as user file;
                update as user new Atlas_Message__c(Id = message.Id, Body_File__c = file.Id);
            }
            update as user new Atlas_Conversation__c(Id = conversationId);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /** Ordered background history writes. Exact response-loss retries reuse their messages. */
    @AuraEnabled
    public static String appendMessages(Id conversationId, String messagesJson) {
        try {
            List<Object> inputs = (List<Object>)JSON.deserializeUntyped(messagesJson);
            if (inputs == null || inputs.isEmpty() || inputs.size() > 10)
                throw new Atlas_Api.AtlasException('Save 1–10 messages at a time.');
            Atlas_Conversation__c parent = [SELECT Id FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE FOR UPDATE];
            List<Map<String,Object>> output = new List<Map<String,Object>>();
            for (Object raw : inputs) {
                Map<String,Object> input = (Map<String,Object>)raw;
                String nonce = (String)input.get('nonce'), body = (String)input.get('body');
                String direction = (String)input.get('direction'), kind = (String)input.get('kind');
                if (String.isBlank(nonce) || nonce.length() > 100 || body == null || body.length() > 1500000
                    || (direction != 'To Agent' && direction != 'From Agent') || String.isBlank(kind) || kind.length() > 40)
                    throw new Atlas_Api.AtlasException('Invalid history message. Keep the browser copy and correct the request.');
                String key = Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId() + ':' + conversationId + ':' + nonce));
                List<Atlas_Message__c> prior = [SELECT Id, Name, Conversation__c, Direction__c, Kind__c, Body__c, Body_File__c, CreatedDate
                    FROM Atlas_Message__c WHERE Client_Key__c = :key WITH USER_MODE];
                Atlas_Message__c message;
                if (!prior.isEmpty()) {
                    message = prior[0];
                    if (message.Conversation__c != conversationId || message.Direction__c != direction || message.Kind__c != kind || !messageBody(message).equals(body))
                        throw new Atlas_Api.AtlasException('History retry does not match its original message. Nothing was overwritten.');
                } else {
                    message = new Atlas_Message__c(Conversation__c = conversationId, Direction__c = direction,
                        Kind__c = kind, Client_Key__c = key, Body__c = body.left(1000));
                    insert as user message;
                    if (body.length() > 1000) {
                        ContentVersion file = new ContentVersion(Title = 'Atlas message', PathOnClient = 'message.txt',
                            VersionData = Blob.valueOf(body), FirstPublishLocationId = message.Id);
                        insert as user file;
                        update as user new Atlas_Message__c(Id = message.Id, Body_File__c = file.Id);
                    }
                    message = [SELECT Id, Name, CreatedDate FROM Atlas_Message__c WHERE Id = :message.Id WITH USER_MODE];
                }
                output.add(new Map<String,Object>{'nonce' => nonce, 'id' => message.Name, 'recordId' => message.Id,
                    'direction' => direction, 'kind' => kind, 'created' => message.CreatedDate});
            }
            update as user new Atlas_Conversation__c(Id = conversationId);
            return JSON.serialize(output);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String messagePage(Id conversationId, Id beforeId) {
        try {
            // IDs break timestamp ties, but are not chronological across Salesforce nodes.
            Atlas_Message__c cursor = [SELECT CreatedDate FROM Atlas_Message__c
                WHERE Id = :beforeId AND Conversation__c = :conversationId WITH USER_MODE];
            Datetime beforeDate = cursor.CreatedDate;
            List<Atlas_Message__c> rows = [SELECT Id, Name, Direction__c, Kind__c, Body__c, Body_File__c, CreatedDate
                FROM Atlas_Message__c WHERE Conversation__c = :conversationId
                    AND (CreatedDate < :beforeDate OR (CreatedDate = :beforeDate AND Id < :beforeId))
                WITH USER_MODE ORDER BY CreatedDate DESC, Id DESC LIMIT 40];
            List<Map<String, Object>> messages = new List<Map<String, Object>>();
            for (Integer i = rows.size() - 1; i >= 0; i--) {
                Atlas_Message__c m = rows[i];
                messages.add(new Map<String, Object>{'id' => m.Name, 'recordId' => m.Id, 'direction' => m.Direction__c,
                    'kind' => m.Kind__c, 'body' => m.Body__c, 'hasFullBody' => m.Body_File__c != null, 'created' => m.CreatedDate});
            }
            return JSON.serialize(new Map<String, Object>{'messages' => messages, 'cursor' => rows.size() == 40 ? rows[39].Id : null});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String getState(Id conversationId) {
        try {
            Atlas_Conversation__c c = [SELECT UI_State__c, State_File__c, State_Revision__c FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE];
            String text = stateText(c);
            return JSON.serialize(new Map<String, Object>{'revision' => c.State_Revision__c ?? 0, 'data' => String.isBlank(text) ? new Map<String,Object>() : JSON.deserializeUntyped(text)});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    /** The saved draft text. A large draft lives in a File; if that File is gone the draft reads as empty rather than breaking the conversation. */
    static String stateText(Atlas_Conversation__c c) {
        if (c.State_File__c == null) return c.UI_State__c;
        List<ContentVersion> files = [SELECT VersionData FROM ContentVersion WHERE Id = :c.State_File__c WITH USER_MODE];
        return files.isEmpty() ? null : files[0].VersionData.toString();
    }

    /** Drafts and pending review survive navigation. A stale tab cannot overwrite them. */
    @AuraEnabled
    public static Integer saveState(Id conversationId, Integer expectedRevision, String stateJson) {
        try {
            if (stateJson == null || stateJson.length() > 1500000) throw new Atlas_Api.AtlasException('Draft exceeds 1,500,000 characters; download the reply before splitting it.');
            JSON.deserializeUntyped(stateJson);
            Atlas_Conversation__c c = [SELECT State_Revision__c, State_File__c, UI_State__c FROM Atlas_Conversation__c WHERE Id = :conversationId WITH USER_MODE FOR UPDATE];
            Integer revision = c.State_Revision__c == null ? 0 : c.State_Revision__c.intValue();
            // Apex == ignores case, so a draft that only changed letter case would be dropped as "unchanged".
            if (stateJson.equals(stateText(c))) return revision;
            if (revision != expectedRevision) throw new Atlas_Api.AtlasException('Draft changed in another tab. Download this draft and reopen the conversation to reconcile; nothing was overwritten.');
            Id previousFile = c.State_File__c;
            c.UI_State__c = stateJson.length() <= MAX_BODY ? stateJson : null;
            c.State_File__c = null;
            if (stateJson.length() > MAX_BODY) {
                ContentVersion file = new ContentVersion(Title = DRAFT_FILE, PathOnClient = 'draft.json', VersionData = Blob.valueOf(stateJson), FirstPublishLocationId = c.Id);
                insert as user file;
                c.State_File__c = file.Id;
            }
            c.State_Revision__c = revision + 1;
            update as user c;
            removeDraftFile(previousFile, c.Id);
            return revision + 1;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static final String DRAFT_FILE = 'Atlas draft';

    /**
     * Every large-draft save used to leave the previous draft File behind, so a long reply
     * edited for an hour filled File storage. Only this conversation's own draft Files are
     * removed (a restored workspace can point State_File__c at a recovery File, which stays).
     * Removal is best effort: a File that cannot be deleted is kept and the save still succeeds.
     */
    static void removeDraftFile(Id versionId, Id conversationId) {
        if (versionId == null) return;
        List<ContentVersion> old = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :versionId AND Title = :DRAFT_FILE
            AND FirstPublishLocationId = :conversationId WITH USER_MODE];
        if (old.isEmpty()) return;
        Database.delete(new List<ContentDocument>{new ContentDocument(Id = old[0].ContentDocumentId)}, false, AccessLevel.USER_MODE);
    }

    /** Only the human's confirmation can add an alias; agents cannot write people. */
    @AuraEnabled
    public static String confirmAlias(Id personId, String alias) {
        // Always take the directory lock before a person lock, including this
        // read/modify/write path, so concurrent alias edits cannot deadlock.
        Atlas_Person__c p;
        try {
            if (String.isBlank(alias) || alias.length() > 120 || Pattern.matches('.*[,;\\r\\n].*', alias)) throw new Atlas_Api.AtlasException('Use one short alias.');
            lockPeople();
            List<Atlas_Person__c> found = [SELECT Id, Name, Jira_Account_Id__c, Aliases__c, Alias_List__c, User__c, Manager__c, Active__c FROM Atlas_Person__c WHERE Id = :personId WITH USER_MODE FOR UPDATE];
            if (found.isEmpty()) throw new Atlas_Api.AtlasException('That person no longer exists or is not shared with you.');
            p = found[0];
            if (p.Active__c != true || String.isBlank(p.Jira_Account_Id__c)) throw new Atlas_Api.AtlasException('Choose an active person with a confirmed Jira account ID.');
        } catch (Exception e) { throw Atlas_Api.fail(e); }
        Set<String> names = new Set<String>(Atlas_Identity.names(p));
        names.add(alias.normalizeSpace());
        return savePerson(JSON.serialize(new Map<String,Object>{'id' => p.Id, 'name' => p.Name, 'jiraId' => p.Jira_Account_Id__c,
            'aliases' => new List<String>(names), 'userId' => p.User__c, 'managerId' => p.Manager__c, 'active' => p.Active__c}));
    }

    // ---------------------------------------------------------------- files

    /** Saves a generated or uploaded file to Salesforce Files, linked to a record. */
    @AuraEnabled
    public static String saveFile(Id parentId, String fileName, String base64) {
        try {
            if (parentId == null || !Atlas_Workspace.TYPES.containsKey(parentId.getSObjectType().getDescribe().getLocalName()))
                throw new Atlas_Api.AtlasException('Choose an accessible native Atlas record for this File.');
            if (Database.query('SELECT Id FROM ' + parentId.getSObjectType().getDescribe().getName() + ' WHERE Id = :parentId FOR UPDATE', AccessLevel.USER_MODE).isEmpty())
                throw new Atlas_Api.AtlasException('This Atlas record is not accessible.');
            if (String.isBlank(fileName) || fileName.length() > 240 || base64 == null || base64.length() > 2000000)
                throw new Atlas_Api.AtlasException('Use a filename up to 240 characters and a File up to 1,500,000 bytes. Nothing was truncated.');
            Blob bytes = EncodingUtil.base64Decode(base64);
            String title = 'Atlas ' + fileName.substringBeforeLast('.');
            String receipt = 'Atlas generated file SHA-256: ' + Atlas_Api.sha256(bytes);
            Id author = UserInfo.getUserId();
            // The parent lock serializes retries. Only this user's exact filename and
            // bytes replay; a changed artifact creates a new File, never overwrites one.
            List<ContentVersion> previous = [SELECT Id, PathOnClient, Description FROM ContentVersion
                WHERE FirstPublishLocationId = :parentId AND CreatedById = :author AND Title = :title WITH USER_MODE LIMIT 2001];
            for (ContentVersion prior : previous) if (fileName.equals(prior.PathOnClient) && receipt.equals(prior.Description)) return prior.Id;
            if (previous.size() > 2000) throw new Atlas_Api.AtlasException('Too many same-named Files to verify a safe retry. Choose a distinct filename.');
            ContentVersion version = new ContentVersion(
                Title = title, PathOnClient = fileName, Description = receipt,
                VersionData = bytes, FirstPublishLocationId = parentId
            );
            insert as user version;
            return version.Id;
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }
}
