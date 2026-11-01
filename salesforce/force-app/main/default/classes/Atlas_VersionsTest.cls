@IsTest
private class Atlas_VersionsTest {
    /** A backup of Foo and fooCmp; NewOne did not exist yet. */
    static final String MANIFEST = '{"requested":[],"found":[{"type":"ApexClass","name":"Foo","file":"classes/Foo.cls"},'
        + '{"type":"LightningComponentBundle","name":"fooCmp","file":"lwc/fooCmp"}],"missing":[{"type":"ApexClass","name":"NewOne"}],'
        + '"files":{"classes/Foo.cls":["ApexClass:Foo"],"classes/Foo.cls-meta.xml":["ApexClass:Foo"],"lwc/fooCmp/fooCmp.js":["LightningComponentBundle:fooCmp"]},'
        + '"deployed":[],"problems":[]}';

    static Map<String, Object> parse(String value) {
        return (Map<String, Object>) JSON.deserializeUntyped(value);
    }

    /** A finished change with a backup. deployed null leaves the list empty, as early releases did. */
    static Atlas_Change__c change(String status, String summary, List<String> deployed, Datetime at) {
        Atlas_Change__c change = new Atlas_Change__c(Status__c = status, Revision__c = 1, Summary__c = summary, Decided_At__c = at,
            Components__c = deployed == null ? MANIFEST : MANIFEST.replace('"deployed":[]', '"deployed":' + JSON.serialize(deployed)));
        insert change;
        ContentVersion backup = new ContentVersion(Title = 'backup', PathOnClient = 'backup.zip', VersionData = Atlas_Mock.backupZip(), FirstPublishLocationId = change.Id);
        insert backup;
        update new Atlas_Change__c(Id = change.Id, Backup_File__c = backup.Id, Backup_Sha256__c = Atlas_Api.sha256(backup.VersionData));
        return Atlas_Changes.load(change.Id);
    }

    static Atlas_Change__c deployed(String summary, List<String> keys, Datetime at) {
        Atlas_Change__c c = change('Deployed', summary, keys, at);
        Atlas_Versions.record(c, Atlas_Changes.manifest(c), 'Change', at, true);
        return c;
    }

    static List<Object> history(String component) {
        return (List<Object>) parse(Atlas_Versions.componentHistory(component)).get('versions');
    }

    @IsTest
    static void historyNumbersEachComponentsVersionsNewestFirst() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c a = deployed('Add NewOne', new List<String>{ 'ApexClass:Foo', 'ApexClass:NewOne' }, Datetime.now().addDays(-3));
            Atlas_Change__c b = deployed('Foo returns three', new List<String>{ 'ApexClass:Foo' }, Datetime.now().addDays(-2));

            Map<String, Map<String, Object>> index = new Map<String, Map<String, Object>>();
            for (Object item : (List<Object>) parse(Atlas_Versions.componentIndex()).get('components'))
                index.put((String) ((Map<String, Object>) item).get('key'), (Map<String, Object>) item);
            System.assertEquals(new Set<String>{ 'ApexClass:Foo', 'ApexClass:NewOne' }, index.keySet());
            System.assertEquals(3, index.get('ApexClass:Foo').get('versions'));
            System.assertEquals('Foo returns three', index.get('ApexClass:Foo').get('latest'));
            System.assertEquals(b.Name, index.get('ApexClass:Foo').get('change'));
            System.assertEquals(2, index.get('ApexClass:NewOne').get('versions'));

            List<Object> foo = history('ApexClass:Foo');
            System.assertEquals(3, foo.size());
            Map<String, Object> v3 = (Map<String, Object>) foo[0], v2 = (Map<String, Object>) foo[1], v1 = (Map<String, Object>) foo[2];
            System.assertEquals(3, v3.get('number'));
            System.assertEquals(true, v3.get('current'));
            System.assertEquals('Foo returns three', v3.get('label'));
            System.assertEquals(null, v3.get('sourceId'), 'The current version needs no restore');
            System.assertEquals('Add NewOne', v2.get('label'));
            System.assertEquals(String.valueOf(b.Id), v2.get('sourceId'), 'v2 is in the backup of the change that replaced it');
            System.assertEquals(true, v2.get('restorable'));
            System.assertEquals('Original', v1.get('label'));
            System.assertEquals(String.valueOf(a.Id), v1.get('sourceId'));
            System.assertEquals(true, v1.get('restorable'));

            List<Object> newOne = history('ApexClass:NewOne');
            System.assertEquals(2, newOne.size());
            Map<String, Object> original = (Map<String, Object>) newOne[1];
            System.assertEquals(false, original.get('restorable'));
            System.assertEquals('Did not exist before ' + a.Name, original.get('note'));

            System.assertEquals(1, history('ApexClass:Never').size(), 'A component Atlas never changed has only its current version');
        }
    }

    @IsTest
    static void keysMatchWithOrWithoutThisOrgsNamespace() {
        String ns = [SELECT NamespacePrefix FROM Organization LIMIT 1].NamespacePrefix;
        System.assertEquals('ApexClass:Foo', Atlas_Versions.componentKey('ApexClass:Foo'));
        System.assertEquals(null, Atlas_Versions.componentKey(null));
        if (ns == null) return;
        System.assertEquals('ApexClass:Foo', Atlas_Versions.componentKey('ApexClass:' + ns + '__Foo'));
        System.assertEquals('CustomField:Account.Score__c', Atlas_Versions.componentKey('CustomField:Account.' + ns.toUpperCase() + '__Score__c'));
        System.assertEquals('ApexClass:other__Foo', Atlas_Versions.componentKey('ApexClass:other__Foo'));
    }

    @IsTest
    static void changesFinishedBeforeHistoryGetTheirStepsOnce() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Change__c legacy = change('Deployed', 'Old deploy', null, Datetime.now().addDays(-5));
            Atlas_Change__c inPlace = change('Restored', 'Old restored deploy', null, Datetime.now().addDays(-4));
            Atlas_Change__c restore = change('Restored', 'Restore ApexClass Foo to v1 (Original)', new List<String>{ 'ApexClass:Foo' }, Datetime.now());
            Atlas_Changes.Manifest m = Atlas_Changes.manifest(restore);
            m.restoreFrom = legacy.Id;
            update new Atlas_Change__c(Id = restore.Id, Components__c = JSON.serialize(m));
            change('Failed', 'Never deployed', null, Datetime.now());

            Atlas_Versions.backfill();
            Atlas_Versions.backfill();
            Map<String, Integer> counts = new Map<String, Integer>();
            for (Atlas_Version__c row : [SELECT Change__c, Component__c, Kind__c, Has_Backup__c FROM Atlas_Version__c]) {
                String k = (row.Change__c == legacy.Id ? 'legacy' : row.Change__c == inPlace.Id ? 'inPlace' : row.Change__c == restore.Id ? 'restore' : 'other')
                    + ' ' + row.Kind__c + ' ' + row.Component__c + ' ' + row.Has_Backup__c;
                counts.put(k, (counts.get(k) ?? 0) + 1);
            }
            System.assertEquals(new Map<String, Integer>{
                // A legacy deployment sent everything requested; the new component had no backup.
                'legacy Change ApexClass:Foo true' => 1, 'legacy Change LightningComponentBundle:fooCmp true' => 1, 'legacy Change ApexClass:NewOne false' => 1,
                'inPlace Change ApexClass:Foo true' => 1, 'inPlace Change LightningComponentBundle:fooCmp true' => 1, 'inPlace Change ApexClass:NewOne false' => 1,
                // An in-place restore saved nothing first, so the version it replaced cannot be put back.
                'inPlace Restore ApexClass:Foo false' => 1, 'inPlace Restore LightningComponentBundle:fooCmp false' => 1,
                'restore Restore ApexClass:Foo true' => 1
            }, counts);
        }
    }

    @IsTest
    static void freeingStorageKeepsEachComponentsOriginalAndNewestRestorePoints() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Datetime old = Datetime.now().addDays(-100);
            Atlas_Change__c a = deployed('First', new List<String>{ 'ApexClass:Foo' }, old);
            Atlas_Change__c b = deployed('Second', new List<String>{ 'ApexClass:Foo' }, old.addDays(10));
            Atlas_Change__c c = deployed('Third', new List<String>{ 'ApexClass:Foo' }, old.addDays(20));
            Atlas_Change__c rejected = change('Rejected', 'Rejected idea', null, old);
            Atlas_Change__c proposed = change('Proposed', 'Still in review', null, null);
            Atlas_Change__c recent = deployed('Recent', new List<String>{ 'LightningComponentBundle:fooCmp' }, Datetime.now());
            for (Atlas_Change__c each : new List<Atlas_Change__c>{ a, b, c, rejected, proposed }) Test.setCreatedDate(each.Id, old);

            Map<String, Object> plan = parse(Atlas_Versions.storagePlan(30));
            System.assertEquals(new Set<Object>{ String.valueOf(b.Id), String.valueOf(rejected.Id) }, new Set<Object>((List<Object>) plan.get('ids')),
                'The original (a), the newest restore point (c), unfinished and recent changes stay');
            System.assertEquals(2, plan.get('files'));
            System.assertEquals(1, plan.get('restorePoints'));
            System.assert(Long.valueOf(String.valueOf(plan.get('bytes'))) > 0);

            Atlas_Change__c running = change('Restoring', 'Restore ApexClass Foo to v2 (First)', new List<String>{ 'ApexClass:Foo' }, Datetime.now());
            Atlas_Changes.Manifest m = Atlas_Changes.manifest(running);
            m.restoreFrom = b.Id;
            update new Atlas_Change__c(Id = running.Id, Components__c = JSON.serialize(m));
            System.assertEquals(new List<Object>{ String.valueOf(rejected.Id) }, parse(Atlas_Versions.storagePlan(30)).get('ids'), 'A running restore keeps its source');
            delete running;

            try {
                Atlas_Versions.freeStorage(30, '[]');
                System.assert(false, 'Only what the person reviewed is removed');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('changed since you looked'), e.getMessage()); }
            Map<String, Object> freed = parse(Atlas_Versions.freeStorage(30, JSON.serialize(plan.get('ids'))));
            System.assertEquals(2, freed.get('changes'));
            System.assertEquals(2, freed.get('files'));
            System.assertEquals(0, freed.get('failed'));
            for (Atlas_Change__c each : [SELECT Id, Backup_File__c, Files_Removed__c FROM Atlas_Change__c WHERE Id IN (:b.Id, :rejected.Id)]) {
                System.assertEquals(null, each.Backup_File__c);
                System.assertNotEquals(null, each.Files_Removed__c);
            }
            System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :b.Id]);
            System.assertNotEquals(null, [SELECT Backup_File__c FROM Atlas_Change__c WHERE Id = :a.Id].Backup_File__c);

            List<Object> foo = history('ApexClass:Foo');
            System.assertEquals(4, foo.size(), 'The history itself stays');
            System.assertEquals(true, ((Map<String, Object>) foo[1]).get('restorable'));
            System.assertEquals(false, ((Map<String, Object>) foo[2]).get('restorable'));
            System.assertEquals('Backup removed to free storage', ((Map<String, Object>) foo[2]).get('note'));
            System.assertEquals(true, ((Map<String, Object>) foo[3]).get('restorable'));
            try {
                Atlas_Changes.restorePlan(b.Id, null);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('was removed to free storage'), e.getMessage()); }
            System.assertEquals(0, parse(Atlas_Versions.storagePlan(30)).get('changes'), 'Nothing is offered twice');
            try {
                Atlas_Versions.storagePlan(0);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('Choose how many days'), e.getMessage()); }
        }
    }

    @IsTest
    static void freeingStorageKeepsFilesSharedWithAnythingElse() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Datetime old = Datetime.now().addDays(-100);
            Atlas_Change__c rejected = change('Rejected', 'Rejected idea', null, old);
            Atlas_Change__c kept = change('Proposed', 'Still in review', null, null);
            ContentVersion proposal = new ContentVersion(Title = 'proposal', PathOnClient = 'proposal.json', VersionData = Blob.valueOf('{}'), FirstPublishLocationId = rejected.Id);
            insert proposal;
            update new Atlas_Change__c(Id = rejected.Id, Proposal_File__c = proposal.Id);
            Id backup = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :rejected.Backup_File__c].ContentDocumentId;
            insert new ContentDocumentLink(ContentDocumentId = backup, LinkedEntityId = kept.Id, ShareType = 'V');
            for (Atlas_Change__c each : new List<Atlas_Change__c>{ rejected, kept }) Test.setCreatedDate(each.Id, old);

            Map<String, Object> plan = parse(Atlas_Versions.storagePlan(30));
            System.assertEquals(new List<Object>{ String.valueOf(rejected.Id) }, plan.get('ids'));
            System.assertEquals(1, plan.get('files'), 'The backup is also on a change that stays, so only the proposal goes');
            Map<String, Object> freed = parse(Atlas_Versions.freeStorage(30, JSON.serialize(plan.get('ids'))));
            System.assertEquals(1, freed.get('files'));
            System.assertEquals(0, freed.get('failed'));
            System.assertEquals(0, freed.get('changes'), 'Its restore point is still there');
            Atlas_Change__c after = [SELECT Backup_File__c, Proposal_File__c, Files_Removed__c FROM Atlas_Change__c WHERE Id = :rejected.Id];
            System.assertEquals(rejected.Backup_File__c, after.Backup_File__c);
            System.assertEquals(null, after.Proposal_File__c, 'Only the reference to the removed File is cleared');
            System.assertEquals(null, after.Files_Removed__c);
            System.assertEquals(1, [SELECT COUNT() FROM ContentDocument WHERE Id = :backup]);
            System.assertEquals(0, parse(Atlas_Versions.storagePlan(30)).get('changes'), 'Nothing removable is left to offer');
        }
    }

    @IsTest
    static void aHistoryTooLongToReadWholeIsRefusedRatherThanCutOff() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Datetime old = Datetime.now().addDays(-10);
            deployed('First', new List<String>{ 'ApexClass:Foo' }, old);
            deployed('Second', new List<String>{ 'ApexClass:Foo' }, old.addDays(1));
            System.assertEquals(3, history('ApexClass:Foo').size());
            Atlas_Versions.maxSteps = 1;
            try {
                history('ApexClass:Foo');
                System.assert(false, 'A cut-off history would hide the newest version');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('more than 1 version steps'), e.getMessage()); }
        }
    }
}
