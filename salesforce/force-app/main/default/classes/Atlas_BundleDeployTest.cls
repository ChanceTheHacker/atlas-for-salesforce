/**
 * Lightning component bundles through the whole change flow: backup, proposal, approval
 * and deployment. The mock retrieve reports bundles as a real one does, one entry per
 * bundle file and none for -meta.xml files, and every test reads back the package Atlas
 * actually sent: its files, their contents and its package.xml.
 */
@IsTest
private class Atlas_BundleDeployTest {
    static final String BUNDLES = '[{"type":"LightningComponentBundle","name":"fooLib"},{"type":"LightningComponentBundle","name":"fooStyles"},'
        + '{"type":"LightningComponentBundle","name":"fooWork"},{"type":"ApexClass","name":"Foo"}]';
    static final List<String> LIB = new List<String>{ 'lwc/fooLib/fooLib.js', 'lwc/fooLib/fooLib.js-meta.xml', 'lwc/fooLib/format.js', 'lwc/fooLib/history.js' };

    @TestSetup
    static void setup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            insert new Atlas_Conversation__c(Name = 'Bundles', Mode__c = 'Source', Status__c = 'Open');
        }
    }

    /** A change waiting for the retrieve of these components; extra: more files in the org's ZIP. */
    static Atlas_Change__c waiting(String components, Map<String, String> extra, String properties) {
        Atlas_Change__c change = new Atlas_Change__c(Conversation__c = [SELECT Id FROM Atlas_Conversation__c LIMIT 1].Id,
            Status__c = 'Backup Needed', Revision__c = 0, Summary__c = 'Bundles',
            Components__c = '{"retrieveId":"09S000000000001AAA","requested":' + components + '}');
        insert change;
        Map<String, String> files = Atlas_Mock.bundleFiles();
        files.putAll(extra);
        Atlas_Mock.retrieveZip = Atlas_Mock.zipOf(files);
        Atlas_Mock.retrieveProperties = properties ?? Atlas_Mock.bundleProperties(Atlas_Mock.bundleFiles(), null);
        return change;
    }

    static Map<String, Object> parse(String value) {
        return (Map<String, Object>) JSON.deserializeUntyped(value);
    }

    static Set<String> keys(Object components) {
        Set<String> out = new Set<String>();
        for (Object item : (List<Object>) components) {
            Map<String, Object> c = (Map<String, Object>) item;
            out.add(c.get('type') + ':' + c.get('name'));
        }
        return out;
    }

    static Integer revision(String changeJson) {
        return Integer.valueOf(parse(changeJson).get('revision'));
    }

    /** Backs up, proposes and approves; the deployment worker runs at Test.stopTest. */
    static Map<String, Object> deploy(Atlas_Change__c change, String files) {
        Map<String, Object> backup = (Map<String, Object>) parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA')).get('change');
        Integer proposed = revision(Atlas_Changes.propose(change.Id, '{"summary":"Bundle edit","tests":["FooTest"],"files":' + files + '}'));
        Atlas_Changes.decide(change.Id, proposed, true, 'Reviewed', 'NoTestRun');
        return backup;
    }

    static void assertDeployed(Id changeId) {
        Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :changeId];
        System.assertEquals('0Af000000000001AAA', saved.Deploy_Id__c, saved.Status__c + ': ' + saved.Result__c);
        System.assertNotEquals(null, Atlas_Mock.deployedZip, 'Nothing was sent to Salesforce');
    }

    @IsTest
    static void aOneFileEditDeploysTheWholeBundleWithoutResendingItsSiblings() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = waiting(BUNDLES, new Map<String, String>(), null);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> backup = deploy(change,
                '[{"path":"lwc/fooLib/history.js","edits":[{"find":"return [item];","replace":"return [item, item];"}]}]');
            Test.stopTest();

            // The backup lists each bundle once, by name, and nothing requested is missing.
            System.assertEquals(new Set<String>{ 'LightningComponentBundle:fooLib', 'LightningComponentBundle:fooStyles',
                'LightningComponentBundle:fooWork', 'ApexClass:Foo' }, keys(backup.get('found')), JSON.serialize(backup.get('found')));
            System.assertEquals(0, ((List<Object>) backup.get('missing')).size(), JSON.serialize(backup.get('missing')));
            assertDeployed(change.Id);
            System.assertEquals(new List<Object>{ 'LightningComponentBundle:fooLib' }, parse(Atlas_Changes.getChange(change.Id)).get('deployed'));

            Map<String, String> sent = Atlas_Mock.entries(Atlas_Mock.deployedZip);
            Map<String, String> original = Atlas_Mock.bundleFiles();
            List<String> paths = new List<String>(sent.keySet());
            paths.sort();
            List<String> expected = LIB.clone();
            expected.add('package.xml');
            expected.sort();
            System.assertEquals(expected, paths, 'The whole bundle and nothing else');
            System.assert(sent.get('lwc/fooLib/history.js').contains('return [item, item];'));
            for (String sibling : new List<String>{ 'lwc/fooLib/fooLib.js', 'lwc/fooLib/format.js', 'lwc/fooLib/fooLib.js-meta.xml' })
                System.assertEquals(original.get(sibling), sent.get(sibling), sibling + ' must come from the backup unchanged');
            Map<String, List<String>> xml = Atlas_Mock.packageOf(Atlas_Mock.deployedZip);
            System.assertEquals(new Map<String, List<String>>{ 'LightningComponentBundle' => new List<String>{ 'fooLib' },
                'version' => new List<String>{ '67.0' } }, xml);
        }
    }

    @IsTest
    static void threeBundlesAndApexDeployTogetherWithANewFileInAnExistingBundle() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = waiting(BUNDLES, new Map<String, String>(), null);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            deploy(change, '['
                + '{"path":"lwc/fooLib/history.js","content":"export function remember(item) {\\n    return [item, 2];\\n}\\n"},'
                + '{"path":"lwc/fooLib/format.js","edits":[{"find":"text.trim()","replace":"text.trim().toUpperCase()"}]},'
                + '{"path":"lwc/fooLib/extra.js","content":"export const EXTRA = 1;\\n"},'
                + '{"path":"lwc/fooStyles/fooStyles.css","content":".foo { color: inherit; margin: 0; }\\n"},'
                + '{"path":"lwc/fooWork/fooWork.html","content":"<template><p>Work done</p></template>\\n"},'
                + '{"path":"classes/Foo.cls","edits":[{"find":"return 1;","replace":"return 2;"}]}]');
            Test.stopTest();

            assertDeployed(change.Id);
            Map<String, String> sent = Atlas_Mock.entries(Atlas_Mock.deployedZip);
            Set<String> expected = new Set<String>(Atlas_Mock.bundleFiles().keySet());
            expected.addAll(new List<String>{ 'lwc/fooLib/extra.js', 'package.xml' });
            System.assertEquals(expected, sent.keySet());
            System.assertEquals('export const EXTRA = 1;\n', sent.get('lwc/fooLib/extra.js'));
            System.assert(sent.get('lwc/fooLib/format.js').contains('toUpperCase'));
            System.assert(sent.get('classes/Foo.cls').contains('return 2;'));
            System.assertEquals(Atlas_Mock.bundleFiles().get('lwc/fooWork/fooWork.js'), sent.get('lwc/fooWork/fooWork.js'));
            System.assertEquals(new Map<String, List<String>>{
                'ApexClass' => new List<String>{ 'Foo' },
                'LightningComponentBundle' => new List<String>{ 'fooLib', 'fooStyles', 'fooWork' },
                'version' => new List<String>{ '67.0' } }, Atlas_Mock.packageOf(Atlas_Mock.deployedZip));
        }
    }

    @IsTest
    static void aNewBundleDeploysOnlyItsOwnFiles() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = waiting(BUNDLES.removeEnd(']') + ',{"type":"LightningComponentBundle","name":"fooNew"}]', new Map<String, String>(), null);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> backup = deploy(change, '['
                + '{"path":"lwc/fooNew/fooNew.js","type":"LightningComponentBundle","name":"fooNew","content":"export default class FooNew {}\\n"},'
                + '{"path":"lwc/fooNew/fooNew.js-meta.xml","type":"LightningComponentBundle","name":"fooNew","content":"<LightningComponentBundle/>"}]');
            Test.stopTest();

            System.assertEquals(new Set<String>{ 'LightningComponentBundle:fooNew' }, keys(backup.get('missing')));
            assertDeployed(change.Id);
            System.assertEquals(new Set<String>{ 'lwc/fooNew/fooNew.js', 'lwc/fooNew/fooNew.js-meta.xml', 'package.xml' },
                Atlas_Mock.entries(Atlas_Mock.deployedZip).keySet());
            System.assertEquals(new List<String>{ 'fooNew' }, Atlas_Mock.packageOf(Atlas_Mock.deployedZip).get('LightningComponentBundle'));
        }
    }

    @IsTest
    static void namespacedBundlesMatchOnlyTheNamespaceSalesforceReported() {
        System.runAs(Atlas_Mock.atlasUser()) {
            // A qualified request comes back under its local name, with the namespace reported separately.
            Atlas_Change__c change = waiting('[{"type":"LightningComponentBundle","name":"nstest__fooLib"},{"type":"LightningComponentBundle","name":"other__fooStyles"}]',
                new Map<String, String>(), Atlas_Mock.bundleProperties(Atlas_Mock.bundleFiles(), 'nstest'));
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> backup = deploy(change, '[{"path":"lwc/fooLib/history.js","edits":[{"find":"[item]","replace":"[item, 3]"}]}]');
            Test.stopTest();

            System.assertEquals(new Set<String>{ 'LightningComponentBundle:fooLib' }, keys(backup.get('found')));
            System.assertEquals(new Set<String>{ 'LightningComponentBundle:other__fooStyles' }, keys(backup.get('missing')),
                'Another namespace is never stripped to match');
            assertDeployed(change.Id);
            System.assertEquals(new List<String>{ 'fooLib' }, Atlas_Mock.packageOf(Atlas_Mock.deployedZip).get('LightningComponentBundle'));
            Set<String> expected = new Set<String>(LIB);
            expected.add('package.xml');
            System.assertEquals(expected, Atlas_Mock.entries(Atlas_Mock.deployedZip).keySet());
        }
    }

    @IsTest
    static void proposalsCannotReachOutsideTheirBundles() {
        System.runAs(Atlas_Mock.atlasUser()) {
            // strayCmp is in the ZIP but Salesforce reported nothing for it; otherCmp was not requested.
            Map<String, String> extra = new Map<String, String>{
                'lwc/strayCmp/strayCmp.js' => 'export default class Stray {}\n', 'lwc/strayCmp/strayCmp.js-meta.xml' => '<LightningComponentBundle/>',
                'lwc/otherCmp/otherCmp.js' => 'export default class Other {}\n', 'lwc/otherCmp/otherCmp.js-meta.xml' => '<LightningComponentBundle/>'
            };
            Atlas_Change__c change = waiting(BUNDLES, extra, Atlas_Mock.bundleProperties(Atlas_Mock.bundleFiles(), null)
                + Atlas_Mock.property('LightningComponentBundle', 'otherCmp/otherCmp.js', 'lwc/otherCmp/otherCmp.js'));
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> backup = (Map<String, Object>) parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA')).get('change');
            Test.stopTest();
            System.assertEquals(4, keys(backup.get('found')).size(), JSON.serialize(backup.get('found')));
            Map<String, String> rejected = new Map<String, String>{
                '{"path":"lwc/strayCmp/strayCmp.js","content":"x"}' => 'not part of the backup',
                '{"path":"lwc/otherCmp/otherCmp.js","content":"x"}' => 'not part of the backup',
                '{"path":"lwc/otherCmp/otherCmp.js","type":"LightningComponentBundle","name":"fooLib","content":"x"}' => 'not part of the backup',
                '{"path":"lwc/fooLib/../fooWork/fooWork.js","content":"x"}' => 'Invalid file path',
                '{"path":"lwc/fooLib","content":"x"}' => 'Invalid file path',
                '{"path":"lwc/fooLib/","content":"x"}' => 'Invalid file path',
                '{"path":"lwc//fooLib/history.js","content":"x"}' => 'Invalid file path',
                '{"path":"/lwc/fooLib/history.js","content":"x"}' => 'Invalid file path',
                '{"path":"lwc/fooLib/./history.js","content":"x"}' => 'Invalid file path',
                '{"path":"lwc/fooLib/.","content":"x"}' => 'Invalid file path',
                '{"path":"lwc/fooLib/history.js","content":"x"},{"path":"lwc/fooLib/History.js","content":"y"}' => 'appears twice'
            };
            for (String files : rejected.keySet()) {
                try {
                    Atlas_Changes.propose(change.Id, '{"files":[' + files + ']}');
                    System.assert(false, 'Expected rejection of ' + files);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains(rejected.get(files)), files + ' → ' + e.getMessage());
                }
            }
        }
    }

    @IsTest
    static void aBundleEditedInSalesforceAfterTheBackupIsNotDeployed() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = waiting(BUNDLES, new Map<String, String>(), null);
            Atlas_Mock.changedPath = 'lwc/fooLib/format.js';
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock(true));
            Test.startTest();
            // The backup itself reads the unedited files; only the pre-deployment check sees the edit.
            Atlas_Mock.changedPath = null;
            Map<String, Object> backup = (Map<String, Object>) parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA')).get('change');
            Integer proposed = revision(Atlas_Changes.propose(change.Id, '{"files":[{"path":"lwc/fooLib/history.js","edits":[{"find":"[item]","replace":"[item, 4]"}]}]}'));
            Atlas_Mock.changedPath = 'lwc/fooLib/format.js';
            Atlas_Changes.decide(change.Id, proposed, true, 'Reviewed', 'NoTestRun');
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Failed', saved.Status__c);
            System.assertEquals(null, saved.Deploy_Id__c);
            System.assertEquals(null, Atlas_Mock.deployedZip);
            System.assert(saved.Result__c.contains('lwc/fooLib/format.js changed in Salesforce after the backup'), saved.Result__c);
        }
    }
}
