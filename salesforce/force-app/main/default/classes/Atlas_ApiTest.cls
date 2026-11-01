@IsTest
private class Atlas_ApiTest {
    @IsTest
    static void getReturnsBodyAndExplainsErrors() {
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        Test.startTest();
        System.assert(Atlas_Api.get(Atlas_Api.DATA + '/limits', null).contains('DailyApiRequests'));
        assertFails('/broken', 'NOT_FOUND: The requested resource does not exist');
        assertFails('/expired', 'rejected your session');
        assertFails('/plain-error', 'HTTP 500: Server exploded');
        assertFails('/timeout', 'longer than two minutes');
        Test.stopTest();
    }

    static void assertFails(String path, String expected) {
        try {
            Atlas_Api.get(path, new Map<String, String>{ 'X-Test' => '1' });
            System.assert(false, 'Expected a failure for ' + path);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains(expected), e.getMessage());
        }
    }

    @IsTest
    static void failKeepsAtlasMessagesAndNamesOtherErrors() {
        System.assertEquals('Plain words', Atlas_Api.fail(new Atlas_Api.AtlasException('Plain words')).getMessage());
        System.assert(Atlas_Api.fail(new DmlException('x')).getMessage().startsWith('System.DmlException'));
        AuraHandledException aura = new AuraHandledException('kept');
        System.assert(Atlas_Api.fail(aura) === aura);
    }

    @IsTest
    static void buildsPackageXmlAndValidatesComponents() {
        System.assertEquals('a&amp;b&lt;c&gt;&quot;&apos;', Atlas_Api.xml('a&b<c>"\''));
        System.assertEquals('', Atlas_Api.xml(null));
        List<Atlas_Api.Component> parts = Atlas_Api.components(
            JSON.deserializeUntyped('[{"type":"ApexClass","name":"B"},{"type":"ApexClass","name":"A"},{"type":"Layout","name":"Account-Account Layout"}]'), 5);
        System.assertEquals(
            '<types><members>A</members><members>B</members><name>ApexClass</name></types><types><members>Account-Account Layout</members><name>Layout</name></types>',
            Atlas_Api.packageXml(parts));
        for (String bad : new List<String>{ '{}', '[]', '[{"type":"Apex Class","name":"A"}]', '[{"name":"A"}]', '[{"type":"ApexClass","name":"A"},{"type":"ApexClass","name":"B"}]' }) {
            try {
                Atlas_Api.components(JSON.deserializeUntyped(bad), 1);
                System.assert(false, 'Expected rejection of ' + bad);
            } catch (Atlas_Api.AtlasException e) {
                System.assert(e.getMessage().length() > 0);
            }
        }
    }

    @IsTest
    static void retrievesAndReadsZip() {
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        Test.startTest();
        String asyncId = Atlas_Api.startRetrieve(new List<Atlas_Api.Component>{ new Atlas_Api.Component('ApexClass', 'Foo') });
        Atlas_Api.Retrieved result = Atlas_Api.checkRetrieve(asyncId);
        Test.stopTest();
        System.assertEquals('09S000000000001AAA', asyncId);
        System.assert(result.done);
        System.assertEquals(4, result.properties.size());
        System.assertEquals(1, result.problems.size());
        List<Atlas_Api.TextFile> files = Atlas_Api.unzip(result.zip, 1000000);
        Map<String, Atlas_Api.TextFile> byPath = new Map<String, Atlas_Api.TextFile>();
        for (Atlas_Api.TextFile f : files) byPath.put(f.path, f);
        System.assert(byPath.get('classes/Foo.cls').text.contains('public class Foo'));
        System.assert(byPath.get('staticresources/Logo.resource').binary);
        // Past the character budget files are listed without content.
        for (Atlas_Api.TextFile f : Atlas_Api.unzip(result.zip, 20)) {
            if (f.path == 'classes/Foo.cls') System.assertEquals(null, f.text);
        }
    }

    @IsTest
    static void deploysAndReportsFailures() {
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        Atlas_Mock.deploySuccess = false;
        Test.startTest();
        String deployId = Atlas_Api.startDeploy(Blob.valueOf('zip'), 'RunSpecifiedTests', new List<String>{ 'FooTest' });
        Map<String, Object> status = Atlas_Api.checkDeploy(deployId);
        Test.stopTest();
        System.assertEquals('false', status.get('success'));
        System.assertEquals(1, ((List<Object>) status.get('componentErrors')).size());
        System.assertEquals(1, ((List<Object>) status.get('testFailures')).size());
        System.assertEquals(1, ((List<Object>) status.get('coverageWarnings')).size());
        System.assertEquals('1', status.get('testsRun'));
    }

    @IsTest
    static void exactCompileFlowLwcAndTestDiagnosticsSurvive() {
        Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
        Test.startTest();
        Map<String, Object> status = Atlas_Api.checkDeploy('0Af000000000001AAA');
        System.assertEquals('0Af000000000001AAA', Atlas_Api.checkDeploy('0Af000000000001').get('id'), 'Setup may supply a 15-character ID for the same deployment.');
        Test.stopTest();
        List<Object> errors = (List<Object>) status.get('componentErrors');
        System.assertEquals(3, errors.size());
        Map<String, Object> compile = (Map<String, Object>) errors[0];
        System.assertEquals('Unexpected token < at line 2 & column 5', compile.get('problem'));
        System.assertEquals('classes/Foo.cls', compile.get('file'));
        System.assertEquals('classes/Foo.cls', compile.get('fileName'));
        System.assertEquals('2', compile.get('line'));
        System.assertEquals('5', compile.get('column'));
        System.assertEquals('Error', compile.get('problemType'));
        Map<String, Object> flow = (Map<String, Object>) errors[1];
        System.assertEquals('Flow', flow.get('type'));
        System.assertEquals('flows/Review.flow', flow.get('file'));
        System.assertEquals('17', flow.get('lineNumber'));
        System.assertEquals('Update_Account (Record Update): field Missing__c does not exist.', flow.get('problem'));
        Map<String, Object> lwc = (Map<String, Object>) errors[2];
        System.assertEquals('lwc/fooCmp/fooCmp.html', lwc.get('file'));
        System.assertEquals('12', lwc.get('columnNumber'));
        System.assertEquals('LWC1058: Invalid HTML syntax: unexpected-equals-sign-before-attribute-name', lwc.get('problem'));
        Map<String, Object> failure = (Map<String, Object>) ((List<Object>) status.get('testFailures'))[0];
        System.assertEquals('FooTest.itWorks', failure.get('test'));
        System.assertEquals('nstest', failure.get('namespace'));
        System.assertEquals('System.AssertException: Expected <2> but got &1\nSecond diagnostic line', failure.get('message'));
        System.assertEquals('Class.nstest.FooTest.itWorks: line 3, column 1\nClass.nstest.TestHelper.run: line 9, column 2', failure.get('stackTrace'));
        System.assertEquals('Deprecated API & compatibility warning', ((Map<String, Object>) ((List<Object>) status.get('componentWarnings'))[0]).get('problem'));
        System.assertEquals('Foo: Test coverage is 0% & below 75%', ((List<Object>) status.get('coverageWarnings'))[0]);
        System.assertEquals('nstest', ((Map<String, Object>) ((List<Object>) status.get('coverageWarningDetails'))[0]).get('namespace'));
        System.assertEquals('Review', ((Map<String, Object>) ((List<Object>) status.get('flowCoverageWarnings'))[0]).get('flowName'));
        System.assertEquals('42.5', ((Map<String, Object>) status.get('testSummary')).get('totalTime'));
    }

    @IsTest
    static void missingOrUnrelatedStatusResultsAreNotDeploymentFailures() {
        Test.startTest();
        for (String mode : new List<String>{'missing', 'wrongId'}) {
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock(mode));
            try {
                Atlas_Api.checkDeploy('0Af000000000001AAA');
                System.assert(false, 'Unrelated or absent results must never become a deployment failure.');
            } catch (Atlas_Api.AtlasException e) { System.assert(e.getMessage().contains('unknown'), e.getMessage()); }
        }
        Test.stopTest();
    }

    @IsTest
    static void reportsSoapFaults() {
        Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
        Test.startTest();
        try {
            Atlas_Api.metadata('nonsense', '');
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('Unknown operation nonsense'), e.getMessage());
        }
        try {
            Atlas_Api.metadata('garbage', '');
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('HTTP 500'), e.getMessage());
        }
        Test.stopTest();
        System.assertEquals(64, Atlas_Api.sha256(Blob.valueOf('x')).length());
    }
}
