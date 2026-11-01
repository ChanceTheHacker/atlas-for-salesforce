/** Bounded Jira operations. Credentials are resolved only by Salesforce, never by an agent. */
public with sharing class Atlas_Jira {
    public class Config {
        public String siteUrl, apiBaseUrl, namedCredential, externalCredential, apiVersion, fingerprint;
        public Boolean connected, readEnabled, writeEnabled;
    }
    public static Atlas_Api.AtlasException problem(String message) { return new Atlas_Api.AtlasException(message); }
    public static String text(Map<String,Object> input, String key, Integer maximum, Boolean required) {
        Object raw = input.get(key);
        if (raw != null && !(raw instanceof String)) throw problem('Jira ' + key + ' must be text.');
        String value = (String)raw;
        if ((required && String.isBlank(value)) || (value != null && value.length() > maximum)) throw problem('Invalid Jira ' + key + '.');
        return value;
    }
    public static void only(Map<String,Object> input, Set<String> allowed) {
        if (input == null) throw problem('Jira request must be an object.');
        for (String key : input.keySet()) if (!allowed.contains(key)) throw problem('Unsupported Jira request property: ' + key.left(80));
    }
    static String baseUrl(String value) {
        if (String.isBlank(value)) return '';
        value = value.trim();
        while (value.endsWith('/')) value = value.substring(0,value.length()-1);
        if (!Pattern.matches('https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9_-]+)*',value) || value.contains('..'))
            throw problem('Use an HTTPS Jira base URL without credentials, query parameters, or fragments.');
        return value;
    }
    /** Validate rather than silently coercing permissions. Unknown legacy nonsecret options survive. */
    public static String validateSetting(String data) {
        if (data == null || data.length() > 120000) throw problem('Jira settings must be a bounded JSON object.');
        Map<String,Object> input;
        try { input=(Map<String,Object>)JSON.deserializeUntyped(data); }
        catch (Exception e) { throw problem('Jira settings must be a valid JSON object.'); }
        if (input == null) throw problem('Jira settings must be an object.');
        Boolean legacyManual=!input.containsKey('namedCredential') && !input.containsKey('externalCredential') && !input.containsKey('apiBaseUrl')
            && !input.containsKey('apiVersion') && !input.containsKey('readEnabled') && !input.containsKey('writeEnabled');
        rejectSecrets(input,0);
        for (String flag : new List<String>{'readEnabled','writeEnabled'}) {
            if (input.containsKey(flag) && !(input.get(flag) instanceof Boolean)) throw problem(flag + ' must be true or false.');
            if (!input.containsKey(flag)) input.put(flag,false);
        }
        for (String key : new List<String>{'siteUrl','apiBaseUrl'}) if (input.containsKey(key)) input.put(key,baseUrl(text(input,key,1000,false)));
        for (String key : new List<String>{'namedCredential','externalCredential'}) {
            String name = text(input,key,160,false);
            if (String.isNotBlank(name) && !Pattern.matches('[A-Za-z][A-Za-z0-9_]{0,159}',name)) throw problem('Use the existing credential API name, not its label or a secret.');
            input.put(key,name == null ? '' : name);
        }
        String version = text(input,'apiVersion',1,false);
        if (String.isBlank(version)) version = '3';
        if (version != '3' && version != '2') throw problem('Jira API version must be 3 (Cloud) or 2 (Data Center).');
        input.put('apiVersion',version);
        validateReviewManagerSetting(input);
        parse(input);
        if (legacyManual && !input.containsKey('reviewManagerPersonId') && !input.containsKey('reviewManagerIdentityType')) return data; // Preserve the original manual/CSV settings shape.
        return JSON.serialize(input);
    }
    static void validateReviewManagerSetting(Map<String,Object> input) {
        String personId=text(input,'reviewManagerPersonId',18,false);
        String identityType=text(input,'reviewManagerIdentityType',20,false);
        if (String.isNotBlank(personId)) {
            try {
                Id recordId=(Id)personId;
                if (recordId.getSObjectType()!=Atlas_Person__c.SObjectType) throw problem('Wrong record type.');
                input.put('reviewManagerPersonId',String.valueOf(recordId));
            } catch (Exception e) { throw problem('Choose a review manager from the Atlas People directory.'); }
        } else if (input.containsKey('reviewManagerPersonId')) {
            input.put('reviewManagerPersonId',''); input.put('reviewManagerIdentityType','');
        }
        if (String.isNotBlank(identityType) && !identityType.equals('accountId') && !identityType.equals('name'))
            throw problem('Confirm the manager identity as accountId (Cloud) or name (Data Center), or leave it unconfirmed.');
        if (input.containsKey('reviewManagerIdentityType')) input.put('reviewManagerIdentityType',String.isBlank(personId) || String.isBlank(identityType) ? '' : identityType);
    }
    static void checkNewReviewManager(Map<String,Object> before,Map<String,Object> after) {
        String selected=(String)after.get('reviewManagerPersonId');
        if (String.isBlank(selected) || selected==(String)before.get('reviewManagerPersonId')) return;
        Id personId=(Id)selected;
        List<Atlas_Person__c> people=[SELECT Id,Active__c FROM Atlas_Person__c WHERE Id=:personId WITH USER_MODE LIMIT 1];
        if (people.isEmpty() || people[0].Active__c!=true) throw problem('Choose an active, accessible review manager from People.');
    }
    static Map<String,Object> managerStatus(Map<String,Object> result,String status,String message) {
        result.put('status',status); result.put('message',message); return result;
    }
    /** Compatibility only: new role edits are saved with the person, not connection settings. */
    public static Map<String,Object> legacyManagerSetting() {
        List<Atlas_Setting__c> settings=[SELECT Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE LIMIT 1];
        return settings.isEmpty() ? new Map<String,Object>() : settingObject(settings[0].Data__c);
    }
    /** Called only for an explicit Manager checkbox save, while holding the directory lock. */
    public static void clearMissingLegacyManager() {
        List<Atlas_Setting__c> rows=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE FOR UPDATE];
        if (rows.isEmpty()) return;
        Map<String,Object> jira=settingObject(rows[0].Data__c);
        String legacyId=(String)jira.get('reviewManagerPersonId');
        if (String.isBlank(legacyId) || !Atlas_ManagerGuard.missingPerson(legacyId)) return;
        jira.put('reviewManagerPersonId',''); jira.put('reviewManagerIdentityType','');
        rows[0].Data__c=JSON.serialize(jira);
        update as user rows;
    }
    public static void migrateManager(Id personId, Boolean selected, Boolean identityProvided) {
        List<Atlas_Setting__c> rows=[SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE FOR UPDATE];
        if (rows.isEmpty()) return;
        Map<String,Object> jira=settingObject(rows[0].Data__c);
        if (String.valueOf(personId) != (String)jira.get('reviewManagerPersonId')) return;
        if (selected && !identityProvided) update as user new Atlas_Person__c(Id=personId,
            Atlas_Jira_Identity_Type__c=(String)jira.get('reviewManagerIdentityType'));
        jira.put('reviewManagerPersonId',''); jira.put('reviewManagerIdentityType','');
        rows[0].Data__c=JSON.serialize(jira);
        update as user rows;
    }
    /** Resolve the saved person afresh at every approval boundary; never infer an identity or a repair developer. */
    public static Map<String,Object> reviewManager() {
        Map<String,Object> jira=legacyManagerSetting();
        String legacyId=text(jira,'reviewManagerPersonId',18,false);
        List<Atlas_Person__c> managers=[SELECT Id,Name,Active__c,Jira_Account_Id__c,User__c,Atlas_Is_Manager__c,Atlas_Jira_Identity_Type__c
            FROM Atlas_Person__c WHERE Atlas_Is_Manager__c=true WITH USER_MODE LIMIT 2];
        String personId=managers.size()==1 ? String.valueOf(managers[0].Id) : legacyId;
        String identityType=managers.size()==1 ? managers[0].Atlas_Jira_Identity_Type__c : text(jira,'reviewManagerIdentityType',20,false);
        Map<String,Object> result=new Map<String,Object>{'status'=>'unconfigured','personId'=>personId ?? '', 'name'=>'','jiraId'=>'',
            'identityType'=>identityType ?? '','ready'=>false,'message'=>'Choose Manager on a person in Team & Jira before routing a suspected bug.'};
        if (managers.size()>1 || (managers.size()==1 && String.isNotBlank(legacyId) && legacyId!=personId)) {
            result.put('personId',''); result.put('identityType','');
            return managerStatus(result,'ambiguous','More than one Manager is configured. Resolve the conflicting roles in Team & Jira; Atlas will not choose one.');
        }
        if (String.isBlank(personId)) return result;
        Id recordId;
        try { recordId=(Id)personId; } catch (Exception e) { return managerStatus(result,'unavailable','The saved Manager is unavailable. Select an active person in Team & Jira.'); }
        List<Atlas_Person__c> rows=managers.isEmpty()
            ? [SELECT Id,Name,Active__c,Jira_Account_Id__c,User__c FROM Atlas_Person__c WHERE Id=:recordId WITH USER_MODE LIMIT 1] : managers;
        if (rows.isEmpty()) return managerStatus(result,'unavailable','The saved review manager is unavailable. Select an active person in Team & Jira; names are never matched automatically.');
        Atlas_Person__c row=rows[0]; result.put('personId',String.valueOf(row.Id)); result.put('name',row.Name);
        if (row.Active__c!=true) return managerStatus(result,'inactive','The saved review manager is inactive. Select an active person in Team & Jira.');
        Atlas_Data.Person person=new Atlas_Data.Person(); person.id=row.Id; person.name=row.Name; person.jiraId=row.Jira_Account_Id__c; person.userId=row.User__c;
        Atlas_Identity.enrich(new List<Atlas_Data.Person>{person});
        if (String.isNotBlank(person.identityWarning)) return managerStatus(result,'identity_warning','Resolve the review manager\'s identity warning in People before routing a bug.');
        if (String.isBlank(person.jiraId)) return managerStatus(result,'missing_jira_id','Add the review manager\'s exact Jira account ID or Data Center username in People. Do not guess it from their name or SSO ID.');
        if (String.isBlank(identityType)) return managerStatus(result,'unconfirmed_identity','Confirm whether the review manager\'s saved Jira ID is a Cloud account ID or a Data Center username.');
        String version=(String)jira.get('apiVersion') ?? '3';
        if (!identityType.equals(version=='2' ? 'name' : version=='3' ? 'accountId' : ''))
            return managerStatus(result,'identity_type_mismatch','The review manager\'s confirmed identity type does not match the Jira API version. Review both settings; Atlas never converts usernames to account IDs.');
        result.put('ready',true); result.put('jiraId',person.jiraId.trim());
        return managerStatus(result,'ready',row.Name+' will receive suspected bugs for review and assignment, not as the repair developer. Nothing is sent by saving this setting.');
    }
    /** Older clients and archives omit manager fields. Omission preserves them; an empty person ID clears them. */
    @TestVisible static String validateSettingPreservingManager(String data,Map<String,Object> before) {
        if (String.isBlank(data) || data.length() > 120000) throw problem('Jira settings must be a bounded JSON object.');
        Map<String,Object> input=settingObject(data);
        if (input == null) throw problem('Jira settings must be an object.');
        Boolean preserved=false;
        if (!input.containsKey('reviewManagerPersonId') && before.containsKey('reviewManagerPersonId')) {
            input.put('reviewManagerPersonId',before.get('reviewManagerPersonId')); preserved=true;
        }
        // A new recipient must never inherit the previous recipient's identity confirmation.
        if (!input.containsKey('reviewManagerIdentityType') && before.containsKey('reviewManagerIdentityType') &&
            JSON.serialize(input.get('reviewManagerPersonId')).equals(JSON.serialize(before.get('reviewManagerPersonId')))) {
            input.put('reviewManagerIdentityType',before.get('reviewManagerIdentityType')); preserved=true;
        }
        return validateSetting(preserved ? JSON.serialize(input) : data);
    }
    public static String validateConnectionSetting(String data) {
        List<Atlas_Setting__c> saved=[SELECT Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE LIMIT 1];
        Map<String,Object> before=saved.isEmpty() ? new Map<String,Object>() : settingObject(saved[0].Data__c);
        String clean=validateSettingPreservingManager(data,before);
        checkNewReviewManager(before,settingObject(clean));
        Config checked=parse(settingObject(clean));
        // Metadata inspection stays outside trigger/DML context. Runtime always verifies again.
        if (checked.connected && canConfigure()) verifyMetadata(checked,inspector);
        return clean;
    }
    public static Boolean canConfigure() {
        String objectName=Atlas_Setting__c.SObjectType.getDescribe().getName();
        String namespacePrefix=objectName.substring(0,objectName.length()-'Atlas_Setting__c'.length());
        return FeatureManagement.checkPermission(namespacePrefix+'Atlas_Configure_Jira');
    }
    static final Set<String> CONNECTION_KEYS=new Set<String>{'siteUrl','apiBaseUrl','namedCredential','externalCredential','apiVersion','readEnabled','writeEnabled'};
    private static Set<Id> restoredSettings=new Set<Id>();
    static Map<String,Object> settingObject(String data) {
        if (String.isBlank(data)) return new Map<String,Object>();
        try { return (Map<String,Object>)JSON.deserializeUntyped(data); }
        catch (Exception e) { throw problem('Jira settings must be a valid JSON object.'); }
    }
    static Boolean hasConnection(Map<String,Object> input) {
        return String.isNotBlank((String)input.get('externalCredential')) || String.isNotBlank((String)input.get('namedCredential'))
            || input.get('readEnabled')==true || input.get('writeEnabled')==true;
    }
    static String connectionValues(Map<String,Object> input) {
        Map<String,Object> value=new Map<String,Object>();
        // Manual CSV site URLs remain editable until credentials are configured.
        for (String key : CONNECTION_KEYS) value.put(key,input.get(key));
        return Atlas_JiraWrites.canonical(value);
    }
    /** Trigger-level protection includes direct record APIs, key renames, recovery and deletion. */
    public static void guardSettings(List<Atlas_Setting__c> records,Map<Id,Atlas_Setting__c> oldRecords,Boolean deleting) {
        Boolean allowed=canConfigure();
        for (Atlas_Setting__c row : records) {
            Atlas_Setting__c old=oldRecords==null ? null : oldRecords.get(row.Id);
            Boolean oldJira=old!=null && old.Key__c=='jira', newJira=!deleting && row.Key__c=='jira';
            if (!oldJira && !newJira) continue;
            try {
                Map<String,Object> before=oldJira ? settingObject(old.Data__c) : new Map<String,Object>();
                if (!newJira) {
                    if (hasConnection(before) && !allowed) throw problem('Only a Jira connection administrator may remove or rename the Jira connection.');
                    continue;
                }
                String normalized=validateSettingPreservingManager(row.Data__c,before);
                Map<String,Object> after=settingObject(normalized);
                Atlas_ManagerGuard.checkLegacy((String)after.get('reviewManagerPersonId'));
                // Recovery preserves unresolved embedded person IDs. Runtime resolution fails closed;
                // the interactive save additionally requires a newly selected person to be active.
                if (!allowed && !JSON.serialize(before.get('connectionRevision')).equals(JSON.serialize(after.get('connectionRevision'))))
                    throw problem('Only a Jira connection administrator may change the protected connection revision.');
                Boolean keyChanged=old!=null && !String.valueOf(old.Key__c).equals(String.valueOf(row.Key__c));
                Boolean protectedChange=(hasConnection(before) || hasConnection(after)) && (keyChanged || !connectionValues(before).equals(connectionValues(after)));
                if (protectedChange && !allowed) throw problem('Only a user with Atlas Configure Jira permission may change the Jira connection or read/write switches.');
                Boolean restoring=restoredSettings.contains(row.Id);
                if (restoring && !allowed) throw problem('Only a Jira connection administrator may restore Jira connection settings.');
                if (protectedChange || restoring) {
                    after.put('connectionRevision',EncodingUtil.convertToHex(Crypto.generateAesKey(128)));
                    row.Data__c=JSON.serialize(after);
                } else if (before.containsKey('connectionRevision')) {
                    // Caller-provided revisions are never trusted, even for an administrator.
                    after.put('connectionRevision',before.get('connectionRevision')); row.Data__c=JSON.serialize(after);
                } else {
                    after.remove('connectionRevision');
                    row.Data__c=settingObject(normalized).containsKey('connectionRevision') ? JSON.serialize(after) : normalized;
                }
            } catch (Exception e) { row.addError(e.getMessage()); }
        }
    }
    public static void restored(List<Atlas_Setting__c> records) {
        List<Atlas_Setting__c> refresh=new List<Atlas_Setting__c>();
        for (Atlas_Setting__c row : records) if (row.Key__c=='jira') {
            try {
                if (!hasConnection(settingObject(row.Data__c))) continue;
                if (!canConfigure()) { row.addError('Only a Jira connection administrator may restore Jira connection settings.'); continue; }
                restoredSettings.add(row.Id); refresh.add(new Atlas_Setting__c(Id=row.Id,Data__c=row.Data__c));
            } catch (Exception e) { row.addError('The restored Jira connection could not be validated.'); }
        }
        if (!refresh.isEmpty()) update refresh;
        restoredSettings.clear();
    }
    static void rejectSecrets(Object value,Integer depth) {
        if (depth > 8) throw problem('Jira settings are nested too deeply.');
        if (value instanceof Map<String,Object>) {
            Map<String,Object> fields = (Map<String,Object>)value;
            for (String key : fields.keySet()) {
                String lower = key.toLowerCase().replace('_','').replace('-','');
                if (lower.contains('password') || lower.contains('secret') || lower.contains('token') || lower == 'authorization' || lower == 'headers' || lower == 'apikey')
                    throw problem('Do not store secrets or authentication headers in Jira settings. Use Salesforce credentials.');
                rejectSecrets(fields.get(key),depth+1);
            }
        } else if (value instanceof List<Object>) for (Object child : (List<Object>)value) rejectSecrets(child,depth+1);
    }
    public static Config config() {
        List<Atlas_Setting__c> rows = [SELECT Data__c FROM Atlas_Setting__c WHERE Key__c='jira' WITH USER_MODE LIMIT 1];
        Map<String,Object> settings = rows.isEmpty() || String.isBlank(rows[0].Data__c) ? new Map<String,Object>() : (Map<String,Object>)JSON.deserializeUntyped(rows[0].Data__c);
        return parse(settings);
    }
    static Config parse(Map<String,Object> input) {
        Config c = new Config();
        c.siteUrl=baseUrl(text(input,'siteUrl',1000,false));
        c.apiBaseUrl=baseUrl(text(input,'apiBaseUrl',1000,false));
        if (String.isBlank(c.apiBaseUrl)) c.apiBaseUrl=c.siteUrl;
        c.namedCredential=text(input,'namedCredential',160,false);
        c.externalCredential=text(input,'externalCredential',160,false);
        for (String name : new List<String>{c.namedCredential,c.externalCredential}) if (String.isNotBlank(name) && !Pattern.matches('[A-Za-z][A-Za-z0-9_]{0,159}',name)) throw problem('Invalid Jira credential API name.');
        c.apiVersion=text(input,'apiVersion',1,false) ?? '3';
        if (c.apiVersion != '2' && c.apiVersion != '3') throw problem('Unsupported Jira API version.');
        for (String flag : new List<String>{'readEnabled','writeEnabled'}) if (input.containsKey(flag) && !(input.get(flag) instanceof Boolean)) throw problem('Jira switches must be true or false.');
        c.readEnabled=input.get('readEnabled') == true; c.writeEnabled=input.get('writeEnabled') == true;
        c.connected=String.isNotBlank(c.externalCredential);
        if ((!c.connected && (String.isNotBlank(c.namedCredential) || c.readEnabled || c.writeEnabled)) ||
            (c.connected && (String.isBlank(c.namedCredential) || String.isBlank(c.apiBaseUrl) || String.isBlank(c.siteUrl))))
            throw problem('Jira connection is incomplete. Configure both credential names and URLs, or clear credentials and both switches for manual mode.');
        c.fingerprint=Atlas_Api.sha256(Blob.valueOf(JSON.serialize(new List<Object>{c.siteUrl,c.apiBaseUrl,c.namedCredential,c.externalCredential,c.apiVersion,c.readEnabled,c.writeEnabled,input.get('connectionRevision')})));
        return c;
    }
    /** Adapter intentionally returns metadata only; no authentication material is read. */
    public virtual class CredentialInspector {
        public virtual Map<String,Object> inspect(String name) {
            return (Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(ConnectApi.NamedCredentials.getNamedCredential(name)));
        }
    }
    @TestVisible static CredentialInspector inspector = new CredentialInspector();
    public static CredentialInspector credentialInspector() { return inspector; }
    public static void verify(Config c,Boolean writeAccess) { verify(c,writeAccess,inspector); }
    public static void verify(Config c,Boolean writeAccess,CredentialInspector credentialAdapter) {
        if (!c.connected) throw problem('Jira is in manual mode. Configure Salesforce credentials to use live Jira.');
        if (writeAccess ? !c.writeEnabled : !c.readEnabled) throw problem(writeAccess ? 'Live Jira writes are disabled.' : 'Live Jira reads are disabled. Use local-tickets explicitly for the saved mirror.');
        verifyMetadata(c,credentialAdapter);
    }
    static void verifyMetadata(Config c,CredentialInspector credentialAdapter) {
        try {
            Map<String,Object> meta=credentialAdapter.inspect(c.namedCredential);
            String endpoint=(String)meta.get('calloutUrl');
            Boolean linked=false;
            Object external=meta.get('externalCredentials');
            if (external instanceof List<Object>) for (Object item : (List<Object>)external) {
                Map<String,Object> entry=(Map<String,Object>)item;
                if (c.externalCredential.equals((String)entry.get('developerName'))) linked=true;
            }
            if (!c.apiBaseUrl.equals(baseUrl(endpoint)) || !linked) throw problem('The Jira URL and External Credential must match the selected Named Credential.');
        } catch (Exception e) {
            // Do not leak ConnectApi error details, endpoint credentials, or principal information.
            throw problem('Cannot verify the selected Jira Named Credential endpoint and linked External Credential. Ask your Salesforce administrator to check this connection and your access.');
        }
    }
    @AuraEnabled
    public static String capabilities() {
        try {
            Config c=config();
            return JSON.serialize(new Map<String,Object>{'connected'=>c.connected,'readEnabled'=>c.readEnabled,'writeEnabled'=>c.writeEnabled,
                'mode'=>c.connected ? 'live' : 'manual','apiVersion'=>c.apiVersion,'siteUrl'=>c.siteUrl,'apiBaseUrl'=>c.apiBaseUrl,
                'maxResults'=>50,'writesRequireApproval'=>true,'canConfigure'=>canConfigure()});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    @AuraEnabled
    public static String connectionTest() {
        try {
            Config c=config(); verify(c,false);
            HttpResponse response=send(c,'GET','/rest/api/'+c.apiVersion+'/myself',null);
            if (response.getStatusCode()!=200) throw problem('Jira connection test failed (HTTP '+response.getStatusCode()+'). Check the credential principal and Jira permissions.');
            Object identity=parseResponse(response);
            if (!(identity instanceof Map<String,Object>) || (((Map<String,Object>)identity).get('accountId') == null && ((Map<String,Object>)identity).get('name') == null))
                throw problem('Jira returned an unexpected identity response. The connection is not verified.');
            return JSON.serialize(new Map<String,Object>{'ok'=>true,'message'=>'Jira authenticated this Salesforce user. No Jira data was changed.','writePermissionVerified'=>false});
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
    public static HttpResponse send(Config c,String method,String path,String body) {
        HttpRequest request=new HttpRequest();
        request.setEndpoint('callout:'+c.namedCredential+path);
        request.setMethod(method); request.setTimeout(30000);
        request.setHeader('Accept','application/json');
        if (body != null) { request.setHeader('Content-Type','application/json'); request.setBody(body); }
        // Salesforce checks the running user's external-credential principal on this actual callout.
        try { return new Http().send(request); }
        catch (Exception e) { throw problem('Jira transport failed. No automatic retry was attempted.'); }
    }
    public static Object parseResponse(HttpResponse response) {
        String body=response.getBody();
        if (body == null || body.length()>250000) throw problem('Jira response exceeded 250,000 characters. Narrow the request.');
        try { return JSON.deserializeUntyped(body); }
        catch (Exception e) { throw problem('Jira returned an invalid JSON response.'); }
    }
    public static String issueKey(Object raw) {
        if (!(raw instanceof String) || !Pattern.matches('[A-Z][A-Z0-9_]{0,49}-[0-9]{1,15}',(String)raw)) throw problem('Use an exact Jira issue key such as PROJ-123.');
        return (String)raw;
    }
    static Integer number(Map<String,Object> request,String key,Integer fallback,Integer maximum) {
        if (!request.containsKey(key)) return fallback;
        String raw=String.valueOf(request.get(key));
        if (!Pattern.matches('[0-9]{1,6}',raw)) throw problem('Jira '+key+' must be a whole number.');
        Integer result=Integer.valueOf(raw);
        if (result<0 || result>maximum || (key=='maxResults' && result==0)) throw problem('Jira '+key+' exceeds its allowed range.');
        return result;
    }
    static List<String> fields(Map<String,Object> request) {
        List<String> result=new List<String>();
        if (request.get('fields') == null) return new List<String>{'summary','status','issuetype','project','assignee','priority','duedate','parent','updated'};
        if (!(request.get('fields') instanceof List<Object>) || ((List<Object>)request.get('fields')).size()>20) throw problem('Choose at most 20 Jira fields.');
        for (Object raw : (List<Object>)request.get('fields')) {
            if (!(raw instanceof String) || !Pattern.matches('[A-Za-z][A-Za-z0-9_]{0,79}',(String)raw)) throw problem('Use exact Jira field IDs, not wildcard fields.');
            result.add((String)raw);
        }
        if (result.isEmpty()) throw problem('Choose at least one Jira field.');
        return result;
    }
    static String encode(String value) { return EncodingUtil.urlEncode(value,'UTF-8'); }
    public static Map<String,Object> run(Map<String,Object> request) {
        only(request,new Set<String>{'op','action','issueKey','jql','maxResults','nextPageToken','startAt','fields'});
        Config c=config(); verify(c,false);
        String action=text(request,'action',20,true), root='/rest/api/'+c.apiVersion;
        String path, method='GET', body;
        Integer maximum=number(request,'maxResults',25,50), start=number(request,'startAt',0,10000);
        List<String> requestedFields=fields(request);
        if (action=='issue') path=root+'/issue/'+issueKey(request.get('issueKey'))+'?fields='+encode(String.join(requestedFields,','));
        else if (action=='transitions') path=root+'/issue/'+issueKey(request.get('issueKey'))+'/transitions';
        else if (action=='search') {
            String jql=text(request,'jql',4000,true);
            Map<String,Object> search=new Map<String,Object>{'jql'=>jql,'maxResults'=>maximum,'fields'=>requestedFields};
            if (c.apiVersion=='3') {
                if (request.containsKey('startAt')) throw problem('Cloud enhanced search uses nextPageToken, not startAt.');
                String token=text(request,'nextPageToken',2048,false);
                if (String.isNotBlank(token)) search.put('nextPageToken',token);
                path=root+'/search/jql';
            } else {
                if (request.containsKey('nextPageToken')) throw problem('Data Center search uses startAt, not nextPageToken.');
                search.put('startAt',start); path=root+'/search';
            }
            method='POST'; body=JSON.serialize(search);
        } else if (action=='projects') path=root+(c.apiVersion=='3' ? '/project/search?maxResults='+maximum+'&startAt='+start : '/project');
        else if (action=='fields') path=root+'/field';
        else throw problem('Unsupported Jira read action.');
        HttpResponse response=send(c,method,path,body);
        if (response.getStatusCode()!=200) throw problem('Live Jira read failed (HTTP '+response.getStatusCode()+'). Saved mirror data was not substituted.');
        Object raw=parseResponse(response);
        Map<String,Object> out=new Map<String,Object>{'source'=>'live-jira','authoritative'=>true,'action'=>action,'hasMore'=>false};
        if (action=='issue') out.put('issue',safeIssue((Map<String,Object>)raw,requestedFields));
        else if (action=='search') {
            Map<String,Object> page=(Map<String,Object>)raw;
            List<Object> rows=new List<Object>();
            for (Object item : (List<Object>)page.get('issues')) {
                if (rows.size()>=maximum) throw problem('Jira exceeded the requested issue page size.');
                rows.add(safeIssue((Map<String,Object>)item,requestedFields));
            }
            out.put('issues',rows); out.put('count',rows.size());
            if (c.apiVersion=='3') {
                String token=text(page,'nextPageToken',2048,false);
                Boolean more=page.get('isLast')==false || String.isNotBlank(token);
                if (more && String.isBlank(token)) throw problem('Jira search returned an incomplete page without a continuation token.');
                out.put('hasMore',more); out.put('nextPageToken',token); out.put('nextCursor',token);
            } else {
                Integer total=number(page,'total',start+rows.size(),999999);
                Boolean more=start+rows.size()<total;
                out.put('hasMore',more); out.put('startAt',start); out.put('nextStartAt',more ? start+rows.size() : null);
                out.put('nextCursor',more ? String.valueOf(start+rows.size()) : null);
            }
        } else {
            List<Object> source;
            if (action=='transitions') source=(List<Object>)((Map<String,Object>)raw).get('transitions');
            else if (raw instanceof List<Object>) source=(List<Object>)raw;
            else source=(List<Object>)((Map<String,Object>)raw).get('values');
            List<Object> items=new List<Object>();
            Integer cap=action=='projects' ? maximum : 200;
            for (Object item : source) {
                if (items.size()==cap) { out.put('hasMore',true); break; }
                Map<String,Object> original=(Map<String,Object>)item;
                Map<String,Object> clean=pick(original,new Set<String>{'id','key','name','custom','required'});
                if (action=='transitions') clean.put('to',pick((Map<String,Object>)original.get('to'),new Set<String>{'id','name'}));
                items.add(clean);
            }
            out.put('items',items); out.put('count',items.size());
            if (action=='projects' && raw instanceof Map<String,Object>) {
                Map<String,Object> page=(Map<String,Object>)raw;
                Boolean more=page.get('isLast')==false;
                out.put('hasMore',more); out.put('nextStartAt',more ? start+items.size() : null);
            }
            if (out.get('hasMore')==true && action!='projects') out.put('note','Result is limited to the first 200 items.');
            if (out.get('hasMore')==true && action=='projects' && c.apiVersion=='2') out.put('note','Data Center project listing is limited; use a narrower issue search.');
        }
        if (JSON.serialize(out).length()>120000) throw problem('Jira result exceeds 120,000 characters. Request fewer issues or fields.');
        return out;
    }
    static Map<String,Object> pick(Map<String,Object> input,Set<String> keys) {
        Map<String,Object> out=new Map<String,Object>();
        if (input!=null) for (String key : keys) if (input.containsKey(key)) out.put(key,input.get(key));
        return out;
    }
    static Map<String,Object> safeIssue(Map<String,Object> input,List<String> requested) {
        String key=issueKey(input.get('key'));
        Map<String,Object> out=pick(input,new Set<String>{'id','key'}), clean=new Map<String,Object>();
        Map<String,Object> original=(Map<String,Object>)input.get('fields');
        if (original==null) throw problem('Jira returned an issue without its fields.');
        for (String field : requested) if (original.containsKey(field)) clean.put(field,scrub(original.get(field),0));
        out.put('fields',clean); return out;
    }
    /** Drop server URLs, emails and authentication-shaped properties from returned objects. */
    static Object scrub(Object input,Integer depth) {
        if (depth>12) throw problem('Jira response is nested too deeply.');
        if (input instanceof Map<String,Object>) {
            Map<String,Object> out=new Map<String,Object>();
            for (String key : ((Map<String,Object>)input).keySet()) {
                String lower=key.toLowerCase();
                if (lower.contains('token') || lower.contains('secret') || lower.contains('password') || lower=='authorization' || lower=='self' || lower=='avatarurls' || lower=='emailaddress') continue;
                out.put(key,scrub(((Map<String,Object>)input).get(key),depth+1));
            }
            return out;
        }
        if (input instanceof List<Object>) {
            List<Object> out=new List<Object>();
            if (((List<Object>)input).size()>200) throw problem('A Jira field contains too many values. Narrow the requested fields.');
            for (Object child : (List<Object>)input) out.add(scrub(child,depth+1));
            return out;
        }
        return input;
    }
    static String quote(String value) { return '"'+value.replace('\\','\\\\').replace('"','\\"').replace('\n',' ').replace('\r',' ')+'"'; }
    public static String tickets(Map<String,Object> request) {
        Config c=config();
        if (!c.connected) return Atlas_Tickets.agentQuery(request);
        if (!c.readEnabled) throw problem('Live Jira reads are disabled. Use local-tickets explicitly for the saved mirror.');
        only(request,new Set<String>{'op','owner','keys','text','status','epicsOnly','limit','cursor','description'});
        List<String> filters=new List<String>();
        Set<Id> owners=Atlas_Tickets.liveOwnerIds(request.get('owner'));
        if (owners!=null) {
            if (owners.isEmpty()) filters.add('assignee is EMPTY');
            else {
                List<String> identities=new List<String>();
                for (Atlas_Person__c p : [SELECT Jira_Account_Id__c FROM Atlas_Person__c WHERE Id IN :owners WITH USER_MODE]) {
                    if (String.isBlank(p.Jira_Account_Id__c)) throw problem('A selected person has no confirmed Jira identity.');
                    identities.add(quote(p.Jira_Account_Id__c));
                }
                filters.add('assignee in ('+String.join(identities,',')+')');
            }
        }
        if (request.get('keys') != null) {
            List<String> keys=new List<String>();
            if (!(request.get('keys') instanceof List<Object>) || ((List<Object>)request.get('keys')).size()>50) throw problem('Use at most 50 Jira keys.');
            for (Object raw : (List<Object>)request.get('keys')) keys.add(issueKey(raw));
            if (keys.isEmpty()) throw problem('Supply at least one Jira key.');
            filters.add('key in ('+String.join(keys,',')+')');
        }
        String term=text(request,'text',200,false), status=text(request,'status',80,false);
        if (String.isNotBlank(term)) filters.add('summary ~ '+quote(term));
        if (String.isNotBlank(status)) filters.add('statusCategory = '+quote(status));
        if (request.get('epicsOnly')==true) filters.add('issuetype = Epic');
        Map<String,Object> read=new Map<String,Object>{'action'=>'search','jql'=>(filters.isEmpty() ? '' : String.join(filters,' AND ')+' ')+'ORDER BY updated DESC',
            'maxResults'=>Math.min(number(request,'limit',25,500),50)};
        if (request.get('description')==true) read.put('fields',new List<Object>{'summary','description','status','issuetype','assignee','priority','duedate','parent','updated'});
        if (request.get('cursor')!=null) read.put(c.apiVersion=='3' ? 'nextPageToken' : 'startAt',c.apiVersion=='3' ? request.get('cursor') : Integer.valueOf((String)request.get('cursor')));
        return JSON.serialize(run(read));
    }
}
