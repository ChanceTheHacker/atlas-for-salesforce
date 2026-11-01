/**
 * Numbered versions of each component, and freeing the storage old changes use.
 *
 * Each Atlas_Version__c row is one step that changed a component: a deployed change
 * or a restore. Version 1 is the component before its first step, and step k made
 * version k + 1. A version can be put back from the backup taken by the step that
 * replaced it, so restoring v2 deploys the backup of the change that made v3.
 */
public with sharing class Atlas_Versions {
    static final Set<String> FINISHED = new Set<String>{ 'Deployed', 'Failed', 'Restored', 'Rejected' };
    static String namespace;

    /** "Type:Name" without this org's namespace prefix, so local and qualified names match. */
    public static String componentKey(String k) {
        if (namespace == null) namespace = [SELECT NamespacePrefix FROM Organization WITH USER_MODE LIMIT 1].NamespacePrefix ?? '';
        if (k == null || namespace == '') return k;
        String prefix = namespace.toLowerCase() + '__';
        List<String> parts = new List<String>();
        for (String part : k.substringAfter(':').split('\\.', -1)) {
            parts.add(part.toLowerCase().startsWith(prefix) ? part.substring(prefix.length()) : part);
        }
        return k.substringBefore(':') + ':' + String.join(parts, '.');
    }

    static List<Atlas_Version__c> rows(Atlas_Change__c change, Atlas_Changes.Manifest m, String kind, Datetime at, Boolean backedUp) {
        // An older release listed bundle files as components. Its steps are recorded by bundle,
        // and only a backup that can be matched to its bundles counts as a saved copy.
        Atlas_Changes.Manifest bundled = Atlas_Changes.reconciled(m);
        Set<String> saved = new Set<String>();
        if (bundled != null) for (Atlas_Changes.Found f : bundled.found) saved.add(componentKey(f.type + ':' + f.name).toLowerCase());
        // Changes from early releases did not record what they deployed: a deployment sent
        // everything requested, a restore everything backed up.
        List<String> keys = m.deployed.clone();
        if (keys.isEmpty()) {
            for (Atlas_Changes.Found f : m.found) keys.add(f.type + ':' + f.name);
            if (kind == 'Change') for (Atlas_Api.Component c : m.missing) keys.add(c.type + ':' + c.name);
        }
        Map<String, Atlas_Version__c> out = new Map<String, Atlas_Version__c>();
        for (String k : keys) {
            String component = componentKey(Atlas_Changes.logicalKey(k));
            if (component.length() > 255 || out.containsKey(component.toLowerCase())) continue;
            out.put(component.toLowerCase(), new Atlas_Version__c(Change__c = change.Id, Component__c = component, Kind__c = kind,
                Description__c = (m.versionLabel ?? change.Summary__c ?? change.Name).abbreviate(255), At__c = at,
                Has_Backup__c = backedUp && saved.contains(component.toLowerCase())));
        }
        return out.values();
    }

    /** Adds one step per component the change deployed. backedUp: the change saved a backup of them first. */
    public static void record(Atlas_Change__c change, Atlas_Changes.Manifest m, String kind, Datetime at, Boolean backedUp) {
        List<Atlas_Version__c> steps = new List<Atlas_Version__c>();
        // A change restored in place before version history existed also needs the step it restored.
        if (kind == 'Restore' && m.restoreFrom == null && [SELECT COUNT() FROM Atlas_Version__c WHERE Change__c = :change.Id WITH USER_MODE] == 0)
            steps.addAll(rows(change, m, 'Change', change.Decided_At__c ?? at, true));
        steps.addAll(rows(change, m, kind, at, backedUp));
        if (!steps.isEmpty()) Database.insert(steps, false, AccessLevel.USER_MODE);
    }

    /** Adds steps for changes that finished before version history existed. */
    public static void backfill() {
        List<Atlas_Version__c> steps = new List<Atlas_Version__c>();
        for (Atlas_Change__c change : [
            SELECT Id, Name, Summary__c, Status__c, Components__c, Backup_File__c, Decided_At__c, LastModifiedDate FROM Atlas_Change__c
            WHERE Status__c IN ('Deployed', 'Restored') AND Id NOT IN (SELECT Change__c FROM Atlas_Version__c)
            WITH USER_MODE ORDER BY CreatedDate LIMIT 200
        ]) {
            Atlas_Changes.Manifest m = Atlas_Changes.manifest(change);
            if (m.restoreFrom != null) {
                steps.addAll(rows(change, m, 'Restore', change.LastModifiedDate, change.Backup_File__c != null));
                continue;
            }
            steps.addAll(rows(change, m, 'Change', change.Decided_At__c ?? change.LastModifiedDate, true));
            if (change.Status__c == 'Restored') steps.addAll(rows(change, m, 'Restore', change.LastModifiedDate, false));
        }
        if (!steps.isEmpty()) Database.insert(steps, false, AccessLevel.USER_MODE);
    }

    @TestVisible static Integer maxSteps = 10000;

    /** Steps for each component, oldest first, keyed by lowercase component key. */
    static Map<String, List<Atlas_Version__c>> steps(Set<String> components) {
        Map<String, List<Atlas_Version__c>> out = new Map<String, List<Atlas_Version__c>>();
        Integer read = 0;
        for (Atlas_Version__c row : [
            SELECT Id, Change__c, Change__r.Name, Change__r.Backup_File__c, Change__r.Decided_By__r.Name, Component__c, Kind__c, Description__c, At__c, Has_Backup__c
            FROM Atlas_Version__c WHERE Component__c IN :components WITH USER_MODE ORDER BY At__c, Id LIMIT :(maxSteps + 1)
        ]) {
            // A cut-off history would hide the newest versions, and with them what a restore replaces.
            if (++read > maxSteps) throw new Atlas_Api.AtlasException('These components have more than ' + maxSteps.format() + ' version steps, too many to read at once. Choose fewer components.');
            String k = row.Component__c.toLowerCase();
            if (!out.containsKey(k)) out.put(k, new List<Atlas_Version__c>());
            out.get(k).add(row);
        }
        return out;
    }

    /** Every version of one component, newest first. */
    static List<Map<String, Object>> versions(List<Atlas_Version__c> steps) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        Integer n = steps.size();
        for (Integer j = n + 1; j >= 1; j--) {
            Atlas_Version__c made = j >= 2 ? steps[j - 2] : null;
            Atlas_Version__c next = j <= n ? steps[j - 1] : null;
            Map<String, Object> v = new Map<String, Object>{ 'number' => j, 'current' => j == n + 1, 'label' => made == null ? 'Original' : made.Description__c };
            if (made != null) {
                v.put('kind', made.Kind__c);
                v.put('change', made.Change__r.Name);
                v.put('changeId', made.Change__c);
                v.put('at', made.At__c);
                v.put('by', made.Change__r.Decided_By__r?.Name);
            }
            if (next != null) {
                Boolean saved = next.Change__r.Backup_File__c != null;
                v.put('sourceId', next.Change__c);
                v.put('restorable', next.Has_Backup__c && saved);
                if (!next.Has_Backup__c) v.put('note', j == 1 && next.Kind__c == 'Change' ? 'Did not exist before ' + next.Change__r.Name : 'No saved copy');
                else if (!saved) v.put('note', 'Backup removed to free storage');
            }
            out.add(v);
        }
        return out;
    }

    /** Components Atlas has changed, most recently changed first. */
    @AuraEnabled
    public static String componentIndex() {
        try {
            backfill();
            Map<String, Map<String, Object>> byKey = new Map<String, Map<String, Object>>();
            List<Atlas_Version__c> rows = [
                SELECT Component__c, Description__c, At__c, Change__r.Name FROM Atlas_Version__c WITH USER_MODE ORDER BY At__c DESC, Id DESC LIMIT 5000
            ];
            for (Atlas_Version__c row : rows) {
                String k = row.Component__c.toLowerCase();
                Map<String, Object> entry = byKey.get(k);
                if (entry == null) {
                    byKey.put(k, new Map<String, Object>{
                        'key' => row.Component__c, 'type' => row.Component__c.substringBefore(':'), 'name' => row.Component__c.substringAfter(':'),
                        'versions' => 2, 'latest' => row.Description__c, 'change' => row.Change__r.Name, 'at' => row.At__c
                    });
                } else entry.put('versions', (Integer) entry.get('versions') + 1);
            }
            return JSON.serialize(new Map<String, Object>{ 'components' => byKey.values(), 'complete' => rows.size() < 5000 });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    @AuraEnabled
    public static String componentHistory(String component) {
        try {
            backfill();
            String k = componentKey(component);
            List<Atlas_Version__c> rows = steps(new Set<String>{ k }).get(k.toLowerCase()) ?? new List<Atlas_Version__c>();
            return JSON.serialize(new Map<String, Object>{ 'component' => rows.isEmpty() ? k : rows[0].Component__c, 'versions' => versions(rows) });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * For each backed-up key of the source change: the version its backup holds, the
     * current version, and the versions a restore replaces. latestId pins the newest
     * step, so a confirmation cannot be used after another change lands.
     */
    public static List<Map<String, Object>> plan(Atlas_Change__c source, List<String> keys) {
        Datetime taken;
        Set<String> components = new Set<String>();
        for (String k : keys) components.add(componentKey(k));
        Map<String, List<Atlas_Version__c>> all = steps(components);
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (String k : keys) {
            String component = componentKey(k);
            List<Atlas_Version__c> rows = all.get(component.toLowerCase()) ?? new List<Atlas_Version__c>();
            // The source's backup holds the version its own step replaced. A change that never
            // finished has no step, so its backup holds whatever was current when it was taken.
            Integer before = -1;
            for (Integer i = 0; i < rows.size() && before < 0; i++) if (rows[i].Change__c == source.Id) before = i;
            if (before < 0) {
                taken = taken ?? [SELECT CreatedDate FROM ContentVersion WHERE Id = :source.Backup_File__c WITH USER_MODE].CreatedDate;
                before = 0;
                for (Atlas_Version__c row : rows) if (row.At__c <= taken) before++;
            }
            List<Map<String, Object>> undone = new List<Map<String, Object>>();
            for (Integer i = before; i < rows.size(); i++) {
                undone.add(new Map<String, Object>{ 'number' => i + 2, 'label' => rows[i].Description__c, 'change' => rows[i].Change__r.Name });
            }
            out.add(new Map<String, Object>{
                'key' => k, 'component' => component, 'type' => component.substringBefore(':'), 'name' => component.substringAfter(':'),
                'restoreTo' => before + 1, 'label' => before == 0 ? 'Original' : rows[before - 1].Description__c,
                'current' => rows.size() + 1, 'undone' => undone, 'latestId' => rows.isEmpty() ? '' : String.valueOf(rows[rows.size() - 1].Id)
            });
        }
        return out;
    }

    // ---------------------------------------------------------------- storage

    /**
     * Finished changes older than the cutoff whose files can go. Every component keeps
     * its original and its newest restore point, and a running restore keeps its source.
     */
    static List<Atlas_Change__c> removable(Integer days) {
        if (days == null || days < 1 || days > 3650) throw new Atlas_Api.AtlasException('Choose how many days old the changes must be.');
        Set<Id> keep = new Set<Id>();
        Map<String, Id> newest = new Map<String, Id>();
        Set<String> seen = new Set<String>();
        Integer scanned = 0;
        for (Atlas_Version__c row : [
            SELECT Component__c, Change__c, Has_Backup__c, Change__r.Backup_File__c FROM Atlas_Version__c WITH USER_MODE ORDER BY At__c, Id LIMIT 20001
        ]) {
            // Unread newer steps could hold a component's newest restore point, so never guess.
            if (++scanned > 20000) throw new Atlas_Api.AtlasException('Version history has more than 20,000 steps, too many to work out which restore points to keep. Nothing was removed.');
            String k = row.Component__c.toLowerCase();
            if (seen.add(k) && row.Has_Backup__c) keep.add(row.Change__c);
            if (row.Has_Backup__c && row.Change__r.Backup_File__c != null) newest.put(k, row.Change__c);
        }
        keep.addAll(newest.values());
        for (Atlas_Change__c running : [
            SELECT Components__c FROM Atlas_Change__c WHERE Status__c IN ('Deploying', 'Restoring') WITH USER_MODE LIMIT 200
        ]) {
            Id source = Atlas_Changes.manifest(running).restoreFrom;
            if (source != null) keep.add(source);
        }
        Datetime cutoff = Datetime.now().addDays(-days);
        return [
            SELECT Id, Name, Result__c FROM Atlas_Change__c
            WHERE Status__c IN :FINISHED AND CreatedDate < :cutoff AND (Decided_At__c = null OR Decided_At__c < :cutoff)
                AND Files_Removed__c = null AND Id NOT IN :keep
            WITH USER_MODE ORDER BY CreatedDate LIMIT 200
        ];
    }

    /**
     * Change ID → IDs of the files saved on it: backups, proposals and full results. A File
     * that is also shared with anything else, such as a change that is kept, a ticket or a
     * library, belongs there too and is left alone.
     */
    static Map<Id, Set<Id>> files(List<Atlas_Change__c> changes) {
        Map<Id, Set<Id>> out = new Map<Id, Set<Id>>();
        if (changes.isEmpty()) return out;
        Set<Id> candidates = new Map<Id, Atlas_Change__c>(changes).keySet();
        Set<Id> all = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :candidates WITH USER_MODE
        ]) {
            if (!out.containsKey(link.LinkedEntityId)) out.put(link.LinkedEntityId, new Set<Id>());
            out.get(link.LinkedEntityId).add(link.ContentDocumentId);
            all.add(link.ContentDocumentId);
        }
        if (all.isEmpty()) return out;
        Set<Id> shared = new Set<Id>();
        for (ContentDocumentLink link : [SELECT ContentDocumentId, LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId IN :all WITH USER_MODE]) {
            // The owner's own link is not sharing.
            if (!candidates.contains(link.LinkedEntityId) && link.LinkedEntityId.getSObjectType() != User.SObjectType) shared.add(link.ContentDocumentId);
        }
        for (Set<Id> ids : out.values()) ids.removeAll(shared);
        return out;
    }

    static Map<String, Object> describe(Integer days) {
        List<Atlas_Change__c> changes = removable(days);
        Map<Id, Set<Id>> byChange = files(changes);
        Set<Id> documents = new Set<Id>();
        List<String> ids = new List<String>(), names = new List<String>();
        for (Atlas_Change__c change : changes) {
            if (!byChange.containsKey(change.Id) || byChange.get(change.Id).isEmpty()) continue;
            documents.addAll(byChange.get(change.Id));
            ids.add(change.Id);
            if (names.size() < 20) names.add(change.Name);
        }
        Long bytes = 0;
        if (!documents.isEmpty()) {
            for (ContentVersion version : [SELECT ContentSize FROM ContentVersion WHERE ContentDocumentId IN :documents WITH USER_MODE]) bytes += version.ContentSize ?? 0;
        }
        Integer points = ids.isEmpty() ? 0 : [SELECT COUNT() FROM Atlas_Version__c WHERE Change__c IN :ids AND Has_Backup__c = true WITH USER_MODE];
        return new Map<String, Object>{
            'days' => days, 'changes' => ids.size(), 'ids' => ids, 'files' => documents.size(), 'bytes' => bytes,
            'restorePoints' => points, 'names' => names, 'more' => Math.max(0, ids.size() - names.size())
        };
    }

    /** What freeStorage would remove. Nothing is changed. */
    @AuraEnabled
    public static String storagePlan(Integer olderThanDays) {
        try {
            backfill();
            return JSON.serialize(describe(olderThanDays));
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    /**
     * Removes the files of exactly the changes the person reviewed. The change records
     * and their history stay; their versions are marked as no longer restorable.
     */
    @AuraEnabled
    public static String freeStorage(Integer olderThanDays, String expectedJson) {
        try {
            Set<String> expected = new Set<String>();
            for (Object id : (List<Object>) JSON.deserializeUntyped(expectedJson ?? '[]')) expected.add(String.valueOf(id));
            // Holds off a new proposal, backup or restore of these changes until the files are gone,
            // so the check below sees the final state of every one of them.
            List<Atlas_Change__c> locked = [SELECT Id FROM Atlas_Change__c WHERE Id IN :expected WITH USER_MODE FOR UPDATE];
            Map<String, Object> now = describe(olderThanDays);
            if (!expected.equals(new Set<String>((List<String>) now.get('ids'))))
                throw new Atlas_Api.AtlasException('What can be removed changed since you looked. Review it again.');
            List<Atlas_Change__c> changes = [SELECT Id, Result__c, Backup_File__c, Proposal_File__c FROM Atlas_Change__c WHERE Id IN :expected WITH USER_MODE];
            Map<Id, Set<Id>> byChange = files(changes);
            // Which File each reference points at, read before the Files are gone.
            Set<Id> referenced = new Set<Id>();
            for (Atlas_Change__c change : changes) {
                Map<String, Object> result = parse(change.Result__c);
                for (Object ref : new List<Object>{ change.Backup_File__c, change.Proposal_File__c, result?.get('fileId') })
                    if (ref != null) referenced.add(Id.valueOf(String.valueOf(ref)));
            }
            Map<Id, Id> documentOf = new Map<Id, Id>();
            if (!referenced.isEmpty()) {
                for (ContentVersion version : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :referenced WITH USER_MODE]) documentOf.put(version.Id, version.ContentDocumentId);
            }

            Savepoint beforeRemoval = Database.setSavepoint();
            // Two removed changes can share one File; delete it once.
            Set<Id> unique = new Set<Id>();
            for (Set<Id> ids : byChange.values()) unique.addAll(ids);
            List<ContentDocument> documents = new List<ContentDocument>();
            for (Id id : unique) documents.add(new ContentDocument(Id = id));
            Set<Id> removed = new Set<Id>();
            List<Database.DeleteResult> results = documents.isEmpty() ? new List<Database.DeleteResult>() : Database.delete(documents, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < results.size(); i++) if (results[i].isSuccess()) removed.add(documents[i].Id);

            // A reference is cleared only when its own File was removed. A File that could not be
            // removed stays usable, and the change stays listed so a later cleanup can try again.
            List<Atlas_Change__c> cleared = new List<Atlas_Change__c>();
            Integer finished = 0;
            for (Atlas_Change__c change : changes) {
                if (!byChange.containsKey(change.Id)) continue;
                Atlas_Change__c row = new Atlas_Change__c(Id = change.Id);
                Boolean touched = false;
                if (change.Backup_File__c != null && removed.contains(documentOf.get(change.Backup_File__c))) {
                    row.Backup_File__c = null;
                    touched = true;
                }
                if (change.Proposal_File__c != null && removed.contains(documentOf.get(change.Proposal_File__c))) {
                    row.Proposal_File__c = null;
                    touched = true;
                }
                Map<String, Object> result = parse(change.Result__c);
                Object fileId = result?.get('fileId');
                if (fileId != null && removed.contains(documentOf.get(Id.valueOf(String.valueOf(fileId))))) {
                    result.remove('fileId');
                    result.remove('fullResultUrl');
                    result.put('errorMessage', 'The full Salesforce result was removed to free storage.');
                    row.Result__c = JSON.serialize(result);
                    touched = true;
                }
                Boolean allGone = removed.containsAll(byChange.get(change.Id));
                // A backup shared with something else stays, and so does the change's restore point.
                Boolean backupGone = change.Backup_File__c == null || removed.contains(documentOf.get(change.Backup_File__c));
                if (allGone && backupGone) {
                    row.Files_Removed__c = Datetime.now();
                    touched = true;
                    finished++;
                }
                if (touched) cleared.add(row);
            }
            List<Database.SaveResult> saved = cleared.isEmpty() ? new List<Database.SaveResult>() : Database.update(cleared, false, AccessLevel.USER_MODE);
            for (Database.SaveResult r : saved) {
                if (!r.isSuccess()) {
                    // A deleted File with a reference still pointing at it would break that change, so undo everything.
                    Database.rollback(beforeRemoval);
                    throw new Atlas_Api.AtlasException('Could not update a change after removing its files, so nothing was removed: ' + r.getErrors()[0].getMessage());
                }
            }
            return JSON.serialize(new Map<String, Object>{
                'changes' => finished, 'files' => removed.size(), 'failed' => documents.size() - removed.size(), 'bytes' => now.get('bytes')
            });
        } catch (Exception e) {
            throw Atlas_Api.fail(e);
        }
    }

    static Map<String, Object> parse(String text) {
        if (String.isBlank(text)) return null;
        Object value = JSON.deserializeUntyped(text);
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
    }
}
