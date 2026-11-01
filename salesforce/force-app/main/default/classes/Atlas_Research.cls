/**
 * Read-only org research for agent requests. The component calls run() once per
 * request, so each request gets its own governor limits. Results are JSON strings
 * the component turns into the reply text for the agent.
 */
public with sharing class Atlas_Research {
    public static final Integer DEFAULT_ROWS = 200;
    public static final Integer MAX_ROWS = 2000;
    static final Integer MAX_RESPONSE_CHARS = 3000000;
    static final Integer MAX_RETRIEVE_COMPONENTS = 100;
    static final Integer MAX_RETRIEVE_CHARS = 2500000;

    @AuraEnabled
    public static String run(String requestJson) {
        try {
            Map<String, Object> request = (Map<String, Object>) JSON.deserializeUntyped(requestJson);
            String op = (String) request.get('op');
            if (op == 'soql') return query(text(request, 'query'), request.get('all') == true, false, rowLimit(request));
            if (op == 'tooling') return query(text(request, 'query'), false, true, rowLimit(request));
            if (op == 'sosl') return Atlas_Api.get(Atlas_Api.DATA + '/search/?q=' + EncodingUtil.urlEncode(text(request, 'search'), 'UTF-8'), null);
            if (op == 'describe') return describe((String) request.get('object'), request.get('fields'));
            if (op == 'metadata-types') return metadataTypes();
            if (op == 'metadata-list') return metadataList(text(request, 'type'), (String) request.get('folder'));
            if (op == 'retrieve') return JSON.serialize(new Map<String, Object>{
                'asyncId' => Atlas_Api.startRetrieve(Atlas_Api.components(request.get('components'), MAX_RETRIEVE_COMPONENTS))
            });
            if (op == 'rest') return rest(text(request, 'path'));
            if (op == 'activity') return activity(request);
            if (op == 'jira') return JSON.serialize(Atlas_Jira.run(request));
            if (op == 'tickets') return Atlas_Jira.tickets(request);
            if (op == 'local-tickets') return Atlas_Tickets.agentQuery(request);
            if (op == 'users') return Atlas_Identity.lookup(text(request, 'term'));
            if (op == 'people') return JSON.serialize(Atlas_Data.peoplePage((Id) request.get('afterId')));
            throw new Atlas_Api.AtlasException('Unknown op "' + op + '".');
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /** Polls a retrieve started by run(). Returns the files once Salesforce is done. */
    @AuraEnabled
    public static String retrieveStatus(String asyncId) {
        try {
            Atlas_Api.Retrieved result = Atlas_Api.checkRetrieve(asyncId);
            Map<String, Object> out = new Map<String, Object>{
                'done' => result.done, 'status' => result.status, 'error' => result.error, 'problems' => result.problems
            };
            if (result.done && result.zip != null) {
                out.put('files', Atlas_Api.unzip(result.zip, MAX_RETRIEVE_CHARS));
                out.put('components', result.properties);
            }
            return JSON.serialize(out);
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    static String text(Map<String, Object> request, String key) {
        Object value = request.get(key);
        if (!(value instanceof String) || String.isBlank((String) value)) {
            throw new Atlas_Api.AtlasException('"' + key + '" is required for op "' + request.get('op') + '".');
        }
        return (String) value;
    }

    static Integer rowLimit(Map<String, Object> request) {
        Object value = request.get('maxRows');
        Integer wanted = value instanceof Integer ? (Integer) value : value instanceof Decimal ? ((Decimal) value).intValue() : DEFAULT_ROWS;
        return Math.max(1, Math.min(MAX_ROWS, wanted));
    }

    /**
     * Runs SOQL through the REST API so large or slow queries report errors instead of
     * crashing Apex. Pages are passed through untouched; the component trims to maxRows.
     */
    static String query(String soql, Boolean includeDeleted, Boolean tooling, Integer maxRows) {
        String path = Atlas_Api.DATA + (tooling ? '/tooling/query/' : includeDeleted ? '/queryAll/' : '/query/')
            + '?q=' + EncodingUtil.urlEncode(soql, 'UTF-8');
        Map<String, String> headers = new Map<String, String>{ 'Sforce-Query-Options' => 'batchSize=200' };
        List<String> pages = new List<String>();
        Integer chars = 0;
        Integer fetched = 0;
        while (path != null) {
            String body = Atlas_Api.get(path, headers);
            pages.add(body);
            chars += body.length();
            QueryPage page = queryPage(body);
            fetched += page.rows;
            path = page.nextUrl;
            if (fetched >= maxRows || chars > MAX_RESPONSE_CHARS || Limits.getCallouts() >= Limits.getLimitCallouts() - 2) break;
        }
        return '{"maxRows":' + maxRows + ',"truncated":' + (path != null) + ',"pages":[' + String.join(pages, ',') + ']}';
    }

    class QueryPage {
        Integer rows = 0;
        String nextUrl;
    }

    /** Read only root pagination; a nested relationship has its own independent cursor.
     * Streaming skips record bodies without changing numeric values or doubling heap. */
    static QueryPage queryPage(String body) {
        QueryPage page = new QueryPage();
        JSONParser parser = JSON.createParser(body);
        if (parser.nextToken() != JSONToken.START_OBJECT) throw new Atlas_Api.AtlasException('Salesforce returned an invalid query page.');
        while (parser.nextToken() != JSONToken.END_OBJECT) {
            if (parser.getCurrentToken() != JSONToken.FIELD_NAME) throw new Atlas_Api.AtlasException('Salesforce returned an incomplete query page.');
            String field = parser.getText();
            JSONToken value = parser.nextToken();
            if (field == 'nextRecordsUrl' && value == JSONToken.VALUE_STRING) page.nextUrl = parser.getText();
            else if (field == 'records' && value == JSONToken.START_ARRAY) {
                while (parser.nextToken() != JSONToken.END_ARRAY) {
                    if (parser.getCurrentToken() != JSONToken.START_OBJECT) throw new Atlas_Api.AtlasException('Salesforce returned an invalid query record.');
                    page.rows++;
                    parser.skipChildren();
                }
            } else parser.skipChildren();
        }
        return page;
    }

    /** GET is not a read-only guarantee: Tooling executeAnonymous also uses GET.
     * Accept only canonical, explicitly read-only resources. Never decode a route:
     * encoded separators, dot segments and nested encodings must fail closed.
     * Query names are allowlisted too, so method-override parameters cannot turn
     * an otherwise safe URL into a write. Values (such as encoded SOQL) stay intact.
     */
    @TestVisible
    static String readOnlyRestPath(String path) {
        String problem = 'rest reads only approved read-only Salesforce paths: limits, query/queryAll (including cursors), tooling/query, search, sobjects descriptions, and ui-api/record-ui. Use the dedicated research operations for other reads.';
        if (String.isBlank(path) || path.contains('#') || path.contains(';') || path.contains('\\') || Pattern.compile('[\\x00-\\x20\\x7f]').matcher(path).find())
            throw new Atlas_Api.AtlasException(problem);
        // Agents often write "/limits" or "limits"; read those under the current API version.
        if (!path.startsWith('/services/data/')) path = Atlas_Api.DATA + (path.startsWith('/') ? '' : '/') + path;
        Integer queryAt = path.indexOf('?');
        String route = queryAt < 0 ? path : path.substring(0, queryAt);
        Matcher version = Pattern.compile('^/services/data/v[0-9]+\\.[0-9]+(/.*)$').matcher(route);
        if (!version.matches()) throw new Atlas_Api.AtlasException(problem);
        String resource = version.group(1);
        Set<String> parameters = new Set<String>();
        if (Pattern.matches('/(?:query|queryAll|tooling/query)(?:/[A-Za-z0-9-]+)?/?', resource) || Pattern.matches('/search/?', resource)) {
            parameters.add('q');
        } else if (Pattern.matches('/limits/?', resource)
            || Pattern.matches('/(?:tooling/)?sobjects(?:/[A-Za-z][A-Za-z0-9_]*/describe)?/?', resource)) {
            // Global and object descriptions take no query parameters here.
        } else if (Pattern.matches('/ui-api/record-ui/[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?(?:,[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?)*/?', resource)) {
            parameters.addAll(new List<String>{'layoutTypes', 'modes', 'optionalFields', 'childRelationships', 'formFactor'});
        } else throw new Atlas_Api.AtlasException(problem);
        if (queryAt >= 0) {
            Set<String> seen = new Set<String>();
            String query = path.substring(queryAt + 1);
            if (String.isBlank(query)) throw new Atlas_Api.AtlasException(problem);
            for (String pair : query.split('&')) {
                Integer equalAt = pair.indexOf('=');
                String name = equalAt < 0 ? pair : pair.substring(0, equalAt);
                if (equalAt < 0 || !parameters.contains(name) || !seen.add(name)) throw new Atlas_Api.AtlasException(problem);
            }
        }
        return path;
    }

    static String rest(String path) {
        path = readOnlyRestPath(path);
        String body = Atlas_Api.get(path, null);
        return JSON.serialize(new Map<String, Object>{
            'path' => path, 'length' => body.length(), 'body' => body.left(MAX_RESPONSE_CHARS / 6)
        });
    }

    // ---------------------------------------------------------------- describe

    // Long picklists (states, countries) are cut unless the agent names the field.
    static final Integer PICKLIST_SHOWN = 25;

    static String describe(String objectName, Object fieldFilter) {
        Map<String, Schema.SObjectType> types = Schema.getGlobalDescribe();
        if (String.isBlank(objectName)) {
            List<String> lines = new List<String>();
            for (Schema.SObjectType type : types.values()) {
                Schema.DescribeSObjectResult d = type.getDescribe(SObjectDescribeOptions.DEFERRED);
                if (!d.isQueryable() || !d.isAccessible()) continue;
                lines.add(d.getName() + ' | ' + d.getLabel() + (d.isCustom() ? ' | custom' : ''));
            }
            lines.sort();
            return JSON.serialize(new Map<String, Object>{ 'objects' => lines });
        }
        Schema.SObjectType type = types.get(objectName.toLowerCase());
        if (type == null) throw new Atlas_Api.AtlasException('No object named ' + objectName + '. Use describe without "object" to list objects.');
        Schema.DescribeSObjectResult d = type.getDescribe(SObjectDescribeOptions.FULL);
        if (!d.isAccessible()) throw new Atlas_Api.AtlasException('You do not have read access to ' + d.getName() + '.');
        Map<String, Schema.SObjectField> all = d.fields.getMap();
        Set<String> wanted = null;
        List<String> missing = new List<String>();
        if (fieldFilter != null) {
            if (!(fieldFilter instanceof List<Object>)) throw new Atlas_Api.AtlasException('describe "fields" must be a list of field API names.');
            wanted = new Set<String>();
            for (Object name : (List<Object>) fieldFilter) {
                String key = String.valueOf(name).trim().toLowerCase();
                if (all.containsKey(key) && all.get(key).getDescribe().isAccessible()) wanted.add(key); else missing.add(String.valueOf(name));
            }
        }
        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        for (String key : all.keySet()) {
            if (wanted != null && !wanted.contains(key)) continue;
            Schema.DescribeFieldResult f = all.get(key).getDescribe();
            if (!f.isAccessible()) continue;
            Map<String, Object> row = new Map<String, Object>{
                'name' => f.getName(), 'label' => f.getLabel(), 'type' => String.valueOf(f.getType())
            };
            if (f.getLength() > 0) row.put('length', f.getLength());
            if (f.getPrecision() > 0) row.put('precision', String.valueOf(f.getPrecision()) + ',' + f.getScale());
            if (!f.getReferenceTo().isEmpty()) {
                List<String> targets = new List<String>();
                for (Schema.SObjectType target : f.getReferenceTo()) targets.add(String.valueOf(target));
                row.put('referenceTo', targets);
                row.put('relationshipName', f.getRelationshipName());
            }
            if (f.isCalculated()) row.put('formula', f.getCalculatedFormula());
            if (f.isCustom()) row.put('custom', true);
            if (!f.isNillable() && f.isCreateable() && f.getType() != Schema.DisplayType.BOOLEAN) row.put('required', true);
            if (f.isExternalId()) row.put('externalId', true);
            if (f.isUnique()) row.put('unique', true);
            if (String.isNotBlank(f.getInlineHelpText())) row.put('help', f.getInlineHelpText());
            List<Schema.PicklistEntry> values = f.getPicklistValues();
            if (!values.isEmpty()) {
                List<String> active = new List<String>();
                for (Schema.PicklistEntry value : values) {
                    if (value.isActive()) active.add(value.getValue() == value.getLabel() ? value.getValue() : value.getValue() + ' (' + value.getLabel() + ')');
                }
                if (wanted == null && active.size() > PICKLIST_SHOWN) {
                    row.put('picklistTotal', active.size());
                    while (active.size() > PICKLIST_SHOWN) active.remove(active.size() - 1);
                }
                row.put('picklist', active);
            }
            fields.add(row);
        }
        // Naming fields asks about those fields only.
        if (wanted != null) {
            return JSON.serialize(new Map<String, Object>{
                'object' => d.getName(), 'label' => d.getLabel(), 'custom' => d.isCustom(), 'keyPrefix' => d.getKeyPrefix(),
                'fields' => fields, 'missing' => missing
            });
        }
        List<String> children = new List<String>();
        for (Schema.ChildRelationship child : d.getChildRelationships()) {
            if (child.getRelationshipName() != null && child.getChildSObject().getDescribe().isAccessible() && child.getField().getDescribe().isAccessible()) {
                children.add(child.getRelationshipName() + ' → ' + child.getChildSObject() + '.' + child.getField());
            }
        }
        List<String> recordTypes = new List<String>();
        for (Schema.RecordTypeInfo info : d.getRecordTypeInfos()) {
            if (!info.isMaster() && info.isAvailable()) recordTypes.add(info.getDeveloperName() + ' (' + info.getName() + (info.isActive() ? '' : ', inactive') + ')');
        }
        return JSON.serialize(new Map<String, Object>{
            'object' => d.getName(), 'label' => d.getLabel(), 'custom' => d.isCustom(), 'keyPrefix' => d.getKeyPrefix(),
            'fields' => fields, 'childRelationships' => children, 'recordTypes' => recordTypes
        });
    }

    // ---------------------------------------------------------------- metadata

    static String metadataTypes() {
        Atlas_Api.SoapResult res = Atlas_Api.metadata('describeMetadata', '<asOfVersion>' + Atlas_Api.VERSION + '</asOfVersion>');
        Dom.XmlNode result = res.node.getChildElement('result', 'http://soap.sforce.com/2006/04/metadata');
        List<String> types = new List<String>();
        for (Dom.XmlNode type : Atlas_Api.children(result, 'metadataObjects')) {
            String line = Atlas_Api.text(type, 'xmlName') + ' | folder ' + Atlas_Api.text(type, 'directoryName');
            List<String> childNames = new List<String>();
            for (Dom.XmlNode child : Atlas_Api.children(type, 'childXmlNames')) childNames.add(child.getText());
            if (!childNames.isEmpty()) line += ' | children ' + String.join(childNames, ', ');
            types.add(line);
        }
        types.sort();
        return JSON.serialize(new Map<String, Object>{ 'types' => types });
    }

    static String metadataList(String type, String folder) {
        String query = '<queries><folder>' + Atlas_Api.xml(folder) + '</folder><type>' + Atlas_Api.xml(type) + '</type></queries>';
        if (String.isBlank(folder)) query = '<queries><type>' + Atlas_Api.xml(type) + '</type></queries>';
        Atlas_Api.SoapResult res = Atlas_Api.metadata('listMetadata', query + '<asOfVersion>' + Atlas_Api.VERSION + '</asOfVersion>');
        List<String> rows = new List<String>();
        for (Dom.XmlNode item : Atlas_Api.children(res.node, 'result')) {
            Map<String, Object> f = Atlas_Api.flat(item);
            rows.add(String.valueOf(f.get('fullName')) + ' | ' + f.get('fileName') + ' | modified ' + String.valueOf(f.get('lastModifiedDate')).left(10)
                + ' by ' + f.get('lastModifiedByName') + (f.get('namespacePrefix') == null ? '' : ' | namespace ' + f.get('namespacePrefix')));
        }
        rows.sort();
        return JSON.serialize(new Map<String, Object>{ 'type' => type, 'count' => rows.size(), 'items' => rows });
    }

    // ---------------------------------------------------------------- activity

    /** Tooling objects checked for recent changes, with the field that names each item. */
    static final List<List<String>> ACTIVITY_SOURCES = new List<List<String>>{
        new List<String>{ 'ApexClass', 'Name' },
        new List<String>{ 'ApexTrigger', 'Name' },
        new List<String>{ 'LightningComponentBundle', 'DeveloperName' },
        new List<String>{ 'AuraDefinitionBundle', 'DeveloperName' },
        new List<String>{ 'ApexPage', 'Name' },
        new List<String>{ 'Flow', 'MasterLabel' },
        new List<String>{ 'CustomObject', 'DeveloperName' },
        new List<String>{ 'CustomField', 'DeveloperName' },
        new List<String>{ 'Layout', 'Name' },
        new List<String>{ 'FlexiPage', 'DeveloperName' },
        new List<String>{ 'ValidationRule', 'ValidationName' },
        new List<String>{ 'PermissionSet', 'Name' },
        new List<String>{ 'StaticResource', 'Name' },
        new List<String>{ 'EmailTemplate', 'Name' }
    };

    /**
     * Recent setup and development changes by me, my team or named people:
     * the Setup Audit Trail plus last-modified dates of common metadata.
     */
    static String activity(Map<String, Object> request) {
        // JSON numbers like 7.0 arrive as Decimal; they used to fall back to 14 days silently.
        Object asked = request.get('days');
        Integer days = asked instanceof Integer ? (Integer) asked : asked instanceof Decimal ? ((Decimal) asked).intValue() : 14;
        days = Math.max(1, Math.min(180, days));
        Map<Id, String> users = activityUsers(request.get('who'));
        if (users.isEmpty()) throw new Atlas_Api.AtlasException('No Salesforce users matched "who". Link people to Salesforce users in Team & Jira.');
        Set<Id> userIds = users.keySet();
        Datetime since = Datetime.now().addDays(-days);

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        List<String> limited = new List<String>();
        for (SetupAuditTrail entry : [
            SELECT CreatedDate, CreatedById, Section, Display
            FROM SetupAuditTrail WHERE CreatedById IN :userIds AND CreatedDate >= :since
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1001
        ]) {
            if (rows.size() == 1000) {
                limited.add('Setup Audit Trail: showing the latest 1000 actions; more match this period.');
                break;
            }
            rows.add(new Map<String, Object>{
                'when' => entry.CreatedDate, 'who' => users.get(entry.CreatedById), 'source' => 'Setup Audit Trail',
                'what' => entry.Section, 'detail' => entry.Display
            });
        }
        List<String> idList = new List<String>();
        for (Id userId : userIds) idList.add('\'' + userId + '\'');
        List<String> skipped = new List<String>();
        String sinceText = since.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        List<String> paths = new List<String>();
        for (List<String> source : ACTIVITY_SOURCES) {
            String soql = 'SELECT Id, ' + source[1] + ', LastModifiedDate, LastModifiedById, CreatedDate FROM ' + source[0]
                + ' WHERE LastModifiedDate >= ' + sinceText + ' AND LastModifiedById IN (' + String.join(idList, ',') + ')'
                + ' ORDER BY LastModifiedDate DESC LIMIT 201';
            paths.add('/tooling/query/?q=' + EncodingUtil.urlEncode(soql, 'UTF-8'));
        }
        List<Object> batched = toolingBatch(paths);
        for (Integer s = 0; s < ACTIVITY_SOURCES.size(); s++) {
            List<String> source = ACTIVITY_SOURCES[s];
            try {
                Map<String, Object> page;
                if (batched == null) {
                    page = (Map<String, Object>) JSON.deserializeUntyped(Atlas_Api.get(Atlas_Api.DATA + paths[s], null));
                } else {
                    Map<String, Object> answer = (Map<String, Object>) batched[s];
                    if (answer.get('statusCode') != 200) throw new Atlas_Api.AtlasException(batchError(answer));
                    page = (Map<String, Object>) answer.get('result');
                }
                List<Object> records = (List<Object>) page.get('records');
                if (records.size() > 200 || page.get('done') == false || page.get('nextRecordsUrl') != null)
                    limited.add(source[0] + ': showing the latest ' + Math.min(200, records.size()) + ' items; more match this period.');
                for (Integer i = 0; i < Math.min(200, records.size()); i++) {
                    Map<String, Object> record = (Map<String, Object>) records[i];
                    String created = String.valueOf(record.get('CreatedDate'));
                    String modified = String.valueOf(record.get('LastModifiedDate'));
                    rows.add(new Map<String, Object>{
                        'when' => (Datetime) JSON.deserialize('"' + modified + '"', Datetime.class),
                        'who' => users.get((Id) record.get('LastModifiedById')),
                        'source' => source[0],
                        'what' => String.valueOf(record.get(source[1])) + ' (' + record.get('Id') + ')',
                        'detail' => created == modified ? 'Created' : 'Last modified'
                    });
                }
            } catch (Exception e) {
                skipped.add(source[0] + ': ' + e.getMessage().left(200));
            }
        }
        rows.sort(new NewestFirst());
        return JSON.serialize(new Map<String, Object>{
            'days' => days, 'people' => users.values(), 'count' => rows.size(), 'rows' => rows, 'skipped' => skipped, 'limited' => limited,
            'note' => 'Tooling rows show only the latest modification of each item; the Setup Audit Trail lists setup actions. This is evidence, not proof of ticket completion. Narrow the period or use scoped SOQL/Tooling requests for any incomplete sources.'
        });
    }

    /**
     * Runs up to 25 Tooling requests as one composite batch, so activity costs one round trip
     * instead of one per source. Returns one {statusCode, result} per path in order, or null
     * when the batch itself fails; the caller then asks each source on its own as before.
     */
    @TestVisible
    static List<Object> toolingBatch(List<String> paths) {
        if (paths.isEmpty() || paths.size() > 25) return null;
        List<Object> requests = new List<Object>();
        for (String path : paths) requests.add(new Map<String, Object>{'method' => 'GET', 'url' => 'v' + Atlas_Api.VERSION + path});
        try {
            HttpResponse res = Atlas_Api.send('POST', Atlas_Api.DATA + '/tooling/composite/batch',
                JSON.serialize(new Map<String, Object>{'batchRequests' => requests, 'haltOnError' => false}),
                new Map<String, String>{'Content-Type' => 'application/json', 'Accept' => 'application/json'});
            if (res.getStatusCode() != 200) return null;
            Object results = ((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('results');
            return results instanceof List<Object> && ((List<Object>) results).size() == paths.size() ? (List<Object>) results : null;
        } catch (Exception e) {
            return null;
        }
    }

    static String batchError(Map<String, Object> answer) {
        Object result = answer.get('result');
        if (result instanceof List<Object> && !((List<Object>) result).isEmpty() && ((List<Object>) result)[0] instanceof Map<String, Object>) {
            Map<String, Object> first = (Map<String, Object>) ((List<Object>) result)[0];
            return first.get('errorCode') + ': ' + first.get('message');
        }
        return 'HTTP ' + answer.get('statusCode');
    }

    class NewestFirst implements Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Datetime x = (Datetime) a.get('when');
            Datetime y = (Datetime) b.get('when');
            return x == y ? 0 : x > y ? -1 : 1;
        }
    }

    /** "me", "team" (me and my direct reports), "reports", or a list of names, aliases or user IDs. */
    static Map<Id, String> activityUsers(Object who) {
        Map<Id, String> users = new Map<Id, String>();
        String mode = who == null ? 'me' : who instanceof String ? ((String) who).trim().toLowerCase() : null;
        if (mode != null && mode != 'me' && mode != 'team' && mode != 'reports') {
            who = new List<Object>{ who };
            mode = null;
        }
        if (mode == 'me' || mode == 'team') users.put(UserInfo.getUserId(), UserInfo.getName());
        if (mode == 'team' || mode == 'reports') {
            for (Atlas_Person__c person : [
                SELECT User__c, User__r.Name FROM Atlas_Person__c
                WHERE Manager__r.User__c = :UserInfo.getUserId() AND User__c != null AND Active__c = true WITH USER_MODE
            ]) users.put(person.User__c, person.User__r.Name);
        }
        if (mode != null) return users;
        if (!(who instanceof List<Object>)) throw new Atlas_Api.AtlasException('"who" must be "me", "team", "reports" or a list of people.');
        Set<String> wanted = new Set<String>();
        List<String> ids = new List<String>();
        for (Object item : (List<Object>) who) {
            String value = String.valueOf(item).trim();
            if (Atlas_Identity.isManagerRole(value)) {
                Map<String,Object> manager = Atlas_Identity.managerIdentity(value);
                if (manager.get('userId') == null)
                    throw new Atlas_Api.AtlasException('Link the manager to an active Salesforce user in Team & Jira before requesting activity.');
                users.put((Id)manager.get('userId'), (String)manager.get('userName'));
                continue;
            }
            wanted.add(Atlas_Data.aliasKey(value));
            if (Pattern.matches('005[A-Za-z0-9]{12}([A-Za-z0-9]{3})?', value)) ids.add(value);
        }
        for (Atlas_Person__c person : [
            SELECT Name, Jira_Account_Id__c, Aliases__c, Alias_List__c, User__c, User__r.Name FROM Atlas_Person__c WHERE User__c != null AND Active__c = true WITH USER_MODE LIMIT 5000
        ]) {
            Set<String> keys = new Set<String>{ Atlas_Data.aliasKey(person.Name) };
            for (String alias : Atlas_Identity.names(person)) keys.add(Atlas_Data.aliasKey(alias));
            keys.add(Atlas_Data.aliasKey(person.Jira_Account_Id__c));
            for (String key : keys) {
                if (wanted.contains(key)) users.put(person.User__c, person.User__r.Name);
            }
        }
        for (User user : [SELECT Id, Name FROM User WHERE Name IN :wanted OR Id IN :ids WITH USER_MODE LIMIT 200]) users.put(user.Id, user.Name);
        return users;
    }
}
