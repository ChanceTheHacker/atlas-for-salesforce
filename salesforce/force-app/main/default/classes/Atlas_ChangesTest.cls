@IsTest
private class Atlas_ChangesTest {
    static final String COMPONENTS = '[{"type":"ApexClass","name":"Foo"},{"type":"LightningComponentBundle","name":"fooCmp"},{"type":"ApexClass","name":"NewOne"},{"type":"StaticResource","name":"Logo"}]';

    /** What backupStatus records for the mock retrieve of COMPONENTS. */
    static final String MANIFEST = '{"retrieveId":"09S000000000001AAA","requested":' + COMPONENTS + ','
        + '"found":[{"type":"ApexClass","name":"Foo","file":"classes/Foo.cls"},{"type":"LightningComponentBundle","name":"fooCmp","file":"lwc/fooCmp"},'
        + '{"type":"StaticResource","name":"Logo","file":"staticresources/Logo.resource"}],'
        + '"missing":[{"type":"ApexClass","name":"NewOne"}],'
        + '"files":{"classes/Foo.cls":["ApexClass:Foo"],"classes/Foo.cls-meta.xml":["ApexClass:Foo"],"lwc/fooCmp/fooCmp.js":["LightningComponentBundle:fooCmp"],'
        + '"lwc/fooCmp/fooCmp.js-meta.xml":["LightningComponentBundle:fooCmp"],"staticresources/Logo.resource":["StaticResource:Logo"]},'
        + '"deployed":[],"problems":[]}';

    static final String PROPOSAL = '{"summary":"Make Foo return two","reasoning":"Two is better","tests":["FooTest"],"files":['
        + '{"path":"classes/Foo.cls","content":"public class Foo {\\n    public static Integer one() { return 2; }\\n}\\n","comments":[{"line":2,"text":"Returns two"}]},'
        + '{"path":"lwc/fooCmp/fooCmp.html","content":"<template></template>"},'
        + '{"path":"classes/NewOne.cls","type":"ApexClass","name":"NewOne","content":"public class NewOne {}"},'
        + '{"path":"classes/NewOne.cls-meta.xml","type":"ApexClass","name":"NewOne","content":"<ApexClass/>"}]}';

    @TestSetup
    static void setup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            insert new Atlas_Conversation__c(Name = 'Fix Foo', Mode__c = 'Source', Status__c = 'Open');
        }
    }

    static Id conversation() {
        return [SELECT Id FROM Atlas_Conversation__c LIMIT 1].Id;
    }

    /** A change whose backup already exists, created without callouts. */
    static Atlas_Change__c backedUp(String status) {
        Atlas_Change__c change = new Atlas_Change__c(Conversation__c = conversation(), Status__c = status, Revision__c = 0,
            Components__c = MANIFEST, Summary__c = 'Fix Foo');
        insert change;
        ContentVersion version = new ContentVersion(Title = 'backup', PathOnClient = 'backup.zip', VersionData = Atlas_Mock.backupZip(),
            FirstPublishLocationId = change.Id);
        insert version;
        change.Backup_File__c = version.Id;
        change.Backup_Sha256__c = Atlas_Api.sha256(version.VersionData);
        update change;
        return change;
    }

    static Map<String, Object> parse(String value) {
        return (Map<String, Object>) JSON.deserializeUntyped(value);
    }

    /** A deployed change of the given components, recorded as one version step each. */
    static Atlas_Change__c deployedChange(String summary, List<String> deployed, Datetime at) {
        Atlas_Change__c change = backedUp('Deployed');
        update new Atlas_Change__c(Id = change.Id, Summary__c = summary, Decided_At__c = at,
            Components__c = MANIFEST.replace('"deployed":[]', '"deployed":' + JSON.serialize(deployed)));
        change = Atlas_Changes.load(change.Id);
        Atlas_Versions.record(change, Atlas_Changes.manifest(change), 'Change', at, true);
        return change;
    }

    /** A restore of keys from source, as startRestore leaves it; saved: its own backup is done. */
    static Atlas_Change__c restoreChange(Atlas_Change__c source, List<String> keys, Boolean saved) {
        Atlas_Change__c restore = backedUp('Restoring');
        Atlas_Changes.Manifest m = Atlas_Changes.manifest(restore);
        m.restoreFrom = source.Id;
        m.restoreKeys = keys;
        m.deployed = keys;
        m.restoreSha = source.Backup_Sha256__c;
        m.versionLabel = 'Restored to v1';
        update new Atlas_Change__c(Id = restore.Id, Components__c = JSON.serialize(m), Revision__c = 1, Summary__c = 'Restore ApexClass Foo to v1 (Original)',
            Backup_File__c = saved ? restore.Backup_File__c : null, Backup_Sha256__c = saved ? restore.Backup_Sha256__c : null,
            Result__c = '{"operation":"restore","status":"' + (saved ? 'Queued' : 'Backing up the current version') + '","done":"false"}');
        return Atlas_Changes.load(restore.Id);
    }

    /** What the restore confirmation pins: the backup and each component's newest version. */
    static String reviewed(Id sourceId) {
        Map<String, Object> plan = parse(Atlas_Changes.restorePlan(sourceId, null));
        Map<String, Object> source = (Map<String, Object>) plan.get('source');
        Map<String, Object> latest = new Map<String, Object>();
        for (Object item : (List<Object>) plan.get('components')) latest.put((String) ((Map<String, Object>) item).get('key'), ((Map<String, Object>) item).get('latestId'));
        return JSON.serialize(new Map<String, Object>{ 'revision' => source.get('revision'), 'backupSha256' => source.get('backupSha256'), 'latest' => latest });
    }

    static String lastHandoff(Id conversationId) {
        return Atlas_Data.getMessage([SELECT Id FROM Atlas_Message__c WHERE Conversation__c = :conversationId AND Kind__c = 'deploy' ORDER BY CreatedDate DESC, Id DESC LIMIT 1].Id);
    }

    static List<String> activeFlowXml() {
        String ns = 'http://soap.sforce.com/2006/04/metadata';
        return new List<String>{
            '<md:Flow xmlns:md="' + ns + '"><md:status>Active</md:status></md:Flow>',
            '<Flow xmlns="' + ns + '"><status source="review"><![CDATA[Active]]></status></Flow>',
            '<Flow xmlns="' + ns + '"><status>Ac<![CDATA[ti]]>ve</status></Flow>',
            '<Flow xmlns="' + ns + '"><status>&#65;ctive</status></Flow>',
            '<Flow xmlns="' + ns + '"><status>&#x41;ctive</status></Flow>',
            '<Flow xmlns="' + ns + '"><status>\n    Active\n</status></Flow>',
            '<md:FlowDefinition xmlns:md="' + ns + '"><md:activeVersionNumber> 002 </md:activeVersionNumber></md:FlowDefinition>',
            '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber><![CDATA[002]]></activeVersionNumber></FlowDefinition>',
            '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber>&#50;</activeVersionNumber></FlowDefinition>',
            '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber>&#x32;</activeVersionNumber></FlowDefinition>',
            // Values that are not a plain number still ask for confirmation instead of failing.
            '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber>latest</activeVersionNumber></FlowDefinition>',
            '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber>99999999999</activeVersionNumber></FlowDefinition>'
        };
    }

    @IsTest
    static void fullChangeActivationFlagUsesTheApprovalDomParser() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<String> active = activeFlowXml();
            Atlas_Change__c change = backedUp('Proposed');
            Integer revision = 0;
            for (String xml : active) {
                revision++;
                ContentVersion file = new ContentVersion(Title = 'Atlas activation proposal', PathOnClient = 'proposal.json', FirstPublishLocationId = change.Id,
                    VersionData = Blob.valueOf(JSON.serialize(new Map<String,Object>{'files' => new List<Object>{
                        new Map<String,Object>{'path' => xml.contains('FlowDefinition') ? 'flowDefinitions/Review.flowDefinition' : 'flows/Review.flow', 'content' => xml}
                    }})));
                insert file;
                update new Atlas_Change__c(Id = change.Id, Proposal_File__c = file.Id, Revision__c = revision);
                System.assertEquals(true, parse(Atlas_Changes.getChange(change.Id)).get('activatesFlow'), xml);
                try {
                    Atlas_Changes.decideConfirmed(change.Id, revision, true, null, 'Default', false);
                    System.assert(false, 'The same parser must still require explicit activation consent');
                } catch (AuraHandledException e) { System.assert(e.getMessage().contains('Explicitly confirm activation'), e.getMessage()); }
            }
            try {
                Atlas_Changes.decide(change.Id, revision, true, null, 'Default');
                System.assert(false, 'Ordinary approval must not activate a Flow');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('Explicitly confirm activation'), e.getMessage()); }
            System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
            System.assertEquals(0, Limits.getQueueableJobs(), 'Denied activation must not enqueue a deployment.');
        }
    }

    @IsTest
    static void inactiveActivationFlagsExcludeEscapedNestedAndForeignFields() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String ns = 'http://soap.sforce.com/2006/04/metadata';
            List<String> inactive = new List<String>{
                '<Flow xmlns="' + ns + '"><status>Draft</status><description>&lt;status&gt;Active&lt;/status&gt;</description></Flow>',
                '<Flow xmlns="' + ns + '"><description><![CDATA[<status>Active</status>]]></description></Flow>',
                '<FlowDefinition xmlns="' + ns + '"><activeVersionNumber>0</activeVersionNumber></FlowDefinition>',
                '<Flow xmlns="' + ns + '" xmlns:other="urn:other"><other:status>Active</other:status></Flow>',
                '<Flow xmlns="' + ns + '"><status xmlns="">Active</status></Flow>',
                '<Flow xmlns="' + ns + '"><status xmlns="http://soap.sforce.com/2006/04/Metadata">Active</status></Flow>',
                '<Flow xmlns="' + ns + '"><STATUS>Active</STATUS></Flow>',
                '<Flow xmlns="' + ns + '"><description><status>Active</status></description></Flow>',
                '<Flow xmlns="' + ns + '"><status><![CDATA[&#65;ctive]]></status></Flow>',
                '<Flow xmlns="' + ns + '"><status>&amp;#65;ctive</status></Flow>',
                '<Flow xmlns="' + ns + '"><status>Ac<![CDATA[&#116;]]>ive</status></Flow>',
                '<FlowDefinition xmlns="' + ns + '"><activeversionnumber>2</activeversionnumber></FlowDefinition>',
                '<FlowDefinition xmlns="' + ns + '" xmlns:other="urn:other"><other:activeVersionNumber>2</other:activeVersionNumber></FlowDefinition>'
            };
            Atlas_Change__c change = backedUp('Proposed');
            for (String xml : inactive) {
                ContentVersion file = new ContentVersion(Title = 'Atlas inactive proposal', PathOnClient = 'proposal.json', FirstPublishLocationId = change.Id,
                    VersionData = Blob.valueOf(JSON.serialize(new Map<String,Object>{'files' => new List<Object>{
                        new Map<String,Object>{'path' => xml.contains('FlowDefinition') ? 'flowDefinitions/Review.flowDefinition' : 'flows/Review.flow', 'content' => xml}
                    }})));
                insert file;
                update new Atlas_Change__c(Id = change.Id, Proposal_File__c = file.Id);
                System.assertEquals(false, parse(Atlas_Changes.getChange(change.Id)).get('activatesFlow'), xml);
            }
        }
    }

    @IsTest
    static void malformedOrNestedActivationMetadataFailsClosed() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String ns = 'http://soap.sforce.com/2006/04/metadata';
            Atlas_Change__c change = backedUp('Proposed');
            for (String xml : new List<String>{
                '<Flow xmlns="' + ns + '"><status>Active</status></Flow><broken',
                '<Flow xmlns="' + ns + '"><status>Draft</status></Flow><broken',
                '<Flow xmlns="' + ns + '"><status>Ac<part>ti</part>ve</status></Flow>'
            }) {
                ContentVersion file = new ContentVersion(Title = 'Atlas invalid activation proposal', PathOnClient = 'proposal.json', FirstPublishLocationId = change.Id,
                    VersionData = Blob.valueOf(JSON.serialize(new Map<String,Object>{'files' => new List<Object>{
                        new Map<String,Object>{'path' => 'flows/Review.flow', 'content' => xml}
                    }})));
                insert file;
                update new Atlas_Change__c(Id = change.Id, Proposal_File__c = file.Id);
                String parserError;
                try {
                    Atlas_Changes.getChange(change.Id);
                    System.assert(false, 'Invalid XML must not produce an activation flag: ' + xml);
                } catch (AuraHandledException e) { parserError = e.getMessage(); }
                System.assert(String.isNotBlank(parserError));
                try {
                    Atlas_Changes.decideConfirmed(change.Id, 0, true, null, 'Default', false);
                    System.assert(false, 'Invalid XML must not reach deployment approval: ' + xml);
                } catch (AuraHandledException e) { System.assertEquals(parserError, e.getMessage()); }
            }
            System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
            System.assertEquals(0, Limits.getQueueableJobs());
        }
    }

    @IsTest
    static void restoringCdataAndEntityActivationRequiresConfirmation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = new Atlas_Change__c(Status__c = 'Deployed', Revision__c = 1);
            insert change;
            for (String xml : activeFlowXml()) {
                Boolean definition = xml.contains('FlowDefinition');
                String type = definition ? 'FlowDefinition' : 'Flow';
                String path = definition ? 'flowDefinitions/Review.flowDefinition' : 'flows/Review.flow';
                Compression.ZipWriter writer = new Compression.ZipWriter();
                writer.addEntry(path, Blob.valueOf(xml));
                ContentVersion backup = new ContentVersion(Title = 'Atlas activation backup', PathOnClient = 'backup.zip',
                    VersionData = writer.getArchive(), FirstPublishLocationId = change.Id);
                insert backup;
                String backupHash = Atlas_Api.sha256(backup.VersionData);
                update new Atlas_Change__c(Id = change.Id, Backup_File__c = backup.Id, Backup_Sha256__c = backupHash,
                    Components__c = JSON.serialize(new Map<String,Object>{
                        'found' => new List<Object>{new Map<String,Object>{'type' => type, 'name' => 'Review', 'file' => path}},
                        'files' => new Map<String,Object>{path => new List<String>{type + ':Review'}},
                        'deployed' => new List<String>{type + ':Review'}
                    }));
                System.assertEquals(true, parse(Atlas_Changes.restorePlan(change.Id, null)).get('activatesFlow'), xml);
                String expected = JSON.serialize(new Map<String, Object>{ 'revision' => 1, 'backupSha256' => backupHash, 'latest' => new Map<String, Object>() });
                try {
                    Atlas_Changes.startRestore(change.Id, null, 'Default', false, expected);
                    System.assert(false, 'Restoring activation needs explicit consent: ' + xml);
                } catch (AuraHandledException e) { System.assert(e.getMessage().contains('The backup activates a Flow.'), e.getMessage()); }
            }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Change__c WHERE Status__c = 'Restoring']);
            System.assertEquals(0, Limits.getQueueableJobs(), 'Denied activation must not enqueue a restore.');
        }
    }

    @IsTest
    static void startsBackupForNewChange() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> started = parse(Atlas_Changes.startBackup(conversation(), null, 'Fix Foo', COMPONENTS));
            Test.stopTest();
            Map<String, Object> change = (Map<String, Object>) started.get('change');
            System.assertEquals('09S000000000001AAA', started.get('asyncId'));
            System.assertEquals('Backup Needed', change.get('status'));
            System.assertEquals(4, ((List<Object>) change.get('requested')).size());
        }
    }

    @IsTest
    static void backupsStoreOnlyTheRequestedTypePaths() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            // Callouts must precede the backup's database writes, so the unknown-type lookup runs first.
            Map<String, List<String>> paths = Atlas_Changes.typePaths(new List<Atlas_Api.Component>{
                new Atlas_Api.Component('CustomObject', 'Thing__c'), new Atlas_Api.Component('ApexClass', 'Foo')});
            System.assertEquals(1, Atlas_Mock.calls, 'An unknown type is looked up once.');
            Map<String, Object> started = parse(Atlas_Changes.startBackup(conversation(), null, 'Fix Foo', '[{"type":"ApexClass","name":"Foo"}]'));
            Test.stopTest();
            System.assertEquals(2, Atlas_Mock.calls, 'Known types must not ask Salesforce to describe every metadata type.');
            System.assertEquals(new Set<String>{'ApexClass', 'CustomObject'}, paths.keySet());
            System.assertEquals(new List<String>{'objects', ''}, paths.get('CustomObject'));
            Id changeId = (Id) ((Map<String, Object>) started.get('change')).get('id');
            Atlas_Changes.Manifest m = Atlas_Changes.manifest([SELECT Components__c FROM Atlas_Change__c WHERE Id = :changeId]);
            System.assertEquals(new Set<String>{'ApexClass'}, m.typePaths.keySet());
        }
    }

    @IsTest
    static void addsComponentsToAnExistingBackup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c existing = backedUp('Proposed');
            Atlas_Change__c deployed = backedUp('Deployed');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> started = parse(Atlas_Changes.startBackup(null, existing.Id, null, '[{"type":"ApexClass","name":"Bar"},{"type":"ApexClass","name":"Foo"}]'));
            Test.stopTest();
            System.assertEquals(5, ((List<Object>) ((Map<String, Object>) started.get('change')).get('requested')).size());
            try {
                Atlas_Changes.startBackup(null, deployed.Id, null, COMPONENTS);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Start a new change'), e.getMessage());
            }
        }
    }

    private class ApprovedDuringBackup implements HttpCalloutMock {
        Id changeId;
        ApprovedDuringBackup(Id changeId) { this.changeId = changeId; }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new Atlas_Mock().respond(request);
            if (request.getBody().contains('describeMetadata')) {
                update new Atlas_Change__c(Id = changeId, Status__c = 'Deploying');
            }
            return response;
        }
    }

    @IsTest
    static void aSlowBackupCannotOverwriteAnApproval() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Proposed');
            Test.setMock(HttpCalloutMock.class, new ApprovedDuringBackup(change.Id));
            Test.startTest();
            try {
                Atlas_Changes.startBackup(null, change.Id, 'Another backup', COMPONENTS);
                System.assert(false, 'The approval during the callout must win');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('changed'), e.getMessage());
            }
            Test.stopTest();
            System.assertEquals('Deploying', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
        }
    }

    @IsTest
    static void expandingABackupInvalidatesTheOldProposal() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            update new Atlas_Change__c(Id = change.Id, Status__c = 'Backup Needed');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA');
            Test.stopTest();
            System.assertEquals(null, [SELECT Proposal_File__c FROM Atlas_Change__c WHERE Id = :change.Id].Proposal_File__c,
                'An old proposal must never be compared against a refreshed backup');
        }
    }

    @IsTest
    static void backupsRejectAnUnrelatedRetrieveJob() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backup Needed');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            try {
                Atlas_Changes.backupStatus(change.Id, '09S000000000002AAA');
                System.assert(false, 'A retrieve job from another change cannot replace this backup');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('backup request'), e.getMessage());
            }
            Test.stopTest();
            System.assertEquals('Backup Needed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
        }
    }

    private class NamespacedRetrieve implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new Atlas_Mock().respond(request);
            if (request.getBody().contains('checkRetrieveStatus')) response.setBody(response.getBody()
                .replace('<fullName>Foo</fullName>', '<fullName>Foo</fullName><namespacePrefix>nstest</namespacePrefix>'));
            return response;
        }
    }

    @IsTest
    static void qualifiedBackupNamesMatchOnlyReportedNamespace() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = new Atlas_Change__c(Conversation__c=conversation(), Status__c='Backup Needed', Revision__c=0,
                Components__c='{"retrieveId":"09S000000000001AAA","requested":[{"type":"ApexClass","name":"nstest__Foo"},{"type":"ApexClass","name":"other__Foo"}]}');
            insert change;
            Test.setMock(HttpCalloutMock.class, new NamespacedRetrieve());
            Test.startTest();
            Map<String,Object> result = parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA'));
            Test.stopTest();
            Map<String,Object> dto = (Map<String,Object>)result.get('change');
            List<Object> missing = (List<Object>)dto.get('missing');
            System.assertEquals(1, missing.size());
            System.assertEquals('other__Foo', ((Map<String,Object>)missing[0]).get('name'));
            Map<String,Object> proposal = parse(Atlas_Changes.propose(change.Id,
                '{"files":[{"path":"classes/Foo.cls","content":"public class Foo {}"}]}'));
            System.assertEquals('Proposed', proposal.get('status'));
            try {
                Atlas_Changes.propose(change.Id, '{"files":[{"path":"classes/nstest__Foo.cls","type":"ApexClass","name":"nstest__Foo","content":"public class Foo {}"}]}');
                System.assert(false, 'Existing qualified component is not a new-component escape hatch');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('backup')); }
        }
    }

    @IsTest
    static void savesTheBackupWhenRetrieveFinishes() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = new Atlas_Change__c(Conversation__c = conversation(), Status__c = 'Backup Needed', Revision__c = 0,
                Components__c = '{"retrieveId":"09S000000000001AAA","requested":' + COMPONENTS + '}');
            insert change;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Mock.retrieveDone = false;
            System.assertEquals(false, parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA')).get('done'));
            Atlas_Mock.retrieveDone = true;
            Map<String, Object> result = parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA'));
            Test.stopTest();
            Map<String, Object> dto = (Map<String, Object>) result.get('change');
            System.assertEquals('Backed Up', dto.get('status'));
            System.assertEquals(6, ((List<Object>) result.get('files')).size());
            System.assertEquals(3, ((List<Object>) dto.get('found')).size());
            System.assertEquals(1, ((List<Object>) dto.get('missing')).size());
            System.assert(((String) dto.get('backupUrl')).startsWith('/sfc/servlet.shepherd/version/download/068'));
            Atlas_Change__c saved = [SELECT Backup_Sha256__c, Components__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals(Atlas_Api.sha256(Atlas_Mock.backupZip()).length(), saved.Backup_Sha256__c.length());
            System.assert(saved.Components__c.contains('"lwc/fooCmp/fooCmp.js":["LightningComponentBundle:fooCmp"]'), saved.Components__c);
        }
    }

    @IsTest
    static void secondPollDoesNotSaveTheBackupAgain() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> result = parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA'));
            Test.stopTest();
            System.assertEquals(true, result.get('done'));
            System.assertEquals(1, [SELECT COUNT() FROM ContentVersion WHERE FirstPublishLocationId = :change.Id]);
        }
    }

    @IsTest
    static void aDeclaredComponentCannotSmuggleAnUnbackedFile() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            try {
                Atlas_Changes.propose(change.Id, '{"files":[{"path":"classes/Unbacked.cls","type":"ApexClass","name":"NewOne","content":"public class Unbacked {}"}]}');
                System.assert(false, 'A declaration must not authorize an unrelated file');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('backup') || e.getMessage().contains('path'), e.getMessage());
            }
        }
    }

    @IsTest
    static void proposalsMustStayInsideTheBackup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Map<String, Object> proposed = parse(Atlas_Changes.propose(change.Id, PROPOSAL));
            System.assertEquals('Proposed', proposed.get('status'));
            System.assertEquals(1, proposed.get('revision'));
            System.assertEquals('Make Foo return two', proposed.get('summary'));
            Map<String, Object> before = (Map<String, Object>) proposed.get('before');
            System.assert(((String) before.get('classes/Foo.cls')).contains('return 1'));
            System.assert(!before.containsKey('classes/NewOne.cls'));

            Map<String, Object> revised = parse(Atlas_Changes.propose(change.Id,
                '{"files":[{"path":"staticresources/Logo.resource","content":"text"}]}'));
            System.assertEquals(2, revised.get('revision'));
            System.assertEquals('[binary file]', ((Map<String, Object>) revised.get('before')).get('staticresources/Logo.resource'));

            for (String bad : new List<String>{
                '{}', '{"files":[]}', '{"files":[{"path":"../evil","content":"x"}]}', '{"files":[{"path":"package.xml","content":"x"}]}',
                '{"files":[{"path":"classes/Foo.cls"}]}', '{"files":[{"path":"classes/Other.cls","content":"x"}]}',
                '{"files":[{"path":"classes/Foo.cls","content":"a"},{"path":"classes/Foo.cls","content":"b"}]}'
            }) {
                try {
                    Atlas_Changes.propose(change.Id, bad);
                    System.assert(false, 'Expected rejection of ' + bad);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().length() > 0);
                }
            }
            Atlas_Change__c waiting = backedUp('Backup Needed');
            try {
                Atlas_Changes.propose(waiting.Id, PROPOSAL);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('needs a backed-up change'));
            }
        }
    }

    @IsTest
    static void editsAreAppliedToTheBackedUpFile() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, '{"files":[{"path":"classes/Foo.cls","edits":['
                + '{"find":"return 1;","replace":"return 2;"},{"find":"public class Foo {\\n","replace":"public class Foo {\\n    // Two now\\n"}]}]}');
            Map<String, Object> proposal = (Map<String, Object>) parse(Atlas_Changes.getChange(change.Id)).get('proposal');
            Map<String, Object> file = (Map<String, Object>) ((List<Object>) proposal.get('files'))[0];
            System.assertEquals('public class Foo {\n    // Two now\n    public static Integer one() { return 2; }\n}\n', file.get('content'));
            System.assert(!file.containsKey('edits'));

            Map<String, String> bad = new Map<String, String>{
                '{"find":"return 3;","replace":"x"}' => 'not in the file',
                '{"find":"o","replace":"x"}' => 'more than once',
                '{"find":"","replace":"x"}' => 'needs "find"'
            };
            for (String edit : bad.keySet()) {
                try {
                    Atlas_Changes.propose(change.Id, '{"files":[{"path":"classes/Foo.cls","edits":[' + edit + ']}]}');
                    System.assert(false, 'Expected rejection of ' + edit);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains(bad.get(edit)), e.getMessage());
                }
            }
            for (String other : new List<String>{
                '{"files":[{"path":"classes/NewOne.cls","type":"ApexClass","name":"NewOne","edits":[{"find":"a","replace":"b"}]}]}',
                '{"files":[{"path":"classes/Foo.cls","content":"x","edits":[{"find":"a","replace":"b"}]}]}',
                '{"files":[{"path":"classes/Foo.cls","edits":"nope"}]}'
            }) {
                try {
                    Atlas_Changes.propose(change.Id, other);
                    System.assert(false, 'Expected rejection of ' + other);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains('classes/'), e.getMessage());
                }
            }
        }
    }

    @IsTest
    static void deployPackageHoldsBackupFilesOverlaidWithProposal() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.Manifest m = Atlas_Changes.manifest(change);
            Blob zip = Atlas_Changes.buildZip(
                [SELECT Id, Backup_File__c FROM Atlas_Change__c WHERE Id = :change.Id], m,
                new Set<String>{ 'ApexClass:Foo', 'LightningComponentBundle:fooCmp', 'ApexClass:NewOne' },
                new Map<String, Blob>{ 'classes/Foo.cls' => Blob.valueOf('changed'), 'classes/NewOne.cls' => Blob.valueOf('new'),
                    'classes/NewOne.cls-meta.xml' => Blob.valueOf('<ApexClass/>'), 'lwc/fooCmp/fooCmp.html' => Blob.valueOf('<template></template>') },
                new Map<String, List<String>>{ 'classes/Foo.cls' => new List<String>{ 'ApexClass:Foo' },
                    'classes/NewOne.cls' => new List<String>{ 'ApexClass:NewOne' }, 'classes/NewOne.cls-meta.xml' => new List<String>{ 'ApexClass:NewOne' },
                    'lwc/fooCmp/fooCmp.html' => new List<String>{ 'LightningComponentBundle:fooCmp' } });
            Compression.ZipReader reader = new Compression.ZipReader(zip);
            Set<String> paths = new Set<String>();
            for (Compression.ZipEntry entry : reader.getEntries()) paths.add(entry.getName());
            System.assertEquals(new Set<String>{ 'classes/Foo.cls', 'classes/Foo.cls-meta.xml', 'lwc/fooCmp/fooCmp.js', 'lwc/fooCmp/fooCmp.js-meta.xml',
                'lwc/fooCmp/fooCmp.html', 'classes/NewOne.cls', 'classes/NewOne.cls-meta.xml', 'package.xml' }, paths);
            System.assertEquals('changed', reader.extract(reader.getEntry('classes/Foo.cls')).toString());
            String packageXml = reader.extract(reader.getEntry('package.xml')).toString();
            System.assert(packageXml.contains('<members>Foo</members><members>NewOne</members><name>ApexClass</name>'), packageXml);
            System.assert(!packageXml.contains('Logo'));
        }
    }

    @IsTest
    static void rejectionKeepsTheNote() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            Map<String, Object> rejected = parse(Atlas_Changes.decide(change.Id, 1, false, 'Keep returning one', null));
            System.assertEquals('Rejected', rejected.get('status'));
            System.assertEquals('Keep returning one', rejected.get('decisionNote'));
            Atlas_Message__c handoff = [SELECT Body__c FROM Atlas_Message__c WHERE Conversation__c = :change.Conversation__c AND Kind__c = 'decision'];
            System.assert(handoff.Body__c.contains('I REJECTED'));
            System.assert(handoff.Body__c.contains('Keep returning one'));
            System.assert(handoff.Body__c.contains('"change":"' + rejected.get('name') + '"'));
            Map<String, Object> replay = parse(Atlas_Changes.decide(change.Id, 1, false, 'Keep returning one', null));
            System.assertEquals(rejected.get('decidedAt'), replay.get('decidedAt'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'decision'],
                'The rejection handoff commits without a browser and a lost-response retry cannot duplicate it.');
            try {
                Atlas_Changes.decide(change.Id, 1, true, null, null);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('changed since you opened it'));
            }
        }
    }

    @IsTest
    static void approvalStopsIfOrgSourceChangedAfterBackup() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock(true));
            Test.startTest();
            Atlas_Changes.decide(change.Id, 1, true, 'Reviewed', 'NoTestRun');
            Test.stopTest();
            Atlas_Change__c actual = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Failed', actual.Status__c, 'A newer org edit must block deployment');
            System.assertEquals(null, actual.Deploy_Id__c);
            System.assert(actual.Result__c.contains('changed'), actual.Result__c);
        }
    }

    @IsTest
    static void approvalStartsTheDeployment() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> approved = parse(Atlas_Changes.decide(change.Id, 1, true, 'Looks good', 'RunSpecifiedTests'));
            Test.stopTest();
            System.assertEquals('Deploying', approved.get('status'));
            System.assertEquals(null, approved.get('deployId'), 'The approval reserves a worker before making callouts');
            System.assertEquals('0Af000000000001AAA', [SELECT Deploy_Id__c FROM Atlas_Change__c WHERE Id = :change.Id].Deploy_Id__c);
            System.assertEquals('RunSpecifiedTests', approved.get('testLevel'));
            System.assertEquals(3, ((List<Object>) approved.get('deployed')).size());
        }
    }

    @IsTest
    static void specifiedTestsNeedTestsFromTheAgent() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL.replace('"tests":["FooTest"],', ''));
            try {
                Atlas_Changes.decide(change.Id, 1, true, null, 'RunSpecifiedTests');
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('listed no tests'));
            }
        }
    }

    @IsTest
    static void deploymentOutcomeIsSavedWithoutTheBrowser() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.deployStatus(change.Id);
            Test.stopTest();
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Conversation__c = :change.Conversation__c AND Kind__c = 'deploy'],
                'The result and agent handoff must commit together, even if the browser closes');
        }
    }

    @IsTest
    static void completionWorkerSavesExactFailuresAndAnIdempotentHandoff() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
            Test.startTest();
            System.enqueueJob(new Atlas_DeployCompletionJob(change.Id, '0Af000000000001AAA', 0));
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Failed', saved.Status__c);
            Map<String, Object> result = parse(saved.Result__c);
            System.assertEquals(3, ((List<Object>) result.get('componentErrors')).size());
            Atlas_Message__c message = [SELECT Id FROM Atlas_Message__c WHERE Conversation__c = :change.Conversation__c AND Kind__c = 'deploy'];
            String body = Atlas_Data.getMessage(message.Id);
            for (String expected : new List<String>{'classes/Foo.cls line 2:5', 'flows/Review.flow line 17:9', 'lwc/fooCmp/fooCmp.html line 4:12',
                'Second diagnostic line', 'Class.nstest.TestHelper.run: line 9, column 2', 'Deprecated API & compatibility warning', 'rollbackOnError=true'})
                System.assert(body.contains(expected), expected + ' must reach the agent: ' + body);
            System.assert(!body.contains('Nothing changed in Salesforce.'));
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Map<String, Object> cached = parse(Atlas_Changes.deployStatus(change.Id));
            Atlas_Changes.completeDeployment(change.Id, '0Af000000000001AAA', 1);
            System.assertEquals(true, cached.get('done'));
            System.assertEquals(false, cached.get('finished'));
            System.assertEquals(parse(saved.Result__c), (Map<String, Object>) cached.get('result'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void submittedDeploymentFinishesWithoutBrowserPolling() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            update new Atlas_Change__c(Id = change.Id, Status__c = 'Deploying', Test_Level__c = 'RunSpecifiedTests',
                Components__c = MANIFEST.replace('"deployed":[]', '"deployed":["ApexClass:Foo","LightningComponentBundle:fooCmp","ApexClass:NewOne"]'));
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            System.assertEquals(1, Limits.getQueueableJobs(), 'A known submission schedules completion before the browser can close.');
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('0Af000000000001AAA', saved.Deploy_Id__c);
            System.assertEquals('Failed', saved.Status__c);
            System.assertEquals(3, ((List<Object>) parse(saved.Result__c).get('componentErrors')).size());
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void reconciledUnknownRestoreAlsoTracksCompletionWithoutResubmission() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Result__c = '{"operation":"restore","before":"Restored","outcomeUnknown":true,"done":"true","success":"false"}');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
            Test.startTest();
            Atlas_Changes.reconcileDeployment(change.Id, '0Af000000000001AAA');
            System.assertEquals(1, Limits.getQueueableJobs());
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Restored', saved.Status__c);
            System.assertEquals('restore', parse(saved.Result__c).get('operation'));
            System.assertEquals('Restored', parse(saved.Result__c).get('before'));
            System.assertEquals('0Af000000000001AAA', saved.Deploy_Id__c);
        }
    }

    @IsTest
    static void successfulTerminalResultsAreServedWithoutCallouts() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            System.assertEquals(true, parse(Atlas_Changes.deployStatus(change.Id)).get('finished'));
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            System.assertEquals(true, parse(Atlas_Changes.deployStatus(change.Id)).get('done'));
            Test.stopTest();
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void boundedMonitoringPausesWithoutInventingFailureOrResubmitting() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA', Result__c = '{"operation":"restore","before":"Restored"}');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('pending'));
            Test.startTest();
            Atlas_Changes.completeDeployment(change.Id, '0Af000000000001AAA', 3);
            Atlas_Changes.completeDeployment(change.Id, '0Af000000000001AAA', 3);
            Atlas_Change__c paused = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Restoring', paused.Status__c);
            System.assertEquals('0Af000000000001AAA', paused.Deploy_Id__c);
            System.assertEquals('Restored', parse(paused.Result__c).get('before'));
            System.assertEquals(true, parse(paused.Result__c).get('trackingPaused'));
            System.assertEquals('false', parse(paused.Result__c).get('done'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
            System.assertEquals(0, Limits.getQueueableJobs());
            Test.stopTest();
        }
    }

    @IsTest
    static void laterRequestResumesPausedMonitoringAndCachesTheResult() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA',
                Result__c = '{"operation":"restore","before":"Restored","done":"false","trackingPaused":true}');
            Atlas_Data.addMessage(change.Conversation__c, 'To Agent', 'deploy', 'Monitoring paused');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
            Test.startTest();
            Map<String, Object> completed = parse(Atlas_Changes.deployStatus(change.Id));
            System.assertEquals('Restored', ((Map<String, Object>) completed.get('change')).get('status'));
            System.assertEquals('restore', ((Map<String, Object>) completed.get('result')).get('operation'));
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Map<String, Object> cached = parse(Atlas_Changes.deployStatus(change.Id));
            System.assertEquals('restore', ((Map<String, Object>) cached.get('result')).get('operation'));
            System.assertEquals(false, cached.get('finished'));
            Test.stopTest();
            System.assertEquals(2, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy'], 'One pause handoff and one terminal handoff.');
        }
    }

    @IsTest
    static void uncertainTerminalResponsesDoNotMarkADeploymentFailed() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('unknown'));
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            System.assertEquals(false, status.get('done'));
            System.assertEquals(true, ((Map<String, Object>) status.get('result')).get('resultUnknown'));
            Atlas_Changes.completeDeployment(change.Id, '0Af000000000001AAA', 3);
            Test.stopTest();
            System.assertEquals('Deploying', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void statusErrorsAtThePollBoundPreserveTheKnownDeployment() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('calloutError'));
            Test.startTest();
            Atlas_Changes.completeDeployment(change.Id, '0Af000000000001AAA', 3);
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Deploying', saved.Status__c);
            System.assertEquals('0Af000000000001AAA', saved.Deploy_Id__c);
            System.assertEquals(null, parse(saved.Result__c).get('outcomeUnknown'), 'Status errors are not submission uncertainty.');
            System.assert(((String) parse(saved.Result__c).get('trackingMessage')).contains('Status service unavailable'));
        }
    }

    @IsTest
    static void staleCompletionWorkersNeverPollOrFinishANewerRestore() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000002AAA', Result__c = '{"operation":"restore","before":"Deployed"}');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Test.startTest();
            System.enqueueJob(new Atlas_DeployCompletionJob(change.Id, '0Af000000000001AAA', 0));
            Test.stopTest();
            System.assertEquals('Restoring', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c);
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void aLostSubmissionResponseDoesNotAllowAnotherSubmission() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Result__c = '{"operation":"restore","before":"Deployed"}');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('submissionUnknown'));
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals('Restoring', ((Map<String, Object>) status.get('change')).get('status'));
            System.assertEquals(true, ((Map<String, Object>) status.get('result')).get('outcomeUnknown'));
            System.assertEquals('Deployed', ((Map<String, Object>) status.get('result')).get('before'));
            System.assertEquals(0, Limits.getQueueableJobs());
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void missingSubmissionIdIsUncertainRatherThanRetryable() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            update new Atlas_Change__c(Id = change.Id, Result__c = '{"operation":"restore","before":"Deployed"}');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('missingSubmissionId'));
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals(null, saved.Deploy_Id__c);
            System.assertEquals(true, parse(saved.Result__c).get('outcomeUnknown'));
            System.assertEquals(0, Limits.getQueueableJobs());
        }
    }

    @IsTest
    static void aQuickSourceCheckDeploysInTheSameJob() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            update new Atlas_Change__c(Id = change.Id, Status__c = 'Deploying', Test_Level__c = 'RunSpecifiedTests',
                Components__c = MANIFEST.replace('"deployed":[]', '"deployed":["ApexClass:Foo","LightningComponentBundle:fooCmp","ApexClass:NewOne"]'));
            Atlas_Mock.retrievePending = 2;
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('details'));
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            System.assertEquals(1, Limits.getQueueableJobs(), 'Only the completion job is queued; no delayed source-check job.');
            System.assertEquals('0Af000000000001AAA', [SELECT Deploy_Id__c FROM Atlas_Change__c WHERE Id = :change.Id].Deploy_Id__c,
                'The deploy starts as soon as the third status check reports the source check done.');
            Test.stopTest();
        }
    }

    @IsTest
    static void aSlowSourceCheckWaitsForTheNextJobWithoutDeploying() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            Atlas_Mock.retrieveDone = false;
            Atlas_Changes.retrieveChecks = 4;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, '09S000000000001AAA', 0);
            System.assertEquals(4, Atlas_Mock.calls, 'Every check is a status call, never a deploy.');
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Deploying', saved.Status__c);
            System.assertEquals(null, saved.Deploy_Id__c);
        }
    }

    @IsTest
    static void sourceCheckBudgetExhaustionNeverStartsADeployment() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            Atlas_Mock.retrieveDone = false;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.retrieveChecks = 3;
            Atlas_Changes.executeDeployment(change.Id, '09S000000000001AAA', 30);
            System.assertEquals(3, Atlas_Mock.calls, 'Only retrieve status calls are allowed.');
            System.assertEquals(0, Limits.getQueueableJobs());
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Failed', saved.Status__c);
            System.assertEquals(null, saved.Deploy_Id__c);
            System.assertEquals(false, parse(saved.Result__c).get('outcomeUnknown'));
            System.assert(saved.Result__c.contains('No deployment was started.'));
        }
    }

    @IsTest
    static void developerEditionChainBudgetReservesCompletionAndHonorsSmallerLimits() {
        System.assert(Atlas_DeployJob.fitsChain(1, 5, 2));
        System.assert(Atlas_DeployJob.fitsChain(3, 5, 2));
        System.assert(!Atlas_DeployJob.fitsChain(4, 5, 2));
        System.assert(Atlas_DeployJob.fitsChain(4, 5, 1));
        System.assert(!Atlas_DeployJob.fitsChain(5, 5, 1));
        System.assert(!Atlas_DeployJob.fitsChain(5, 100, 1));
        System.assert(!Atlas_DeployJob.fitsChain(2, 2, 1));
    }

    private class SupersededDeployment implements HttpCalloutMock {
        Id changeId;
        SupersededDeployment(Id changeId) { this.changeId = changeId; }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new Atlas_Mock().respond(request);
            update new Atlas_Change__c(Id = changeId, Status__c = 'Restoring',
                Deploy_Id__c = '0Af000000000002AAA', Result__c = '{"operation":"restore","before":"Deployed"}');
            return response;
        }
    }

    @IsTest
    static void anOldPollCannotFinishANewerRestore() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new SupersededDeployment(change.Id));
            Test.startTest();
            Map<String, Object> result = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals('Restoring', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :change.Id].Status__c,
                'The earlier deploy result must not complete the new restore');
            System.assertEquals(false, result.get('done'));
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    private class CompletedDuringPoll implements HttpCalloutMock {
        Id changeId;
        CompletedDuringPoll(Id changeId) { this.changeId = changeId; }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new Atlas_Mock().respond(request);
            update new Atlas_Change__c(Id = changeId, Status__c = 'Failed',
                Result__c = '{"id":"0Af000000000001AAA","operation":"deploy","done":"true","success":"false","errorMessage":"Other poll saved the exact failure"}');
            Atlas_Data.addMessage(conversation(), 'To Agent', 'deploy', 'Already recorded by the other poll');
            return response;
        }
    }

    @IsTest
    static void concurrentTerminalWriterWinsOverTheCalloutResponse() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Test.setMock(HttpCalloutMock.class, new CompletedDuringPoll(change.Id));
            Test.startTest();
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals(true, status.get('done'));
            System.assertEquals(false, status.get('finished'));
            System.assertEquals('false', ((Map<String, Object>) status.get('result')).get('success'));
            System.assertEquals('Other poll saved the exact failure', ((Map<String, Object>) status.get('result')).get('errorMessage'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    private class LargeDeploymentResult implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new Atlas_Mock().respond(request);
            response.setBody(response.getBody().replace('Unexpected token', 'x'.repeat(140000) + 'END-OF-ERROR'));
            return response;
        }
    }

    @IsTest
    static void largeDeploymentResultsRemainReadableAfterReload() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            update new Atlas_Change__c(Id = change.Id, Deploy_Id__c = '0Af000000000001AAA');
            Atlas_Mock.deploySuccess = false;
            Test.setMock(HttpCalloutMock.class, new LargeDeploymentResult());
            Test.startTest();
            Atlas_Changes.deployStatus(change.Id);
            Map<String, Object> reopened = parse(Atlas_Changes.getChange(change.Id));
            Map<String, Object> result = (Map<String, Object>) reopened.get('result');
            Map<String, Object> error = (Map<String, Object>) ((List<Object>) result.get('componentErrors'))[0];
            System.assert(((String) error.get('problem')).endsWith('END-OF-ERROR'));
            System.assertEquals(1, ((List<Object>) JSON.deserializeUntyped(Atlas_Changes.listChanges())).size());
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Map<String, Object> cached = parse(Atlas_Changes.deployStatus(change.Id));
            Map<String, Object> cachedResult = (Map<String, Object>) cached.get('result');
            Map<String, Object> cachedError = (Map<String, Object>) ((List<Object>) cachedResult.get('componentErrors'))[0];
            System.assertEquals(error.get('problem'), cachedError.get('problem'), 'Spilled terminal errors must hydrate without another Metadata API check.');
            System.assertEquals(true, cached.get('done'));
            System.assertEquals(false, cached.get('finished'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
            Test.stopTest();
        }
    }

    @IsTest
    static void recordsSuccessfulDeployments() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Deploying');
            change.Deploy_Id__c = '0Af000000000001AAA';
            update change;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals(true, status.get('done'));
            System.assertEquals(true, status.get('finished'));
            System.assertEquals('Deployed', ((Map<String, Object>) status.get('change')).get('status'));
            System.assertEquals('deploy', ((Map<String, Object>) status.get('result')).get('operation'));
        }
    }

    @IsTest
    static void reportsAFinishedDeploymentOnlyOnce() {
        System.runAs(Atlas_Mock.atlasUser()) {
            // Another screen already recorded this result, so this poll must not tell the agent again.
            Atlas_Change__c change = backedUp('Deployed');
            change.Deploy_Id__c = '0Af000000000001AAA';
            update change;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals(true, status.get('done'));
            System.assertEquals(false, status.get('finished'));
            System.assertEquals('Deployed', ((Map<String, Object>) status.get('change')).get('status'));
        }
    }

    @IsTest
    static void recordsFailedRestores() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Restoring');
            change.Deploy_Id__c = '0Af000000000001AAA';
            change.Result__c = '{"operation":"restore","before":"Restored"}';
            update change;
            Atlas_Mock.deploySuccess = false;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> status = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            Map<String, Object> dto = (Map<String, Object>) status.get('change');
            // A failed restore keeps the pre-restore label; this does not assert tests had no effects.
            System.assertEquals('Restored', dto.get('status'));
            System.assertEquals('restore', ((Map<String, Object>) dto.get('result')).get('operation'));
            System.assertEquals('false', ((Map<String, Object>) status.get('result')).get('success'));
            System.assertEquals(true, status.get('finished'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void repeatedFailedRestorePollPreservesTheOperation() {
        System.runAs(Atlas_Mock.atlasUser()) {
            // A later browser request starts after the first poll's transaction committed.
            Atlas_Change__c change = backedUp('Restored');
            change.Deploy_Id__c = '0Af000000000001AAA';
            change.Result__c = '{"id":"0Af000000000001AAA","operation":"restore","done":"true","success":"false"}';
            update change;
            Atlas_Data.addMessage(change.Conversation__c, 'To Agent', 'deploy', 'Restore failed');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Test.startTest();
            Map<String, Object> repeated = parse(Atlas_Changes.deployStatus(change.Id));
            Test.stopTest();
            System.assertEquals('Restored', ((Map<String, Object>) repeated.get('change')).get('status'));
            System.assertEquals('restore', ((Map<String, Object>) repeated.get('result')).get('operation'));
            System.assertEquals('false', ((Map<String, Object>) repeated.get('result')).get('success'));
            System.assertEquals(false, repeated.get('finished'));
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Message__c WHERE Kind__c = 'deploy']);
        }
    }

    @IsTest
    static void restorePlanShowsTheVersionsARestoreReplaces() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Datetime now = Datetime.now();
            Atlas_Change__c first = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, now.addDays(-2));
            Atlas_Change__c second = deployedChange('Make Foo return three', new List<String>{ 'ApexClass:Foo', 'LightningComponentBundle:fooCmp' }, now.addDays(-1));
            Map<String, Object> plan = parse(Atlas_Changes.restorePlan(first.Id, null));
            List<Object> components = (List<Object>) plan.get('components');
            System.assertEquals(1, components.size(), 'By default a restore puts back what the change deployed');
            Map<String, Object> foo = (Map<String, Object>) components[0];
            System.assertEquals('ApexClass:Foo', foo.get('key'));
            System.assertEquals(1, foo.get('restoreTo'));
            System.assertEquals('Original', foo.get('label'));
            System.assertEquals(3, foo.get('current'));
            System.assertEquals(2, ((List<Object>) foo.get('undone')).size(), 'Going back to the original replaces both later versions');
            System.assertEquals(false, plan.get('activatesFlow'));
            for (Object item : (List<Object>) parse(Atlas_Changes.restorePlan(second.Id, null)).get('components')) {
                Map<String, Object> c = (Map<String, Object>) item;
                if (c.get('key') != 'ApexClass:Foo') continue;
                System.assertEquals(2, c.get('restoreTo'));
                System.assertEquals('Make Foo return two', c.get('label'));
                System.assertEquals(1, ((List<Object>) c.get('undone')).size());
            }
            Atlas_Change__c onlyNew = deployedChange('Add NewOne', new List<String>{ 'ApexClass:NewOne' }, now);
            Atlas_Change__c proposed = backedUp('Proposed');
            Map<Id, String> refusals = new Map<Id, String>{ onlyNew.Id => 'Nothing to restore', proposed.Id => 'only finished changes can be restored' };
            for (Id sourceId : refusals.keySet()) {
                try {
                    Atlas_Changes.restorePlan(sourceId, null);
                    System.assert(false);
                } catch (AuraHandledException e) { System.assert(e.getMessage().contains(refusals.get(sourceId)), e.getMessage()); }
            }
            try {
                Atlas_Changes.restorePlan(first.Id, '[{"type":"ApexClass","name":"NewOne"}]');
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('is not in the backup of'), e.getMessage()); }
        }
    }

    @IsTest
    static void aRestoreIsANewChangeThatBacksUpTheCurrentVersionFirst() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            String expected = reviewed(source.Id);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> started = parse(Atlas_Changes.startRestore(source.Id, null, 'NoTestRun', false, expected));
            System.assertEquals('Restoring', started.get('status'));
            System.assertEquals('Restore ApexClass Foo to v1 (Original)', started.get('summary'));
            System.assertEquals('Restored to v1', Atlas_Changes.manifest(Atlas_Changes.load((Id) started.get('id'))).versionLabel);
            System.assertEquals(String.valueOf(source.Id), started.get('restoreFrom'));
            System.assertEquals(null, started.get('deployId'), 'Nothing is deployed before the current version is backed up');
            System.assertEquals(1, Limits.getQueueableJobs());
            try {
                Atlas_Changes.startRestore(source.Id, null, 'NoTestRun', false, expected);
                System.assert(false, 'A second restore of the same component must wait');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('is restoring ApexClass Foo right now'), e.getMessage()); }
            Test.stopTest();
            Atlas_Change__c restore = Atlas_Changes.load((Id) started.get('id'));
            System.assertNotEquals(null, restore.Backup_File__c, 'The current version is saved first, so the restore can be undone');
            System.assertEquals(null, restore.Deploy_Id__c);
            System.assertEquals('Restoring', restore.Status__c);
            System.assertEquals('Queued', parse(restore.Result__c).get('status'));
            System.assertEquals(source.Conversation__c, restore.Conversation__c);
            System.assert([SELECT Description FROM ContentVersion WHERE Id = :restore.Backup_File__c].Description.startsWith('Version before ' + restore.Name));
            Atlas_Change__c unchanged = Atlas_Changes.load(source.Id);
            System.assertEquals('Deployed', unchanged.Status__c, 'The source change is never modified');
            System.assertEquals(source.Backup_Sha256__c, unchanged.Backup_Sha256__c);
            try {
                Atlas_Changes.startBackup(conversation(), restore.Id, 'More', COMPONENTS);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('is a restore'), e.getMessage()); }
        }
    }

    @IsTest
    static void aRestoreDeploysTheChosenComponentsFromTheSourceBackupAndCanBeUndone() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two',
                new List<String>{ 'ApexClass:Foo', 'LightningComponentBundle:fooCmp' }, Datetime.now().addDays(-1));
            Atlas_Change__c restore = restoreChange(source, new List<String>{ 'ApexClass:Foo' }, true);
            Compression.ZipReader reader = new Compression.ZipReader(Atlas_Changes.buildZip(source, Atlas_Changes.manifest(source),
                new Set<String>{ 'ApexClass:Foo' }, new Map<String, Blob>(), new Map<String, List<String>>()));
            Set<String> paths = new Set<String>();
            for (Compression.ZipEntry entry : reader.getEntries()) paths.add(entry.getName());
            System.assertEquals(new Set<String>{ 'classes/Foo.cls', 'classes/Foo.cls-meta.xml', 'package.xml' }, paths);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.executeDeployment(restore.Id, null, 0);
            Test.stopTest();
            Atlas_Change__c done = Atlas_Changes.load(restore.Id);
            System.assertEquals('0Af000000000001AAA', done.Deploy_Id__c);
            System.assertEquals('Restored', done.Status__c);
            System.assertEquals('Deployed', Atlas_Changes.load(source.Id).Status__c);
            String body = lastHandoff(restore.Conversation__c);
            System.assert(body.startsWith('I RESTORED Restore ApexClass Foo to v1 (Original) (' + done.Name + ').'), body);
            System.assert(body.contains('Restoring does not delete components created later.'), body);
            System.assert(!body.contains('{"'), 'The agent gets a summary, not the raw result: ' + body);

            List<Object> versions = (List<Object>) parse(Atlas_Versions.componentHistory('ApexClass:Foo')).get('versions');
            System.assertEquals(3, versions.size());
            Map<String, Object> current = (Map<String, Object>) versions[0], before = (Map<String, Object>) versions[1];
            System.assertEquals(true, current.get('current'));
            System.assertEquals('Restore', current.get('kind'));
            System.assertEquals('Restored to v1', current.get('label'), 'Restoring to this version later reads "to v3 (Restored to v1)", not a nested summary');
            System.assertEquals(String.valueOf(restore.Id), before.get('sourceId'), 'Switching back restores the version this restore replaced');
            System.assertEquals(true, before.get('restorable'));
            System.assertEquals(2, ((List<Object>) parse(Atlas_Versions.componentHistory('LightningComponentBundle:fooCmp')).get('versions')).size(),
                'Components the restore did not touch keep their history');
        }
    }

    @IsTest
    static void aRestoreWhoseSourceBackupChangedDeploysNothing() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            Atlas_Change__c restore = restoreChange(source, new List<String>{ 'ApexClass:Foo' }, true);
            update new Atlas_Change__c(Id = source.Id, Backup_Sha256__c = 'replaced');
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('noCallouts'));
            Test.startTest();
            Atlas_Changes.executeDeployment(restore.Id, null, 0);
            Test.stopTest();
            Atlas_Change__c failed = Atlas_Changes.load(restore.Id);
            System.assertEquals('Failed', failed.Status__c);
            System.assertEquals(null, failed.Deploy_Id__c);
            String body = lastHandoff(restore.Conversation__c);
            System.assert(body.startsWith('RESTORE FAILED for '), body);
            System.assert(body.contains('was removed or replaced') && body.contains('Nothing was restored.'), body);
        }
    }

    @IsTest
    static void aRestoreThatCannotBackUpTheCurrentVersionDeploysNothing() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            Atlas_Change__c restore = restoreChange(source, new List<String>{ 'ApexClass:Foo' }, false);
            Atlas_Mock.retrieveDone = false;
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.executeDeployment(restore.Id, '09S000000000001AAA', 3);
            Test.stopTest();
            Atlas_Change__c failed = Atlas_Changes.load(restore.Id);
            System.assertEquals('Failed', failed.Status__c);
            System.assertEquals(null, failed.Deploy_Id__c);
            System.assertEquals(null, failed.Backup_File__c);
            String body = lastHandoff(restore.Conversation__c);
            System.assert(body.contains('did not finish backing up the current version') && body.contains('Nothing was restored.'), body);
        }
    }

    @IsTest
    static void aRestoreConfirmationIsBoundToTheReviewedBackupAndVersions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-2));
            String expected = reviewed(source.Id);
            Map<String, String> stale = new Map<String, String>{ 'none' => 'requires a reviewed restore plan', '{}' => 'requires a reviewed restore plan' };
            for (String json : stale.keySet()) {
                try {
                    Atlas_Changes.startRestore(source.Id, null, 'Default', true, json == 'none' ? null : json);
                    System.assert(false);
                } catch (AuraHandledException e) { System.assert(e.getMessage().contains(stale.get(json)), e.getMessage()); }
            }
            deployedChange('Make Foo return three', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            try {
                Atlas_Changes.startRestore(source.Id, null, 'Default', true, expected);
                System.assert(false, 'A version nobody reviewed must not be replaced');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('ApexClass Foo has a newer version since you opened the restore confirmation'), e.getMessage()); }
            expected = reviewed(source.Id);
            update new Atlas_Change__c(Id = source.Id, Revision__c = 5);
            try {
                Atlas_Changes.startRestore(source.Id, null, 'Default', true, expected);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('changed since you opened the restore confirmation'), e.getMessage()); }
            update new Atlas_Change__c(Id = source.Id, Backup_File__c = null);
            try {
                Atlas_Changes.startRestore(source.Id, null, 'Default', true, expected);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('was removed to free storage'), e.getMessage()); }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Change__c WHERE Status__c = 'Restoring']);
            System.assertEquals(0, Limits.getQueueableJobs(), 'A stale confirmation must not start anything');
        }
    }

    @IsTest
    static void oneComponentIsNeverDeployedAndRestoredAtOnce() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            String expected = reviewed(source.Id);
            Atlas_Change__c running = backedUp('Deploying');
            update new Atlas_Change__c(Id = running.Id, Components__c = MANIFEST.replace('"deployed":[]', '"deployed":["ApexClass:Foo"]'));
            try {
                Atlas_Changes.startRestore(source.Id, null, 'Default', false, expected);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('is deploying ApexClass Foo right now'), e.getMessage()); }
            update new Atlas_Change__c(Id = running.Id, Status__c = 'Restoring');
            Atlas_Change__c proposed = backedUp('Backed Up');
            Atlas_Changes.propose(proposed.Id, PROPOSAL);
            try {
                Atlas_Changes.decide(proposed.Id, 1, true, null, 'NoTestRun');
                System.assert(false, 'An approval waits for a running restore of the same component');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('is restoring ApexClass Foo right now'), e.getMessage()); }
            System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :proposed.Id].Status__c);
            System.assertEquals(0, Limits.getQueueableJobs());
        }
    }

    @IsTest
    static void approvalsAndRestoresReserveComponentsUnderOneSharedLock() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c first = backedUp('Backed Up');
            Atlas_Changes.propose(first.Id, PROPOSAL);
            Atlas_Change__c second = backedUp('Backed Up');
            Atlas_Changes.propose(second.Id, PROPOSAL);
            Atlas_Changes.decide(first.Id, 1, true, null, 'NoTestRun');
            try {
                Atlas_Changes.decide(second.Id, 1, true, null, 'NoTestRun');
                System.assert(false, 'The second approval must see the reservation the first one committed');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains(' is deploying ') && e.getMessage().contains('right now'), e.getMessage()); }
            Atlas_Changes.lockDeployments();
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Setting__c WHERE Key__c = 'deploy-lock'], 'Every approval and restore queues on the same row');
            System.assertEquals('Proposed', [SELECT Status__c FROM Atlas_Change__c WHERE Id = :second.Id].Status__c);
        }
    }

    @IsTest
    static void aDeploymentSalesforceRefusesFailsInsteadOfStayingUnknown() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = backedUp('Backed Up');
            Atlas_Changes.propose(change.Id, PROPOSAL);
            update new Atlas_Change__c(Id = change.Id, Status__c = 'Deploying', Test_Level__c = 'NoTestRun',
                Components__c = MANIFEST.replace('"deployed":[]', '"deployed":["ApexClass:Foo","LightningComponentBundle:fooCmp","ApexClass:NewOne"]'));
            Test.setMock(HttpCalloutMock.class, new Atlas_DeploymentMock('rejected'));
            Test.startTest();
            Atlas_Changes.executeDeployment(change.Id, null, 0);
            Test.stopTest();
            Atlas_Change__c saved = [SELECT Status__c, Deploy_Id__c, Result__c FROM Atlas_Change__c WHERE Id = :change.Id];
            System.assertEquals('Failed', saved.Status__c, 'A SOAP fault means no deployment exists, so nothing is left to reconcile');
            System.assertEquals(null, saved.Deploy_Id__c);
            Map<String, Object> result = parse(saved.Result__c);
            System.assertEquals(false, result.get('outcomeUnknown'));
            System.assert(String.valueOf(result.get('errorMessage')).contains('NoTestRun cannot be used in production'), saved.Result__c);
            try {
                Atlas_Changes.checkNotBusy(new Set<String>{ 'ApexClass:Foo' }, null);
            } catch (Atlas_Api.AtlasException e) { System.assert(false, 'A refused deployment must not keep its components reserved: ' + e.getMessage()); }
        }
    }

    @IsTest
    static void aRestoreWhoseBackupCannotBeSavedFailsInsteadOfStayingRestoring() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = deployedChange('Make Foo return two', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-1));
            Atlas_Change__c restore = restoreChange(source, new List<String>{ 'ApexClass:Foo' }, false);
            Integer files = [SELECT COUNT() FROM ContentVersion WHERE FirstPublishLocationId = :restore.Id];
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            // A manifest too big to record stands in for any failure while saving the backup.
            Atlas_Changes.manifestChars = 10;
            Test.startTest();
            Atlas_Changes.executeDeployment(restore.Id, null, 0);
            Test.stopTest();
            Atlas_Change__c failed = Atlas_Changes.load(restore.Id);
            System.assertEquals('Failed', failed.Status__c);
            System.assertEquals(null, failed.Backup_File__c);
            System.assertEquals(null, failed.Deploy_Id__c);
            System.assertEquals(files, [SELECT COUNT() FROM ContentVersion WHERE FirstPublishLocationId = :restore.Id], 'The half-saved backup is rolled back');
            String body = lastHandoff(restore.Conversation__c);
            System.assert(body.contains('Could not save the backup of the current version') && body.contains('Back up fewer components per change'), body);
        }
    }

    @IsTest
    static void aManifestTooBigForItsFieldIsRefusedBeforeAnythingIsSaved() {
        Atlas_Changes.Manifest m = new Atlas_Changes.Manifest();
        System.assert(Atlas_Changes.manifestJson(m).startsWith('{'));
        Atlas_Changes.manifestChars = 10;
        try {
            Atlas_Changes.manifestJson(m);
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) { System.assert(e.getMessage().contains('Back up fewer components per change. Nothing was saved.'), e.getMessage()); }
    }

    @IsTest
    static void confirmedFlowActivationStartsTheRestore() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = new Atlas_Change__c(Status__c = 'Deployed', Revision__c = 1);
            insert change;
            Compression.ZipWriter writer = new Compression.ZipWriter();
            writer.addEntry('flows/Review.flow', Blob.valueOf(activeFlowXml()[0]));
            ContentVersion backup = new ContentVersion(Title = 'Atlas activation backup', PathOnClient = 'backup.zip',
                VersionData = writer.getArchive(), FirstPublishLocationId = change.Id);
            insert backup;
            update new Atlas_Change__c(Id = change.Id, Backup_File__c = backup.Id, Backup_Sha256__c = Atlas_Api.sha256(backup.VersionData),
                Components__c = JSON.serialize(new Map<String,Object>{
                    'found' => new List<Object>{new Map<String,Object>{'type' => 'Flow', 'name' => 'Review', 'file' => 'flows/Review.flow'}},
                    'files' => new Map<String,Object>{'flows/Review.flow' => new List<String>{'Flow:Review'}}, 'deployed' => new List<String>{'Flow:Review'}
                }));
            String expected = reviewed(change.Id);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String,Object> started = parse(Atlas_Changes.startRestore(change.Id, null, 'Default', true, expected));
            System.assertEquals('Restoring', started.get('status'));
            System.assertEquals('Restore Flow Review to v1 (Original)', started.get('summary'));
            System.assertEquals(1, Limits.getQueueableJobs());
            Test.stopTest();
        }
    }

    @IsTest
    static void agentHandoffsAreShortAndCapLongLists() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = Atlas_Changes.load(backedUp('Failed').Id);
            System.assertEquals(null, Atlas_Changes.handoff(change, null));
            List<Object> errors = new List<Object>();
            for (Integer i = 0; i < 60; i++) errors.add(new Map<String, Object>{ 'fileName' => 'classes/C' + i + '.cls', 'lineNumber' => '1', 'columnNumber' => '2', 'problem' => 'Broken ' + i });
            String failed = Atlas_Changes.handoff(change, new Map<String, Object>{ 'operation' => 'deploy', 'id' => '0Af000000000001AAA', 'done' => 'true',
                'success' => 'false', 'componentErrors' => errors });
            System.assert(failed.startsWith('DEPLOY FAILED for ' + change.Name + ' revision 0.'), failed);
            System.assert(failed.contains('- classes/C0.cls line 1:2: Broken 0'), failed);
            System.assert(failed.contains('…and 10 more.') && !failed.contains('Broken 55'), failed);
            System.assert(failed.contains('"change":"' + change.Name + '"'), failed);
            System.assert(failed.endsWith('Split larger replies into separate responses.'), failed);
            String deployed = Atlas_Changes.handoff(change, new Map<String, Object>{ 'operation' => 'deploy', 'done' => 'true', 'success' => 'true', 'testsRun' => '2' });
            System.assert(deployed.startsWith('I approved and DEPLOYED ' + change.Name + ' revision 0.\n2 Apex test(s) ran and passed.'), deployed);
            System.assert(Atlas_Changes.handoff(change, new Map<String, Object>{ 'operation' => 'deploy', 'done' => 'false', 'trackingPaused' => true,
                'trackingMessage' => 'Polling budget used.' }).contains('NOT YET CONFIRMED: Polling budget used.'));
            System.assert(Atlas_Changes.handoff(change, new Map<String, Object>{ 'operation' => 'deploy', 'outcomeUnknown' => true,
                'errorMessage' => 'Read timed out' }).contains('outcome is UNKNOWN: Read timed out'));
        }
    }

    // ------------------------------------------------ bundles and older manifests

    static final List<String> LIB_FILES = new List<String>{ 'lwc/fooLib/fooLib.js', 'lwc/fooLib/fooLib.js-meta.xml', 'lwc/fooLib/format.js', 'lwc/fooLib/history.js' };

    static Map<String, String> libFiles() {
        Map<String, String> out = new Map<String, String>();
        for (String path : LIB_FILES) out.put(path, Atlas_Mock.bundleFiles().get(path));
        return out;
    }

    /**
     * A manifest as releases before bundle recognition saved it (CHG-00046): each bundle
     * file is its own "component", a -meta.xml file belongs to its entry file, and the
     * requested bundle itself is listed as missing.
     */
    static String legacy(List<String> deployed) {
        List<Object> found = new List<Object>();
        Map<String, Object> files = new Map<String, Object>();
        for (String path : LIB_FILES) {
            files.put(path, new List<Object>{ 'LightningComponentBundle:' + path.substringAfter('lwc/').removeEnd('-meta.xml') });
            if (!path.endsWith('-meta.xml')) found.add(new Map<String, Object>{ 'type' => 'LightningComponentBundle', 'name' => path.substringAfter('lwc/'),
                'file' => path, 'modified' => '2026-10-16T06:20:33.000Z', 'modifiedBy' => 'Ann Admin' });
        }
        Object lib = new Map<String, Object>{ 'type' => 'LightningComponentBundle', 'name' => 'fooLib' };
        return JSON.serialize(new Map<String, Object>{ 'retrieveId' => '09S000000000001AAA', 'requested' => new List<Object>{ lib },
            'missing' => new List<Object>{ lib }, 'found' => found, 'files' => files, 'deployed' => deployed, 'problems' => new List<Object>() });
    }

    static Atlas_Changes.Manifest legacyManifest(List<String> deployed) {
        return Atlas_Changes.manifest(new Atlas_Change__c(Components__c = legacy(deployed)));
    }

    /** A change saved by an older release, with its backup of fooLib in Files. */
    static Atlas_Change__c legacyChange(String status, List<String> deployed) {
        Blob zip = Atlas_Mock.zipOf(libFiles());
        Atlas_Change__c change = new Atlas_Change__c(Conversation__c = conversation(), Status__c = status, Revision__c = 1,
            Components__c = legacy(deployed), Summary__c = 'Older release', Decided_At__c = Datetime.now().addDays(-1));
        insert change;
        ContentVersion version = new ContentVersion(Title = 'backup', PathOnClient = 'backup.zip', VersionData = zip, FirstPublishLocationId = change.Id);
        insert version;
        update new Atlas_Change__c(Id = change.Id, Backup_File__c = version.Id, Backup_Sha256__c = Atlas_Api.sha256(zip));
        return Atlas_Changes.load(change.Id);
    }

    static Map<String, Blob> blobs(Map<String, String> files) {
        Map<String, Blob> out = new Map<String, Blob>();
        for (String path : files.keySet()) out.put(path, Blob.valueOf(files.get(path)));
        return out;
    }

    @IsTest
    static void bundlesAreBackedUpByNameNotByFile() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            for (String name : new List<String>{ 'atlasLib/history.js', 'lwc/atlasLib', '1lib' }) {
                try {
                    Atlas_Changes.startBackup(conversation(), null, 'Fix', '[{"type":"LightningComponentBundle","name":"' + name + '"}]');
                    System.assert(false, 'Expected rejection of ' + name);
                } catch (AuraHandledException e) {
                    System.assert(e.getMessage().contains('is not a bundle name'), e.getMessage());
                }
            }
            System.assertEquals(0, [SELECT COUNT() FROM Atlas_Change__c]);
        }
    }

    @IsTest
    static void aRetrieveThatDoesNotMatchItsFoldersBlocksTheBundle() {
        Atlas_Changes.Manifest m = new Atlas_Changes.Manifest();
        m.requested = Atlas_Api.components(JSON.deserializeUntyped('[{"type":"LightningComponentBundle","name":"fooLib"},'
            + '{"type":"LightningComponentBundle","name":"fooWork"},{"type":"ApexClass","name":"Foo"}]'), 10);
        List<Map<String, Object>> properties = new List<Map<String, Object>>{
            // A file reported in another bundle's folder, and a folder whose letter case differs from the name.
            new Map<String, Object>{ 'type' => 'LightningComponentBundle', 'fullName' => 'fooLib/history.js', 'fileName' => 'lwc/fooWork/history.js' },
            new Map<String, Object>{ 'type' => 'LightningComponentBundle', 'fullName' => 'fooWork/fooWork.js', 'fileName' => 'lwc/FooWork/fooWork.js' },
            new Map<String, Object>{ 'type' => 'ApexClass', 'fullName' => 'Foo', 'fileName' => 'classes/Foo.cls' },
            new Map<String, Object>{ 'type' => 'ApexClass', 'fullName' => 'Bar', 'fileName' => 'classes/Bar.cls' }
        };
        List<String> blocked = Atlas_Changes.index(m, properties, new List<String>{ 'lwc/fooLib/fooLib.js', 'lwc/fooWork/history.js',
            'lwc/FooWork/fooWork.js', 'classes/Foo.cls', 'classes/Foo.cls-meta.xml', 'classes/Bar.cls', 'lwc/strayCmp/strayCmp.js', 'package.xml' });
        System.assertEquals(1, m.found.size(), JSON.serialize(m.found));
        System.assertEquals('Foo', m.found[0].name);
        System.assertEquals(0, m.missing.size(), 'Reported bundles are not missing, so they cannot be declared as new either');
        for (String path : new List<String>{ 'lwc/fooLib/fooLib.js', 'lwc/fooWork/history.js', 'lwc/FooWork/fooWork.js', 'classes/Bar.cls', 'lwc/strayCmp/strayCmp.js' })
            System.assertEquals(new List<String>(), m.files.get(path), path + ' must belong to nothing');
        System.assertEquals(new List<String>{ 'ApexClass:Foo' }, m.files.get('classes/Foo.cls-meta.xml'));
        String all = String.join(blocked, '\n');
        System.assert(all.contains('ApexClass Bar (not requested)'), all);
        System.assert(all.contains('LightningComponentBundle fooLib (Salesforce reported lwc/fooWork/history.js for fooLib/history.js)'), all);
        System.assert(all.contains('lwc/strayCmp (in the backup, but no requested component owns it)'), all);
        System.assertEquals(blocked, m.blocked);
        try {
            Atlas_Changes.preflight(m, new Set<String>{ 'LightningComponentBundle:fooLib' }, new Map<String, List<String>>{
                'lwc/fooLib/fooLib.js' => new List<String>{ 'LightningComponentBundle:fooLib' } });
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('LightningComponentBundle fooLib is not in the backup of this change.'), e.getMessage());
        }
    }

    @IsTest
    static void olderFileLevelBackupsAreBlockedUntilBackedUpAgain() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = legacyChange('Backed Up', new List<String>());
            Map<String, Object> dto = parse(Atlas_Changes.getChange(change.Id));
            System.assertEquals(true, dto.get('needsBackup'));
            try {
                Atlas_Changes.propose(change.Id, '{"files":[{"path":"lwc/fooLib/history.js","content":"x"}]}');
                System.assert(false, 'A file-level backup cannot take a proposal');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('older Atlas release') && e.getMessage().contains('Send atlas-backup'), e.getMessage());
            }
            // A proposal saved before the upgrade cannot be approved either, and nothing is reserved.
            ContentVersion proposal = new ContentVersion(Title = 'proposal', PathOnClient = 'proposal.json', FirstPublishLocationId = change.Id,
                VersionData = Blob.valueOf('{"files":[{"path":"lwc/fooLib/history.js","content":"x"}]}'));
            insert proposal;
            update new Atlas_Change__c(Id = change.Id, Status__c = 'Proposed', Proposal_File__c = proposal.Id);
            try {
                Atlas_Changes.decide(change.Id, 1, true, 'Reviewed', 'NoTestRun');
                System.assert(false, 'A file-level backup cannot be approved');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('older Atlas release'), e.getMessage());
            }
            Atlas_Change__c after = Atlas_Changes.load(change.Id);
            System.assertEquals('Proposed', after.Status__c);
            System.assertEquals(change.Components__c, after.Components__c, 'The stored record is kept as it was');
            System.assertEquals(0, Limits.getQueueableJobs());
        }
    }

    @IsTest
    static void backingUpAnOlderChangeAgainRecordsItByBundle() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c change = legacyChange('Backup Needed', new List<String>{ 'LightningComponentBundle:fooLib/history.js' });
            Atlas_Mock.retrieveZip = Atlas_Mock.zipOf(libFiles());
            Atlas_Mock.retrieveProperties = Atlas_Mock.bundleProperties(libFiles(), null);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Map<String, Object> dto = (Map<String, Object>) parse(Atlas_Changes.backupStatus(change.Id, '09S000000000001AAA')).get('change');
            Test.stopTest();
            System.assertEquals(false, dto.get('needsBackup'));
            System.assertEquals(new List<Object>(), dto.get('blocked'));
            Atlas_Changes.Manifest m = Atlas_Changes.manifest(Atlas_Changes.load(change.Id));
            System.assertEquals(1, m.found.size());
            System.assertEquals('lwc/fooLib', m.found[0].file);
            System.assertEquals(0, m.missing.size());
            System.assertEquals(new List<String>{ 'LightningComponentBundle:fooLib' }, m.deployed);
            for (String path : LIB_FILES) System.assertEquals(new List<String>{ 'LightningComponentBundle:fooLib' }, m.files.get(path), path);
            Map<String, Object> proposed = parse(Atlas_Changes.propose(change.Id, '{"files":[{"path":"lwc/fooLib/history.js","edits":[{"find":"[item]","replace":"[item, 5]"}]}]}'));
            System.assertEquals('Proposed', proposed.get('status'));
        }
    }

    @IsTest
    static void olderManifestsAreRebuiltByBundleOnlyWhenEveryFileHasOneOwner() {
        Atlas_Changes.Manifest old = legacyManifest(new List<String>{ 'LightningComponentBundle:fooLib/history.js', 'LightningComponentBundle:fooLib/format.js' });
        Atlas_Changes.Manifest m = Atlas_Changes.reconciled(old);
        System.assertEquals(1, m.found.size());
        System.assertEquals('fooLib', m.found[0].name);
        System.assertEquals('lwc/fooLib', m.found[0].file);
        System.assertEquals('2026-10-16T06:20:33.000Z', m.found[0].modified);
        System.assertEquals(0, m.missing.size());
        for (String path : LIB_FILES) System.assertEquals(new List<String>{ 'LightningComponentBundle:fooLib' }, m.files.get(path), path);
        System.assertEquals(new List<String>{ 'LightningComponentBundle:fooLib' }, m.deployed);
        System.assertEquals(new List<String>{ 'LightningComponentBundle:fooLib/history.js' }, old.files.get('lwc/fooLib/history.js'), 'The original is not modified');
        System.assert(Atlas_Changes.reconciled(Atlas_Changes.manifest(new Atlas_Change__c(Components__c = MANIFEST))) != null);

        // Anything that cannot be matched without guessing is refused.
        Atlas_Changes.Manifest stray = legacyManifest(new List<String>());
        stray.files.put('lwc/otherCmp/otherCmp.js', new List<String>());
        Atlas_Changes.Manifest unrequested = legacyManifest(new List<String>());
        Atlas_Changes.Found other = new Atlas_Changes.Found();
        other.type = 'LightningComponentBundle';
        other.name = 'otherCmp/otherCmp.js';
        other.file = 'lwc/otherCmp/otherCmp.js';
        unrequested.found.add(other);
        Atlas_Changes.Manifest elsewhere = legacyManifest(new List<String>());
        Atlas_Changes.Found moved = new Atlas_Changes.Found();
        moved.type = 'LightningComponentBundle';
        moved.name = 'fooLib/extra.js';
        moved.file = 'lwc/fooWork/extra.js';
        elsewhere.found.add(moved);
        Atlas_Changes.Manifest unknownDeploy = legacyManifest(new List<String>{ 'LightningComponentBundle:fooWork/fooWork.js' });
        Atlas_Changes.Manifest unknownRestore = legacyManifest(new List<String>());
        unknownRestore.restoreKeys = new List<String>{ 'ApexClass:Bar' };
        for (Atlas_Changes.Manifest bad : new List<Atlas_Changes.Manifest>{ stray, unrequested, elsewhere, unknownDeploy, unknownRestore })
            System.assertEquals(null, Atlas_Changes.reconciled(bad), JSON.serialize(bad));
    }

    @IsTest
    static void restoresFromOlderBackupsPutBackWholeBundles() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = legacyChange('Deployed', new List<String>{ 'LightningComponentBundle:fooLib/history.js' });
            Map<String, Object> plan = parse(Atlas_Changes.restorePlan(source.Id, null));
            List<Object> items = (List<Object>) plan.get('components');
            System.assertEquals(1, items.size(), JSON.serialize(items));
            System.assertEquals('LightningComponentBundle:fooLib', ((Map<String, Object>) items[0]).get('component'));
            List<Atlas_Version__c> steps = [SELECT Component__c, Has_Backup__c FROM Atlas_Version__c WHERE Change__c = :source.Id];
            System.assertEquals(1, steps.size(), 'History records the bundle once, not each file');
            System.assertEquals('LightningComponentBundle:fooLib', steps[0].Component__c);
            System.assertEquals(true, steps[0].Has_Backup__c);

            Blob zip = Atlas_Changes.buildZip(source, Atlas_Changes.restorableManifest(source),
                new Set<String>{ 'LightningComponentBundle:fooLib' }, new Map<String, Blob>(), new Map<String, List<String>>());
            Set<String> expected = new Set<String>(LIB_FILES);
            expected.add('package.xml');
            System.assertEquals(expected, Atlas_Mock.entries(zip).keySet());
            System.assertEquals(new Map<String, List<String>>{ 'LightningComponentBundle' => new List<String>{ 'fooLib' }, 'version' => new List<String>{ '67.0' } },
                Atlas_Mock.packageOf(zip));

            // A restore queued before the upgrade with a file-level key deploys its whole bundle.
            Atlas_Change__c restore = restoreChange(source, new List<String>{ 'LightningComponentBundle:fooLib/history.js' }, true);
            Test.setMock(HttpCalloutMock.class, new Atlas_Mock());
            Test.startTest();
            Atlas_Changes.executeDeployment(restore.Id, null, 0);
            Test.stopTest();
            System.assertEquals('0Af000000000001AAA', Atlas_Changes.load(restore.Id).Deploy_Id__c);
            System.assertEquals(expected, Atlas_Mock.entries(Atlas_Mock.deployedZip).keySet());
        }
    }

    @IsTest
    static void olderBackupsThatCannotBeMatchedAreNotRestored() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c source = legacyChange('Deployed', new List<String>());
            Atlas_Changes.Manifest m = legacyManifest(new List<String>());
            m.files.put('lwc/otherCmp/otherCmp.js', new List<String>());
            update new Atlas_Change__c(Id = source.Id, Components__c = JSON.serialize(m));
            try {
                Atlas_Changes.restorePlan(source.Id, null);
                System.assert(false);
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Nothing was restored. Restore from another change.'), e.getMessage());
            }
            System.assertEquals(false, [SELECT Has_Backup__c FROM Atlas_Version__c WHERE Change__c = :source.Id LIMIT 1].Has_Backup__c,
                'History keeps the step but does not offer a backup it cannot match');
            System.assertEquals(JSON.serialize(m), Atlas_Changes.load(source.Id).Components__c);
        }
    }

    @IsTest
    static void aDeploymentFromAnOlderReleaseStillHoldsItsBundle() {
        System.runAs(Atlas_Mock.atlasUser()) {
            legacyChange('Deploying', new List<String>{ 'LightningComponentBundle:fooLib/history.js' });
            try {
                Atlas_Changes.checkNotBusy(new Set<String>{ 'LightningComponentBundle:fooLib' }, null);
                System.assert(false);
            } catch (Atlas_Api.AtlasException e) {
                System.assert(e.getMessage().contains('is deploying'), e.getMessage());
            }
            Atlas_Changes.checkNotBusy(new Set<String>{ 'LightningComponentBundle:fooWork' }, null);
        }
    }

    @IsTest
    static void preflightListsEveryProblemBeforeAnythingIsSent() {
        Atlas_Changes.Manifest m = Atlas_Changes.manifest(new Atlas_Change__c(Components__c = MANIFEST));
        String failed = 'The deployment package failed its checks, so nothing was sent to Salesforce:';
        Map<String, List<String>> problems = new Map<String, List<String>>{
            'LightningComponentBundle fooCmp/fooCmp.js is not a valid component name: bundles deploy by bundle name, not by file.' => null,
            'ApexClass Bar is not in the backup of this change.' => null,
            'ApexClass Bar needs both classes/Bar.cls and Bar.cls-meta.xml.' => null,
            'lwc/fooWork/x.js is not inside the folder of LightningComponentBundle fooCmp (lwc/fooCmp).' => null
        };
        try {
            Atlas_Changes.preflight(m, new Set<String>{ 'LightningComponentBundle:fooCmp/fooCmp.js', 'ApexClass:Bar' }, new Map<String, List<String>>{
                'lwc/fooWork/x.js' => new List<String>{ 'LightningComponentBundle:fooCmp' }, 'classes/Bar.cls' => new List<String>{ 'ApexClass:Bar' } });
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().startsWith(failed), e.getMessage());
            for (String problem : problems.keySet()) System.assert(e.getMessage().contains(problem), problem + ' → ' + e.getMessage());
        }

        // A bundle that would lose its metadata file or its entry file, and a file sent twice in two cases.
        Atlas_Changes.Manifest incomplete = Atlas_Changes.manifest(new Atlas_Change__c(Components__c = MANIFEST));
        incomplete.files.remove('lwc/fooCmp/fooCmp.js-meta.xml');
        incomplete.files.remove('lwc/fooCmp/fooCmp.js');
        try {
            Atlas_Changes.preflight(incomplete, new Set<String>{ 'LightningComponentBundle:fooCmp' }, new Map<String, List<String>>{
                'lwc/fooCmp/helper.js' => new List<String>{ 'LightningComponentBundle:fooCmp' } });
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('lwc/fooCmp has no fooCmp.js-meta.xml.'), e.getMessage());
            System.assert(e.getMessage().contains('lwc/fooCmp has no fooCmp.js, .html or .css file.'), e.getMessage());
        }
        try {
            Atlas_Changes.preflight(m, new Set<String>{ 'LightningComponentBundle:fooCmp' }, new Map<String, List<String>>{
                'lwc/fooCmp/FooCmp.js' => new List<String>{ 'LightningComponentBundle:fooCmp' } });
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('appears more than once (letter case aside)'), e.getMessage());
        }

        // Aura bundles need an entry file with its -meta.xml.
        Atlas_Changes.Manifest aura = Atlas_Changes.manifest(new Atlas_Change__c(Components__c = '{"requested":[{"type":"AuraDefinitionBundle","name":"fooAura"}],'
            + '"found":[{"type":"AuraDefinitionBundle","name":"fooAura","file":"aura/fooAura"}],'
            + '"files":{"aura/fooAura/fooAuraController.js":["AuraDefinitionBundle:fooAura"]}}'));
        Set<String> touched = new Set<String>{ 'AuraDefinitionBundle:fooAura' };
        try {
            Atlas_Changes.preflight(aura, touched, new Map<String, List<String>>());
            System.assert(false);
        } catch (Atlas_Api.AtlasException e) {
            System.assert(e.getMessage().contains('aura/fooAura has no fooAura.cmp, .app, .evt, .intf or .tokens file with its -meta.xml.'), e.getMessage());
        }
        Atlas_Changes.Contents c = Atlas_Changes.preflight(aura, touched, new Map<String, List<String>>{
            'aura/fooAura/fooAura.cmp' => new List<String>{ 'AuraDefinitionBundle:fooAura' },
            'aura/fooAura/fooAura.cmp-meta.xml' => new List<String>{ 'AuraDefinitionBundle:fooAura' } });
        System.assertEquals(new List<String>{ 'aura/fooAura/fooAura.cmp', 'aura/fooAura/fooAura.cmp-meta.xml', 'aura/fooAura/fooAuraController.js' }, c.paths);
        System.assertEquals(touched, c.members);
    }

    @IsTest
    static void builtPackagesAreReadBackBeforeSending() {
        Atlas_Changes.Contents expected = new Atlas_Changes.Contents();
        expected.paths = new List<String>{ 'classes/Foo.cls', 'classes/Foo.cls-meta.xml' };
        expected.members = new Set<String>{ 'ApexClass:Foo' };
        String ns = 'http://soap.sforce.com/2006/04/metadata';
        Map<String, String> good = new Map<String, String>{ 'classes/Foo.cls' => 'x', 'classes/Foo.cls-meta.xml' => '<ApexClass/>',
            'package.xml' => '<Package xmlns="' + ns + '"><types><members>Foo</members><name>ApexClass</name></types><version>' + Atlas_Api.VERSION + '</version></Package>' };
        Compression.ZipWriter writer = new Compression.ZipWriter();
        for (String path : good.keySet()) writer.addEntry(path, Blob.valueOf(good.get(path)));
        Atlas_Changes.verifyArchive(writer.getArchive(), expected);

        Map<String, Map<String, String>> wrong = new Map<String, Map<String, String>>();
        Map<String, String> extra = good.clone();
        extra.put('lwc/fooCmp/fooCmp.js', 'x');
        wrong.put('The archive holds classes/Foo.cls, classes/Foo.cls-meta.xml, lwc/fooCmp/fooCmp.js instead of', extra);
        Map<String, String> lost = good.clone();
        lost.remove('classes/Foo.cls-meta.xml');
        wrong.put('The archive holds classes/Foo.cls instead of', lost);
        Map<String, String> members = good.clone();
        members.put('package.xml', good.get('package.xml').replace('<members>Foo</members>', '<members>Foo</members><members>Bar</members>'));
        wrong.put('package.xml lists', members);
        Map<String, String> version = good.clone();
        version.put('package.xml', good.get('package.xml').replace('<version>' + Atlas_Api.VERSION, '<version>60.0'));
        wrong.put('package.xml is for API version 60.0', version);
        Map<String, String> none = good.clone();
        none.remove('package.xml');
        wrong.put('The archive has no package.xml.', none);
        for (String problem : wrong.keySet()) {
            Compression.ZipWriter bad = new Compression.ZipWriter();
            for (String path : wrong.get(problem).keySet()) bad.addEntry(path, Blob.valueOf(wrong.get(problem).get(path)));
            try {
                Atlas_Changes.verifyArchive(bad.getArchive(), expected);
                System.assert(false, 'Expected ' + problem);
            } catch (Atlas_Api.AtlasException e) {
                System.assert(e.getMessage().startsWith('The built deployment package does not match its checks, so nothing was sent to Salesforce:'), e.getMessage());
                System.assert(e.getMessage().contains(problem), problem + ' → ' + e.getMessage());
            }
        }
    }
}
