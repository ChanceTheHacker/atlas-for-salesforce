/** Shared identity bridge: one Atlas person, one Salesforce user, one Jira/SSO ID. */
public with sharing class Atlas_Identity {
    public static final Integer MAX_ALIASES = 32768;

    public static List<String> names(Atlas_Person__c person) {
        if (String.isNotBlank(person.Alias_List__c)) return (List<String>)JSON.deserialize(person.Alias_List__c, List<String>.class);
        List<String> result = new List<String>();
        if (String.isNotBlank(person.Aliases__c)) for (String name : person.Aliases__c.split('[,;\\n]'))
            if (String.isNotBlank(name)) result.add(name.normalizeSpace());
        return result;
    }

    public static List<String> cleanNames(List<Object> input) {
        List<String> result = new List<String>();
        Set<String> seen = new Set<String>();
        for (Object value : input) {
            if (!(value instanceof String)) throw new Atlas_Api.AtlasException('Each alias must be text.');
            String name = ((String)value).normalizeSpace();
            if (String.isBlank(name)) continue;
            if (name.length() > 120 || Pattern.matches('.*[,;\\r\\n].*', (String)value))
                throw new Atlas_Api.AtlasException('Use one name per alias, at most 120 characters, without commas or semicolons.');
            if (seen.add(Atlas_Data.aliasKey(name))) result.add(name);
        }
        if (JSON.serialize(result).length() > MAX_ALIASES) throw new Atlas_Api.AtlasException('This person has too many aliases (32,768 stored characters). Nothing was truncated.');
        return result;
    }

    static Boolean eligible(Schema.DescribeFieldResult field) {
        return field.isAccessible() && field.isFilterable() && !field.isEncrypted()
            && (field.getType() == Schema.DisplayType.STRING || field.getType() == Schema.DisplayType.EMAIL);
    }

    public static String validateField(String name) {
        if (String.isBlank(name)) return null;
        Schema.SObjectField field = Schema.SObjectType.User.fields.getMap().get(name.trim());
        if (field == null || !eligible(field.getDescribe()))
            throw new Atlas_Api.AtlasException('Choose an accessible, filterable text field on User for the Jira/SSO ID.');
        return field.getDescribe().getName();
    }

    public static String fieldName() {
        List<Atlas_Setting__c> rows = [SELECT Data__c FROM Atlas_Setting__c WHERE Key__c = 'identity' WITH USER_MODE LIMIT 1];
        if (rows.isEmpty() || String.isBlank(rows[0].Data__c)) return null;
        Map<String,Object> config = (Map<String,Object>)JSON.deserializeUntyped(rows[0].Data__c);
        return validateField((String)config.get('ssoField'));
    }

    @AuraEnabled
    public static List<Map<String,String>> fields() {
        List<Map<String,String>> result = new List<Map<String,String>>();
        for (Schema.SObjectField field : Schema.SObjectType.User.fields.getMap().values()) {
            Schema.DescribeFieldResult d = field.getDescribe();
            if (eligible(d)) result.add(new Map<String,String>{'label' => d.getLabel() + ' (' + d.getName() + ')', 'value' => d.getName()});
        }
        return result;
    }

    public static String userFields(String field) {
        Set<String> fields = new Set<String>{'Id', 'Name', 'Username', 'Email', 'Alias', 'IsActive'};
        if (field != null) fields.add(field);
        return String.join(new List<String>(fields), ',');
    }

    public static Map<Id,User> users(Set<Id> ids, String field) {
        if (ids == null || ids.isEmpty()) return new Map<Id,User>();
        return new Map<Id,User>((List<User>)Database.query('SELECT ' + userFields(field) + ' FROM User WHERE Id IN :ids', AccessLevel.USER_MODE));
    }

    public static String sso(User user, String field) {
        return user == null || field == null || user.get(field) == null ? null : String.valueOf(user.get(field)).trim();
    }

    public static String problem(String jiraId, User user, String field) {
        if (user == null) return 'The linked Salesforce user is not accessible.';
        if (!user.IsActive) return 'The linked Salesforce user is inactive.';
        if (field == null) return null;
        String value = sso(user, field);
        if (String.isBlank(value)) return 'The configured SSO field is empty on this user.';
        if (value != jiraId) return 'Saved Jira ID differs from the current Salesforce SSO value. Review the person in Team & Jira.';
        return null;
    }

    static Set<Id> duplicateSsoUsers(Map<Id,User> linked, String field) {
        Set<Id> result = new Set<Id>();
        if (field == null || linked.isEmpty()) return result;
        Set<String> values = new Set<String>();
        for (User user : linked.values()) if (String.isNotBlank(sso(user, field))) values.add(sso(user, field));
        if (values.isEmpty()) return result;
        Map<String,Integer> counts = new Map<String,Integer>();
        for (User user : (List<User>)Database.query('SELECT Id, ' + field + ' FROM User WHERE ' + field + ' IN :values', AccessLevel.USER_MODE)) {
            String key = sso(user, field).toLowerCase();
            counts.put(key, (counts.get(key) ?? 0) + 1);
        }
        for (User user : linked.values()) if (counts.get(sso(user, field)?.toLowerCase()) > 1) result.add(user.Id);
        return result;
    }

    /** Batch validation for reviewed assignments, including changes since the editor loaded. */
    public static Map<String,Object> versions(Set<Id> ids) {
        Map<String,Object> result = new Map<String,Object>();
        if (ids.isEmpty()) return result;
        List<Atlas_Data.Person> people = new List<Atlas_Data.Person>();
        for (Atlas_Person__c row : [SELECT Id, Name, User__c, Jira_Account_Id__c, Active__c, LastModifiedDate
            FROM Atlas_Person__c WHERE Id IN :ids WITH USER_MODE]) {
            if (!row.Active__c) throw new Atlas_Api.AtlasException('Reconcile inactive person ' + row.Name + ' in Team & Jira before assigning.');
            Atlas_Data.Person person = new Atlas_Data.Person();
            person.id = row.Id; person.name = row.Name; person.userId = row.User__c; person.jiraId = row.Jira_Account_Id__c;
            person.version = String.valueOf(row.LastModifiedDate.getTime());
            people.add(person);
        }
        if (people.size() != ids.size()) throw new Atlas_Api.AtlasException('An assigned person is no longer accessible. Reopen the review.');
        enrich(people);
        for (Atlas_Data.Person person : people) {
            if (person.identityWarning != null) throw new Atlas_Api.AtlasException(person.name + ': ' + person.identityWarning);
            result.put(person.id, Atlas_Api.sha256(Blob.valueOf(JSON.serialize(new List<String>{person.version, person.userId, person.jiraId, person.ssoId}))));
        }
        return result;
    }

    public static void enrich(List<Atlas_Data.Person> people) {
        Set<Id> ids = new Set<Id>();
        for (Atlas_Data.Person person : people) if (person.userId != null) ids.add((Id)person.userId);
        String field;
        String configError;
        try { field = fieldName(); } catch (Exception e) { configError = e.getMessage(); }
        Map<Id,User> linked = users(ids, field);
        Set<Id> duplicateIds = duplicateSsoUsers(linked, field);
        for (Atlas_Data.Person person : people) {
            if (person.userId == null) continue;
            User user = linked.get((Id)person.userId);
            person.email = user?.Email;
            person.loginName = user?.Username;
            person.ssoId = sso(user, field);
            person.identityWarning = configError ?? (duplicateIds.contains((Id)person.userId)
                ? 'Multiple Salesforce users share this SSO/Jira ID. Resolve the duplicate before assigning.' : problem(person.jiraId, user, field));
        }
    }

    public static Boolean isManagerRole(String term) {
        String key = Atlas_Data.aliasKey(term);
        return key == 'manager' || key == 'my manager';
    }

    /** Reuse lookup's cross-namespace collision checks for ticket and activity filters. */
    public static Map<String,Object> managerIdentity(String term) {
        Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(lookup(term));
        if (result.get('status') != 'resolved')
            throw new Atlas_Api.AtlasException('The manager is not a unique, active identity. Reconcile the Manager role and conflicting names in Team & Jira before continuing.');
        return (Map<String,Object>)result.get('resolved');
    }

    /** Read-only resolution. Similar names are suggestions, never confirmed assignments. */
    @AuraEnabled
    public static String lookup(String term) {
        try {
            String needle = term == null ? '' : term.normalizeSpace();
            if (needle.length() < 2 || needle.length() > 120) throw new Atlas_Api.AtlasException('Search with 2–120 characters of a name, email, alias, Salesforce ID or Jira/SSO ID.');
            String key = Atlas_Data.aliasKey(needle);
            Boolean managerRole = isManagerRole(needle);
            // reviewManager enriches the selected person; it must never call lookup recursively.
            Map<String,Object> manager = managerRole ? Atlas_Jira.reviewManager() : null;
            String managerId = managerRole ? (String)manager.get('personId') : null;
            String field = fieldName();
            List<Atlas_Person__c> people = [SELECT Id, Name, Jira_Account_Id__c, Aliases__c, Alias_List__c, User__c, Active__c
                FROM Atlas_Person__c WITH USER_MODE LIMIT 5001];
            if (people.size() > 5000) throw new Atlas_Api.AtlasException('Identity search exceeds 5,000 saved people. Use the paged people request and a scoped User SOQL query.');
            Map<Id,Atlas_Person__c> byUser = new Map<Id,Atlas_Person__c>();
            Set<Id> duplicateUsers = new Set<Id>();
            List<Map<String,Object>> candidates = new List<Map<String,Object>>();
            Set<Id> linkedIds = new Set<Id>();
            for (Atlas_Person__c person : people) {
                if (person.User__c != null) {
                    if (byUser.containsKey(person.User__c)) duplicateUsers.add(person.User__c);
                    byUser.put(person.User__c, person);
                }
                Set<String> keys = new Set<String>{Atlas_Data.aliasKey(person.Jira_Account_Id__c), Atlas_Data.aliasKey(String.valueOf(person.Id))};
                if (person.User__c != null) keys.add(Atlas_Data.aliasKey(String.valueOf(person.User__c)));
                // Saving lets an active person take over an inactive person's name or alias, so only
                // active people own names here. An inactive person is still found by an explicit ID.
                if (person.Active__c) {
                    keys.add(Atlas_Data.aliasKey(person.Name));
                    for (String alias : names(person)) keys.add(Atlas_Data.aliasKey(alias));
                }
                if (keys.contains(key) || (managerRole && String.valueOf(person.Id) == managerId)) {
                    if (person.User__c != null) linkedIds.add(person.User__c);
                    else candidates.add(candidate(person, null, field, true));
                }
            }
            String likeTerm = '%' + needle.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
            String whereClause = '(Name LIKE :likeTerm OR Username LIKE :likeTerm OR Email LIKE :likeTerm OR Alias = :needle'
                + (field == null ? '' : ' OR ' + field + ' = :needle') + ')';
            if (Pattern.matches('005[A-Za-z0-9]{12}([A-Za-z0-9]{3})?', needle)) {
                linkedIds.add((Id)needle);
            }
            // Linked users are fetched separately so a broad name search cannot hide an exact saved alias.
            Map<Id,User> found = users(linkedIds, field);
            List<User> matches = Database.query('SELECT ' + userFields(field) + ' FROM User WHERE ' + whereClause + ' ORDER BY Name, Id LIMIT 21', AccessLevel.USER_MODE);
            Boolean truncated = matches.size() > 20;
            if (truncated) matches.remove(20);
            for (User user : matches) found.put(user.Id, user);
            Set<Id> duplicateIds = duplicateSsoUsers(found, field);
            for (User user : found.values()) {
                Atlas_Person__c person = byUser.get(user.Id);
                Boolean exact = linkedIds.contains(user.Id);
                for (String value : new List<String>{user.Name, user.Username, user.Email, user.Alias, String.valueOf(user.Id), sso(user, field)})
                    if (String.isNotBlank(value) && Atlas_Data.aliasKey(value) == key) exact = true;
                Map<String,Object> row = candidate(person, user, field, exact);
                if (duplicateUsers.contains(user.Id)) row.put('warning', 'Multiple saved people link to this Salesforce user. Resolve the duplicate before assigning.');
                if (duplicateIds.contains(user.Id)) row.put('warning', 'Multiple Salesforce users share this SSO/Jira ID. Resolve the duplicate before assigning.');
                candidates.add(row);
            }
            Integer exactCount = 0;
            Map<String,Object> resolved;
            for (Map<String,Object> row : candidates) if (row.get('exact') == true) { exactCount++; resolved = row; }
            String status = truncated ? 'incomplete' : exactCount > 1 ? 'ambiguous' : exactCount == 1
                ? (resolved.get('warning') != null || resolved.get('active') == false ? 'conflict' : 'resolved')
                : candidates.isEmpty() ? 'not_found' : 'suggestions';
            // Reserved role words never fall back to a literal alias, even when it is unique.
            if (managerRole) {
                if (String.isBlank(managerId)) status = manager.get('status') == 'ambiguous' ? 'ambiguous' : 'conflict';
                else if (status == 'resolved' && String.valueOf(resolved.get('personId')) != managerId) status = 'conflict';
                else if (status == 'resolved' && (manager.get('status') == 'inactive' || manager.get('status') == 'identity_warning')) status = 'conflict';
            }
            return JSON.serialize(new Map<String,Object>{'term' => needle, 'ssoField' => field, 'status' => status,
                'truncated' => truncated, 'matches' => candidates, 'resolved' => status == 'resolved' ? resolved : null,
                'note' => 'Read-only lookup. A saved person ID links Jira ticket assignments; Salesforce userId is for record ownership. Never guess ambiguous matches. New links and aliases require human confirmation in Team & Jira. Jira remains manual.'});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static Map<String,Object> candidate(Atlas_Person__c person, User user, String field, Boolean exact) {
        String jira = person == null ? sso(user, field) : person.Jira_Account_Id__c;
        return new Map<String,Object>{'personId' => person?.Id, 'name' => person == null ? user?.Name : person.Name,
            'userId' => user?.Id, 'userName' => user?.Name, 'username' => user?.Username, 'email' => user?.Email,
            'jiraId' => jira, 'ssoId' => sso(user, field), 'aliases' => person == null ? new List<String>() : names(person),
            'active' => (person == null || person.Active__c) && (user == null || user.IsActive), 'exact' => exact,
            'warning' => user == null ? null : problem(jira, user, field), 'saved' => person != null};
    }
}
