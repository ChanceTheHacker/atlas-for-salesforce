/**
 * Calls this org's own REST, Tooling and Metadata APIs as the signed-in user.
 * A Lightning session cannot call Salesforce APIs, but a Visualforce session can.
 * The Atlas_Session page hands that session to Apex; it never reaches the browser.
 */
public with sharing class Atlas_Api {
    public static final String VERSION = '67.0';
    public static final String DATA = '/services/data/v' + VERSION;
    static final String SOAP_NS = 'http://schemas.xmlsoap.org/soap/envelope/';
    static final String MD_NS = 'http://soap.sforce.com/2006/04/metadata';

    public virtual class AtlasException extends Exception {}
    /** Salesforce answered with a SOAP fault: it refused the request, so nothing was started. */
    public class RejectedException extends AtlasException {}

    static String cachedSession;

    /** Converts any failure into a message the Lightning component can show. */
    public static AuraHandledException fail(Exception e) {
        if (e instanceof AuraHandledException) return (AuraHandledException) e;
        String message = e instanceof AtlasException ? e.getMessage() : e.getTypeName() + ': ' + e.getMessage();
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    /** The current user's API session. Reading the page counts as a callout, so call this before any DML. */
    static String session() {
        if (cachedSession != null) return cachedSession;
        if (Test.isRunningTest()) {
            cachedSession = 'test-session';
            return cachedSession;
        }
        String value = Page.Atlas_Session.getContent().toString().trim();
        if (value.length() < 20 || value.contains('<')) {
            throw new AtlasException('Atlas could not get your Salesforce session. Make sure your user has the '
                + 'Atlas User permission set and the "API Enabled" permission.');
        }
        cachedSession = value;
        return cachedSession;
    }

    public static HttpResponse send(String method, String path, String body, Map<String, String> headers) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + path);
        req.setMethod(method);
        req.setTimeout(120000);
        req.setHeader('Authorization', 'Bearer ' + session());
        if (headers != null) {
            for (String name : headers.keySet()) req.setHeader(name, headers.get(name));
        }
        if (body != null) req.setBody(body);
        try {
            return new Http().send(req);
        } catch (CalloutException e) {
            if (e.getMessage().containsIgnoreCase('timed out')) {
                throw new AtlasException('Salesforce took longer than two minutes to answer. Ask for less data at once.');
            }
            throw new AtlasException('Salesforce API call failed: ' + e.getMessage());
        }
    }

    /** GET a REST resource of this org and return the response body. */
    public static String get(String path, Map<String, String> headers) {
        Map<String, String> all = new Map<String, String>{ 'Accept' => 'application/json' };
        if (headers != null) all.putAll(headers);
        HttpResponse res = send('GET', path, null, all);
        if (res.getStatusCode() == 401) throw new AtlasException('Salesforce rejected your session. Reload the page and try again.');
        if (res.getStatusCode() >= 300) throw new AtlasException(restError(res));
        return res.getBody();
    }

    static String restError(HttpResponse res) {
        String body = res.getBody() == null ? '' : res.getBody();
        try {
            List<String> messages = new List<String>();
            for (Object item : (List<Object>) JSON.deserializeUntyped(body)) {
                Map<String, Object> error = (Map<String, Object>) item;
                messages.add(error.get('errorCode') + ': ' + error.get('message'));
            }
            if (!messages.isEmpty()) return String.join(messages, '; ');
        } catch (Exception ignored) {
            // Not the usual error list; fall back to the raw body.
        }
        return 'HTTP ' + res.getStatusCode() + ': ' + body.left(2000);
    }

    // ---------------------------------------------------------------- Metadata API (SOAP)

    /** Escapes XML text. */
    public static String xml(String value) {
        if (value == null) return '';
        return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;').replace('\'', '&apos;');
    }

    public class SoapResult {
        public Dom.XmlNode node;
        public String zipBase64;
    }

    /** Calls a Metadata API operation. A returned zipFile is cut out before XML parsing to save heap. */
    public static SoapResult metadata(String action, String innerXml) {
        String envelope = '<?xml version="1.0" encoding="utf-8"?>'
            + '<env:Envelope xmlns:env="' + SOAP_NS + '" xmlns="' + MD_NS + '">'
            + '<env:Header><SessionHeader><sessionId>' + xml(session()) + '</sessionId></SessionHeader></env:Header>'
            + '<env:Body><' + action + '>' + innerXml + '</' + action + '></env:Body></env:Envelope>';
        HttpResponse res = send('POST', '/services/Soap/m/' + VERSION, envelope,
            new Map<String, String>{ 'Content-Type' => 'text/xml; charset=UTF-8', 'SOAPAction' => action });
        String body = res.getBody();
        SoapResult result = new SoapResult();
        Integer start = body.indexOf('<zipFile>');
        if (start >= 0) {
            Integer finish = body.indexOf('</zipFile>', start);
            if (finish < 0) throw new AtlasException('Metadata API returned an incomplete ZIP file (HTTP ' + res.getStatusCode() + '). Nothing was saved; try again.');
            result.zipBase64 = body.substring(start + 9, finish);
            body = body.left(start) + body.substring(finish + 10);
        }
        Dom.Document doc = new Dom.Document();
        try {
            doc.load(body);
        } catch (XmlException notXml) {
            throw new AtlasException('Metadata API answered HTTP ' + res.getStatusCode() + ': ' + body.left(500));
        }
        Dom.XmlNode soapBody = doc.getRootElement().getChildElement('Body', SOAP_NS);
        Dom.XmlNode fault = soapBody.getChildElement('Fault', SOAP_NS);
        if (fault != null) {
            String message = 'unknown error';
            for (Dom.XmlNode child : fault.getChildElements()) {
                if (child.getName() == 'faultstring') message = child.getText();
            }
            if (message.contains('INVALID_SESSION_ID')) message = 'Salesforce rejected your session. Reload the page and try again.';
            throw new RejectedException('Metadata API: ' + message);
        }
        result.node = soapBody.getChildElements()[0];
        return result;
    }

    public static String text(Dom.XmlNode node, String name) {
        Dom.XmlNode child = node.getChildElement(name, MD_NS);
        return child == null ? null : child.getText();
    }

    public static List<Dom.XmlNode> children(Dom.XmlNode node, String name) {
        List<Dom.XmlNode> found = new List<Dom.XmlNode>();
        if (node == null) return found;
        for (Dom.XmlNode child : node.getChildElements()) {
            if (child.getName() == name) found.add(child);
        }
        return found;
    }

    /** Flattens an element with simple children into a map of strings. */
    public static Map<String, Object> flat(Dom.XmlNode node) {
        Map<String, Object> values = new Map<String, Object>();
        for (Dom.XmlNode child : node.getChildElements()) {
            if (child.getChildElements().isEmpty()) values.put(child.getName(), child.getText());
        }
        return values;
    }

    public static String packageXml(List<Component> components) {
        Map<String, Set<String>> byType = new Map<String, Set<String>>();
        for (Component c : components) {
            if (!byType.containsKey(c.type)) byType.put(c.type, new Set<String>());
            byType.get(c.type).add(c.name);
        }
        List<String> types = new List<String>(byType.keySet());
        types.sort();
        String out = '';
        for (String type : types) {
            out += '<types>';
            List<String> members = new List<String>(byType.get(type));
            members.sort();
            for (String member : members) out += '<members>' + xml(member) + '</members>';
            out += '<name>' + xml(type) + '</name></types>';
        }
        return out;
    }

    public class Component {
        @AuraEnabled public String type;
        @AuraEnabled public String name;
        public Component() {}
        public Component(String type, String name) {
            this.type = type;
            this.name = name;
        }
    }

    /** Validates agent-supplied components ([{type, name}]). */
    public static List<Component> components(Object raw, Integer max) {
        List<Component> result = new List<Component>();
        if (!(raw instanceof List<Object>)) throw new AtlasException('components must be a list of {"type","name"}.');
        for (Object item : (List<Object>) raw) {
            Map<String, Object> value = item instanceof Map<String, Object> ? (Map<String, Object>) item : null;
            String type = value == null ? null : String.valueOf(value.get('type'));
            String name = value == null ? null : String.valueOf(value.get('name'));
            if (String.isBlank(type) || String.isBlank(name) || !Pattern.matches('[A-Za-z]{2,80}', type) || name.length() > 255) {
                throw new AtlasException('Each component needs a Metadata API "type" (for example ApexClass) and a "name".');
            }
            result.add(new Component(type, name));
        }
        if (result.isEmpty() || result.size() > max) throw new AtlasException('Send 1 to ' + max + ' components.');
        return result;
    }

    public static String startRetrieve(List<Component> components) {
        SoapResult res = metadata('retrieve',
            '<retrieveRequest><apiVersion>' + VERSION + '</apiVersion><singlePackage>true</singlePackage><unpackaged>'
            + packageXml(components) + '<version>' + VERSION + '</version></unpackaged></retrieveRequest>');
        return text(res.node.getChildElement('result', MD_NS), 'id');
    }

    public class Retrieved {
        public Boolean done;
        public String status;
        public String error;
        public Blob zip;
        public List<Map<String, Object>> properties = new List<Map<String, Object>>();
        public List<String> problems = new List<String>();
    }

    public static Retrieved checkRetrieve(String asyncId) {
        SoapResult res = metadata('checkRetrieveStatus',
            '<asyncProcessId>' + xml(asyncId) + '</asyncProcessId><includeZip>true</includeZip>');
        Dom.XmlNode result = res.node.getChildElement('result', MD_NS);
        Retrieved out = new Retrieved();
        out.done = text(result, 'done') == 'true';
        out.status = text(result, 'status');
        out.error = text(result, 'errorMessage');
        if (res.zipBase64 != null) out.zip = EncodingUtil.base64Decode(res.zipBase64);
        for (Dom.XmlNode file : children(result, 'fileProperties')) out.properties.add(flat(file));
        for (Dom.XmlNode message : children(result, 'messages')) {
            out.problems.add(text(message, 'fileName') + ': ' + text(message, 'problem'));
        }
        return out;
    }

    public class TextFile {
        @AuraEnabled public String path;
        @AuraEnabled public String text;
        @AuraEnabled public Integer size;
        @AuraEnabled public Boolean binary = false;
    }

    /** Reads every file of a Metadata API zip. Binary files and anything past maxChars are listed without content. */
    public static List<TextFile> unzip(Blob zip, Integer maxChars) {
        List<TextFile> files = new List<TextFile>();
        Integer used = 0;
        Compression.ZipReader reader = new Compression.ZipReader(zip);
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName().endsWith('/')) continue;
            Blob data = reader.extract(entry);
            TextFile file = new TextFile();
            file.path = entry.getName();
            file.size = data.size();
            try {
                file.text = data.toString();
            } catch (Exception notText) {
                file.binary = true;
            }
            if (file.text != null && used + file.text.length() > maxChars) file.text = null;
            if (file.text != null) used += file.text.length();
            files.add(file);
        }
        return files;
    }

    public static String startDeploy(Blob zip, String testLevel, List<String> tests) {
        String options = '<allowMissingFiles>false</allowMissingFiles><checkOnly>false</checkOnly>'
            + '<ignoreWarnings>false</ignoreWarnings><rollbackOnError>true</rollbackOnError>';
        if (testLevel == 'RunSpecifiedTests') {
            for (String test : tests) options += '<runTests>' + xml(test) + '</runTests>';
        }
        options += '<singlePackage>true</singlePackage>';
        if (String.isNotBlank(testLevel)) options += '<testLevel>' + xml(testLevel) + '</testLevel>';
        SoapResult res = metadata('deploy',
            '<ZipFile>' + EncodingUtil.base64Encode(zip) + '</ZipFile><DeployOptions>' + options + '</DeployOptions>');
        return text(res.node.getChildElement('result', MD_NS), 'id');
    }

    /** Deployment status with component errors and test failures, ready for JSON. */
    public static Map<String, Object> checkDeploy(String deployId) {
        SoapResult res = metadata('checkDeployStatus',
            '<asyncProcessId>' + xml(deployId) + '</asyncProcessId><includeDetails>true</includeDetails>');
        Dom.XmlNode result = res.node.getChildElement('result', MD_NS);
        if (result == null) throw new AtlasException('Metadata API returned no deployment status for ' + deployId + '. The outcome is still unknown.');
        Map<String, Object> out = flat(result);
        String returnedId = (String) out.get('id');
        // Setup accepts 15-character IDs; SOAP normally returns their 18-character form.
        if (returnedId != null && !returnedId.left(15).equals(deployId.left(15)))
            throw new AtlasException('Metadata API returned a different deployment ID. The requested deployment outcome is still unknown.');
        List<Object> componentErrors = new List<Object>();
        List<Object> componentWarnings = new List<Object>();
        List<Object> testFailures = new List<Object>();
        List<Object> coverageWarnings = new List<Object>();
        List<Object> coverageWarningDetails = new List<Object>();
        List<Object> flowCoverageWarnings = new List<Object>();
        Dom.XmlNode details = result.getChildElement('details', MD_NS);
        if (details != null) {
            for (Dom.XmlNode failure : children(details, 'componentFailures')) {
                Map<String, Object> f = componentMessage(failure);
                componentErrors.add(f);
                if (f.get('problemType') == 'Warning') componentWarnings.add(f);
            }
            for (Dom.XmlNode component : children(details, 'componentSuccesses')) {
                Map<String, Object> f = componentMessage(component);
                if (String.isNotBlank((String) f.get('problem'))) componentWarnings.add(f);
            }
            Dom.XmlNode tests = details.getChildElement('runTestResult', MD_NS);
            if (tests != null) {
                out.put('testsRun', text(tests, 'numTestsRun'));
                out.put('testSummary', flat(tests));
                for (Dom.XmlNode failure : children(tests, 'failures')) {
                    Map<String, Object> f = flat(failure);
                    f.put('test', String.valueOf(f.get('name') ?? '')
                        + (String.isBlank((String) f.get('methodName')) ? '' : '.' + f.get('methodName')));
                    testFailures.add(f);
                }
                for (Dom.XmlNode warning : children(tests, 'codeCoverageWarnings')) {
                    Map<String, Object> w = flat(warning);
                    coverageWarnings.add(String.valueOf(w.get('name') ?? '') + ': ' + w.get('message'));
                    coverageWarningDetails.add(w);
                }
                for (Dom.XmlNode warning : children(tests, 'flowCoverageWarnings')) flowCoverageWarnings.add(flat(warning));
            }
        }
        out.put('componentErrors', componentErrors);
        out.put('componentWarnings', componentWarnings);
        out.put('testFailures', testFailures);
        out.put('coverageWarnings', coverageWarnings);
        out.put('coverageWarningDetails', coverageWarningDetails);
        out.put('flowCoverageWarnings', flowCoverageWarnings);
        return out;
    }

    /** Keep Salesforce's original fields as well as the names used by Atlas clients. */
    static Map<String, Object> componentMessage(Dom.XmlNode node) {
        Map<String, Object> f = flat(node);
        f.put('type', f.get('componentType'));
        f.put('name', f.get('fullName'));
        f.put('file', f.get('fileName'));
        f.put('line', f.get('lineNumber'));
        f.put('column', f.get('columnNumber'));
        return f;
    }

    public static String sha256(Blob data) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', data));
    }
}
