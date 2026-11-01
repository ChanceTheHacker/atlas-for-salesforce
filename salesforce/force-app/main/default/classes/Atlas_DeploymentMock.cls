/** Exact Metadata API diagnostics and uncertain outcomes used by deployment tests. */
@IsTest
public class Atlas_DeploymentMock implements HttpCalloutMock {
    String mode;
    public Atlas_DeploymentMock(String mode) { this.mode = mode; }

    public HttpResponse respond(HttpRequest request) {
        if (mode == 'noCallouts') {
            System.assert(false, 'A saved outcome or stale worker must not call Salesforce again.');
        }
        String action = request.getHeader('SOAPAction');
        if (action == 'deploy' && mode == 'submissionUnknown') throw new CalloutException('Submission response lost');
        if (action == 'deploy' && mode == 'rejected') {
            HttpResponse fault = new HttpResponse();
            fault.setStatusCode(500);
            fault.setBody('<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><soapenv:Fault>'
                + '<faultcode>sf:INVALID_OPERATION</faultcode><faultstring>INVALID_OPERATION: testLevel of NoTestRun cannot be used in production organizations</faultstring>'
                + '</soapenv:Fault></soapenv:Body></soapenv:Envelope>');
            return fault;
        }
        HttpResponse response = new Atlas_Mock().respond(request);
        if (action == 'deploy' && mode == 'missingSubmissionId')
            response.setBody(response.getBody().replace('<id>0Af000000000001AAA</id>', ''));
        if (action != 'checkDeployStatus') return response;
        if (mode == 'calloutError') throw new CalloutException('Status service unavailable');
        String result = '<done>true</done><id>0Af000000000001AAA</id><status>Failed</status><success>false</success>' + details();
        if (mode == 'pending') result = '<done>false</done><id>0Af000000000001AAA</id><status>InProgress</status><success>false</success>';
        if (mode == 'unknown') result = '<done>true</done><id>0Af000000000001AAA</id><status>Unknown</status>';
        if (mode == 'wrongId') result = result.replace('0Af000000000001AAA', '0Af000000000099AAA');
        response.setBody('<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/" xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<env:Body><checkDeployStatusResponse>' + (mode == 'missing' ? '' : '<result>' + result + '</result>')
            + '</checkDeployStatusResponse></env:Body></env:Envelope>');
        return response;
    }

    public static String details() {
        return '<details>'
            + component('ApexClass', 'Foo', 'classes/Foo.cls', '2', '5', 'Unexpected token &lt; at line 2 &amp; column 5', 'Error', 'componentFailures')
            + component('Flow', 'Review', 'flows/Review.flow', '17', '9', 'Update_Account (Record Update): field Missing__c does not exist.', 'Error', 'componentFailures')
            + component('LightningComponentBundle', 'fooCmp', 'lwc/fooCmp/fooCmp.html', '4', '12', 'LWC1058: Invalid HTML syntax: unexpected-equals-sign-before-attribute-name', 'Error', 'componentFailures')
            + component('ApexClass', 'OldApi', 'classes/OldApi.cls', '8', '1', 'Deprecated API &amp; compatibility warning', 'Warning', 'componentSuccesses')
            + '<runTestResult><numTestsRun>1</numTestsRun><numFailures>1</numFailures><totalTime>42.5</totalTime>'
            + '<failures><id>01p000000000001AAA</id><name>FooTest</name><namespace>nstest</namespace><methodName>itWorks</methodName>'
            + '<message>System.AssertException: Expected &lt;2&gt; but got &amp;1\nSecond diagnostic line</message>'
            + '<stackTrace>Class.nstest.FooTest.itWorks: line 3, column 1\nClass.nstest.TestHelper.run: line 9, column 2</stackTrace><type>Class</type><time>42.5</time></failures>'
            + '<codeCoverageWarnings><id>01p000000000001AAA</id><name>Foo</name><namespace>nstest</namespace><message>Test coverage is 0% &amp; below 75%</message></codeCoverageWarnings>'
            + '<flowCoverageWarnings><flowName>Review</flowName><flowId>300000000000001AAA</flowId><message>Flow coverage is below the required threshold</message></flowCoverageWarnings>'
            + '</runTestResult></details>';
    }

    static String component(String type, String name, String file, String line, String column, String problem, String problemType, String element) {
        return '<' + element + '><componentType>' + type + '</componentType><fullName>' + name + '</fullName><fileName>' + file
            + '</fileName><lineNumber>' + line + '</lineNumber><columnNumber>' + column + '</columnNumber><problem>' + problem
            + '</problem><problemType>' + problemType + '</problemType><success>' + (element == 'componentSuccesses') + '</success></' + element + '>';
    }
}
