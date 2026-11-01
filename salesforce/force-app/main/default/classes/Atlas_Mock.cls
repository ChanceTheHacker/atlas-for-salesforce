/**
 * Test double for this org's REST, Tooling and Metadata APIs. Routes by endpoint
 * and SOAPAction and returns small, realistic responses.
 */
@IsTest
public class Atlas_Mock implements HttpCalloutMock {
    public static Boolean retrieveDone = true;
    /** Status checks that still answer "in progress" before retrieveDone takes effect. */
    public static Integer retrievePending = 0;
    public static Boolean deploySuccess = true;
    public static Integer calls = 0;
    /** Composite batch requests answered, each counted once in calls. */
    public static Integer batches = 0;
    /**
     * Set by a test to retrieve its own files: the ZIP and the fileProperties Salesforce
     * reports for it (see property). A bundle is reported once per file, never as a whole,
     * and its -meta.xml file is not reported at all, as a real retrieve does.
     */
    public static Blob retrieveZip;
    public static String retrieveProperties;
    /** The last deployment package sent to Salesforce. */
    public static Blob deployedZip;
    /** The file a teammate edits in Salesforce after the backup, for the sourceChanged mock. */
    public static String changedPath = 'classes/Foo.cls';
    Boolean sourceChanged = false;
    public Atlas_Mock() {}
    public Atlas_Mock(Boolean sourceChanged) { this.sourceChanged = sourceChanged; }

    static final String ENVELOPE_START = '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns="http://soap.sforce.com/2006/04/metadata">'
        + '<soapenv:Body>';
    static final String ENVELOPE_END = '</soapenv:Body></soapenv:Envelope>';

    public HttpResponse respond(HttpRequest req) {
        calls++;
        String endpoint = req.getEndpoint();
        if (endpoint.contains('timeout')) throw new CalloutException('Read timed out');
        if (endpoint.contains('/services/Soap/m/')) {
            if (req.getHeader('SOAPAction') == 'deploy') deployedZip = EncodingUtil.base64Decode(req.getBody().substringBetween('<ZipFile>', '</ZipFile>'));
            HttpResponse response = soap(req.getHeader('SOAPAction'), req.getBody());
            if (sourceChanged && req.getHeader('SOAPAction') == 'checkRetrieveStatus') {
                Compression.ZipReader old = new Compression.ZipReader(retrieveZip ?? backupZip());
                Compression.ZipWriter changed = new Compression.ZipWriter();
                for (Compression.ZipEntry entry : old.getEntries()) {
                    changed.addEntry(entry.getName(), entry.getName() == changedPath ? Blob.valueOf('/* teammate edit */') : old.extract(entry));
                }
                response.setBody(response.getBody().replaceAll('<zipFile>[^<]+</zipFile>', '<zipFile>' + EncodingUtil.base64Encode(changed.getArchive()) + '</zipFile>'));
            }
            return response;
        }
        if (endpoint.contains('/composite/batch')) {
            batches++;
            List<Object> results = new List<Object>();
            for (Object item : (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(req.getBody())).get('batchRequests')) {
                HttpResponse one = query(String.valueOf(((Map<String, Object>) item).get('url')));
                results.add(new Map<String, Object>{'statusCode' => one.getStatusCode(), 'result' => JSON.deserializeUntyped(one.getBody())});
            }
            return json(200, JSON.serialize(new Map<String, Object>{'hasErrors' => false, 'results' => results}));
        }
        if (endpoint.contains('/search/')) return json(200, '{"searchRecords":[{"attributes":{"type":"Account"},"Id":"001000000000001AAA"}]}');
        if (endpoint.contains('/query/') || endpoint.contains('/queryAll/')) return query(endpoint);
        if (endpoint.contains('/broken')) return json(400, '[{"errorCode":"NOT_FOUND","message":"The requested resource does not exist"}]');
        if (endpoint.contains('/expired')) return json(401, '[{"errorCode":"INVALID_SESSION_ID","message":"Session expired"}]');
        if (endpoint.contains('/plain-error')) return json(500, 'Server exploded');
        return json(200, '{"DailyApiRequests":{"Max":15000,"Remaining":14999}}');
    }

    static HttpResponse json(Integer status, String body) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(status);
        res.setHeader('Content-Type', 'application/json');
        res.setBody(body);
        return res;
    }

    static HttpResponse query(String endpoint) {
        String soql = EncodingUtil.urlDecode(endpoint.substringAfter('?q='), 'UTF-8');
        if (endpoint.contains('/query/01g')) {
            return json(200, '{"totalSize":3,"done":true,"records":[{"attributes":{"type":"Account"},"Name":"Third"}]}');
        }
        if (soql.contains('FROM Account')) {
            return json(200, '{"totalSize":3,"done":false,"nextRecordsUrl":"/services/data/v67.0/query/01gTEST-200",'
                + '"records":[{"attributes":{"type":"Account"},"Name":"First"},{"attributes":{"type":"Account"},"Name":"Second"}]}');
        }
        if (soql.contains('FROM ApexClass')) {
            return json(200, '{"totalSize":1,"done":true,"records":[{"attributes":{"type":"ApexClass"},"Id":"01p000000000001AAA",'
                + '"Name":"Foo","LastModifiedDate":"2026-10-01T10:00:00.000+0000","LastModifiedById":"' + UserInfo.getUserId()
                + '","CreatedDate":"2026-10-01T10:00:00.000+0000"}]}');
        }
        if (soql.contains('FROM Flow')) return json(400, '[{"errorCode":"INVALID_TYPE","message":"Flow is not supported here"}]');
        return json(200, '{"totalSize":0,"done":true,"records":[]}');
    }

    static HttpResponse soap(String action, String body) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setHeader('Content-Type', 'text/xml');
        String result;
        if (action == 'retrieve') {
            result = '<retrieveResponse><result><done>false</done><id>09S000000000001AAA</id><state>Queued</state></result></retrieveResponse>';
        } else if (action == 'checkRetrieveStatus') {
            Boolean done = retrieveDone && retrievePending <= 0;
            retrievePending--;
            result = done ? retrieved() : '<checkRetrieveStatusResponse><result><done>false</done><status>InProgress</status></result></checkRetrieveStatusResponse>';
        } else if (action == 'deploy') {
            result = '<deployResponse><result><done>false</done><id>0Af000000000001AAA</id><state>Queued</state></result></deployResponse>';
        } else if (action == 'checkDeployStatus') {
            result = deployed();
        } else if (action == 'describeMetadata') {
            result = '<describeMetadataResponse><result><metadataObjects><childXmlNames>CustomField</childXmlNames><directoryName>objects</directoryName>'
                + '<xmlName>CustomObject</xmlName></metadataObjects><metadataObjects><directoryName>classes</directoryName><suffix>cls</suffix><xmlName>ApexClass</xmlName>'
                + '</metadataObjects><metadataObjects><directoryName>lwc</directoryName><xmlName>LightningComponentBundle</xmlName></metadataObjects>'
                + '<metadataObjects><directoryName>aura</directoryName><xmlName>AuraDefinitionBundle</xmlName></metadataObjects></result></describeMetadataResponse>';
        } else if (action == 'listMetadata') {
            result = '<listMetadataResponse><result><fileName>classes/Foo.cls</fileName><fullName>Foo</fullName><lastModifiedByName>Ann Admin</lastModifiedByName>'
                + '<lastModifiedDate>2026-10-01T10:00:00.000Z</lastModifiedDate><type>ApexClass</type></result>'
                + '<result><fileName>classes/Bar.cls</fileName><fullName>Bar</fullName><lastModifiedByName>Ann Admin</lastModifiedByName>'
                + '<lastModifiedDate>2026-10-02T10:00:00.000Z</lastModifiedDate><namespacePrefix>pkg</namespacePrefix><type>ApexClass</type></result></listMetadataResponse>';
        } else {
            res.setStatusCode(500);
            res.setBody(action == 'garbage' ? '<html>Oops</html' : '<?xml version="1.0" encoding="UTF-8"?>'
                + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sf="http://soap.sforce.com/2006/04/metadata">'
                + '<soapenv:Body><soapenv:Fault><faultcode>sf:INVALID_TYPE</faultcode><faultstring>Unknown operation ' + action
                + '</faultstring></soapenv:Fault>' + ENVELOPE_END);
            return res;
        }
        res.setBody(ENVELOPE_START + result + ENVELOPE_END);
        return res;
    }

    /**
     * A test user with the Atlas User permission set. Apex in this API version enforces
     * field access, so tests run as this user instead of whoever deploys.
     */
    public static User atlasUser() {
        String username = 'atlas-test-' + UserInfo.getOrganizationId() + '@example.com';
        List<User> existing = [SELECT Id FROM User WHERE Username = :username];
        if (!existing.isEmpty()) return existing[0];
        String namespace = [SELECT NamespacePrefix FROM Organization LIMIT 1].NamespacePrefix;
        Profile admin = [SELECT Id FROM Profile WHERE PermissionsModifyAllData = true AND UserType = 'Standard' ORDER BY CreatedDate LIMIT 1];
        User tester = new User(Username = username, LastName = 'Atlas Tester', Email = 'atlas-test@example.com', Alias = 'atltest',
            ProfileId = admin.Id, TimeZoneSidKey = 'America/New_York', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert tester;
            insert new PermissionSetAssignment(AssigneeId = tester.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Atlas_User' AND NamespacePrefix = :namespace LIMIT 1].Id);
        }
        return tester;
    }

    public static Blob backupZip() {
        Compression.ZipWriter writer = new Compression.ZipWriter();
        writer.addEntry('package.xml', Blob.valueOf('<Package/>'));
        writer.addEntry('classes/Foo.cls', Blob.valueOf('public class Foo {\n    public static Integer one() { return 1; }\n}\n'));
        writer.addEntry('classes/Foo.cls-meta.xml', Blob.valueOf('<ApexClass><apiVersion>67.0</apiVersion></ApexClass>'));
        writer.addEntry('lwc/fooCmp/fooCmp.js', Blob.valueOf('export default class FooCmp {}\n'));
        writer.addEntry('lwc/fooCmp/fooCmp.js-meta.xml', Blob.valueOf('<LightningComponentBundle/>'));
        writer.addEntry('staticresources/Logo.resource', EncodingUtil.base64Decode('/9j/4AAQSkZJRgABAQ=='));
        return writer.getArchive();
    }

    public static String property(String type, String fullName, String fileName) {
        return property(type, fullName, fileName, null);
    }

    /** One retrieved file as Salesforce reports it; namespacePrefix is set for components in a namespace. */
    public static String property(String type, String fullName, String fileName, String namespacePrefix) {
        return '<fileProperties><createdByName>Ann Admin</createdByName><fileName>' + fileName + '</fileName><fullName>' + fullName
            + '</fullName><lastModifiedByName>Ann Admin</lastModifiedByName><lastModifiedDate>2026-10-01T10:00:00.000Z</lastModifiedDate>'
            + (namespacePrefix == null ? '' : '<namespacePrefix>' + namespacePrefix + '</namespacePrefix>')
            + '<type>' + type + '</type></fileProperties>';
    }

    static String retrieved() {
        return '<checkRetrieveStatusResponse><result><done>true</done>'
            + (retrieveProperties ?? property('ApexClass', 'Foo', 'classes/Foo.cls')
                + property('LightningComponentBundle', 'fooCmp/fooCmp.js', 'lwc/fooCmp/fooCmp.js')
                + property('StaticResource', 'Logo', 'staticresources/Logo.resource'))
            + property('Package', 'package.xml', 'package.xml')
            + '<id>09S000000000001AAA</id><messages><fileName>package.xml</fileName><problem>Entity of type ApexClass named NewOne cannot be found</problem></messages>'
            + '<status>Succeeded</status><success>true</success><zipFile>' + EncodingUtil.base64Encode(retrieveZip ?? backupZip()) + '</zipFile></result></checkRetrieveStatusResponse>';
    }

    /**
     * Three LWC bundles as a real org holds them: a library whose entry module imports its
     * sibling modules, a CSS-only style bundle, and a component with markup and styles.
     * Pass it to bundleProperties for the per-file fileProperties of the same files.
     */
    public static Map<String, String> bundleFiles() {
        return new Map<String, String>{
            'lwc/fooLib/fooLib.js' => 'export { remember } from \'./history\';\nexport { label } from \'./format\';\n',
            'lwc/fooLib/history.js' => 'export function remember(item) {\n    return [item];\n}\n',
            'lwc/fooLib/format.js' => 'export function label(text) {\n    return text.trim();\n}\n',
            'lwc/fooLib/fooLib.js-meta.xml' => '<LightningComponentBundle><apiVersion>67.0</apiVersion><isExposed>false</isExposed></LightningComponentBundle>',
            'lwc/fooStyles/fooStyles.css' => '.foo { color: inherit; }\n',
            'lwc/fooStyles/fooStyles.js-meta.xml' => '<LightningComponentBundle><apiVersion>67.0</apiVersion><isExposed>false</isExposed></LightningComponentBundle>',
            'lwc/fooWork/fooWork.js' => 'import { remember } from \'c/fooLib\';\nexport default class FooWork {}\n',
            'lwc/fooWork/fooWork.html' => '<template><p>Work</p></template>\n',
            'lwc/fooWork/fooWork.css' => '@import \'c/fooStyles\';\n',
            'lwc/fooWork/fooWork.js-meta.xml' => '<LightningComponentBundle><apiVersion>67.0</apiVersion><isExposed>true</isExposed></LightningComponentBundle>',
            'classes/Foo.cls' => 'public class Foo {\n    public static Integer one() { return 1; }\n}\n',
            'classes/Foo.cls-meta.xml' => '<ApexClass><apiVersion>67.0</apiVersion></ApexClass>'
        };
    }

    /** Every entry of a ZIP by path, once each; a repeated path fails the test. */
    public static Map<String, String> entries(Blob zip) {
        Map<String, String> out = new Map<String, String>();
        Compression.ZipReader reader = new Compression.ZipReader(zip);
        for (Compression.ZipEntry entry : reader.getEntries()) {
            System.assert(!out.containsKey(entry.getName()), entry.getName() + ' appears twice in the package');
            out.put(entry.getName(), reader.extract(entry).toString());
        }
        return out;
    }

    /** What a package.xml lists: "Type" → its members, and "version" → the API version. */
    public static Map<String, List<String>> packageOf(Blob zip) {
        Dom.Document doc = new Dom.Document();
        doc.load(entries(zip).get('package.xml'));
        Map<String, List<String>> out = new Map<String, List<String>>();
        for (Dom.XmlNode node : doc.getRootElement().getChildElements()) {
            if (node.getName() == 'version') out.put('version', new List<String>{ node.getText() });
            if (node.getName() != 'types') continue;
            List<String> members = new List<String>();
            for (Dom.XmlNode child : node.getChildElements()) if (child.getName() == 'members') members.add(child.getText());
            out.put(node.getChildElement('name', 'http://soap.sforce.com/2006/04/metadata').getText(), members);
        }
        return out;
    }

    public static Blob zipOf(Map<String, String> files) {
        Compression.ZipWriter writer = new Compression.ZipWriter();
        writer.addEntry('package.xml', Blob.valueOf('<Package/>'));
        for (String path : files.keySet()) writer.addEntry(path, Blob.valueOf(files.get(path)));
        return writer.getArchive();
    }

    /** What a retrieve reports for these files: one entry per bundle file except -meta.xml, one per other component. */
    public static String bundleProperties(Map<String, String> files, String namespacePrefix) {
        String out = '';
        for (String path : files.keySet()) {
            if (path.endsWith('-meta.xml')) continue;
            String dir = path.substringBefore('/');
            if (dir == 'lwc' || dir == 'aura') out += property(dir == 'lwc' ? 'LightningComponentBundle' : 'AuraDefinitionBundle', path.substringAfter('/'), path, namespacePrefix);
            else if (dir == 'classes') out += property('ApexClass', path.substringAfter('/').removeEnd('.cls'), path, namespacePrefix);
        }
        return out;
    }

    static String deployed() {
        String details = deploySuccess ? '<details><runTestResult><numFailures>0</numFailures><numTestsRun>2</numTestsRun></runTestResult></details>'
            : '<details><componentFailures><columnNumber>5</columnNumber><componentType>ApexClass</componentType><fileName>classes/Foo.cls</fileName>'
                + '<fullName>Foo</fullName><lineNumber>2</lineNumber><problem>Unexpected token</problem><success>false</success></componentFailures>'
                + '<runTestResult><codeCoverageWarnings><message>Test coverage of selected Apex Class is 0%</message><name>Foo</name></codeCoverageWarnings>'
                + '<failures><message>Assertion failed</message><methodName>itWorks</methodName><name>FooTest</name><stackTrace>Class.FooTest.itWorks: line 3</stackTrace></failures>'
                + '<numFailures>1</numFailures><numTestsRun>1</numTestsRun></runTestResult></details>';
        return '<checkDeployStatusResponse><result><done>true</done><id>0Af000000000001AAA</id>' + details
            + '<numberComponentErrors>' + (deploySuccess ? 0 : 1) + '</numberComponentErrors><status>' + (deploySuccess ? 'Succeeded' : 'Failed')
            + '</status><success>' + deploySuccess + '</success></result></checkDeployStatusResponse>';
    }
}
