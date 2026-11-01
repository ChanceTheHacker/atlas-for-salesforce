/** Additive recovery only. Reviews, before-state, original payloads and receipts stay private. */
public with sharing class Atlas_WorkspaceRecovery {
    static final String FORMAT = 'atlas-native-recovery';
    static final Map<String, String> WRITABLE = new Map<String, String>{
        'Atlas_Conversation__c' => 'Name,Creation_Key__c,Mode__c,Request__c,Request_File__c,Status__c,UI_State__c,State_File__c,State_Revision__c',
        'Atlas_Message__c' => 'Body__c,Body_File__c,Conversation__c,Direction__c,Kind__c',
        'Atlas_Ticket__c' => 'Assignee__c,Conversation__c,Depends_On__c,Description__c,Due_Date_Note__c,Due_Date_Source__c,Due_Date__c,Epic_Key__c,Epic_Name__c,Epic__c,Export_Batch__c,Export_File__c,Exported_At__c,Import_Revision__c,Issue_Type__c,Jira_Key__c,Jira_Status_Category__c,Jira_Status__c,Jira_Updated__c,Origin_Key__c,Pending_Updates__c,Planning__c,Priority__c,Project_Key__c,Raw_File__c,Reporter__c,Stage__c,Summary__c',
        'Atlas_Person__c' => 'Name,Active__c,Aliases__c,Alias_List__c,Jira_Account_Id__c,Manager__c,User__c,Atlas_Is_Manager__c,Atlas_Jira_Identity_Type__c',
        'Atlas_Setting__c' => 'Name,Data__c,Key__c',
        'Atlas_Library__c' => 'Name,Data_File__c,Kind__c,Revision__c'
    };
    static final Set<String> FILE_FIELDS = new Set<String>{'Request_File__c', 'State_File__c', 'Body_File__c',
        'Raw_File__c', 'Export_File__c', 'Data_File__c', 'Backup_File__c', 'Proposal_File__c'};
    static void check(Boolean ok, String message) { Atlas_Workspace.require(ok, message); }
    static Map<String, Object> objectMap(Object value) { return (Map<String, Object>)value; }
    static String text(Object value) { return value == null ? null : String.valueOf(value); }
    static Map<String, Object> decode(String raw) {
        check(raw != null && Blob.valueOf(raw).size() <= Atlas_Workspace.MAX_RECORD_BYTES, 'Recovery record/plan exceeds 1,000,000 bytes; split the selection, not the record.');
        return objectMap(JSON.deserializeUntyped(raw));
    }
    class Stage {
        Atlas_Library__c row;
        ContentVersion version;
        Map<String, Object> data;
    }
    static Stage stage(Id planId, Boolean lockRow) {
        Stage s = new Stage();
        Id owner = UserInfo.getUserId();
        String query = 'SELECT Id, OwnerId, Data_File__c, Revision__c, Kind__c FROM '
            + Atlas_Library__c.SObjectType.getDescribe().getName() + ' WHERE Id = :planId AND OwnerId = :owner';
        List<SObject> rows = Database.queryWithBinds(query + (lockRow ? ' FOR UPDATE' : ''),
            new Map<String, Object>{'planId' => planId, 'owner' => owner}, AccessLevel.USER_MODE);
        check(rows.size() == 1, 'Recovery plan is missing or is not private data owned by you.');
        s.row = (Atlas_Library__c)rows[0];
        Id versionId = (Id)s.row.Data_File__c;
        ContentVersion meta = [SELECT ContentSize FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
        check(meta.ContentSize <= Atlas_Workspace.MAX_RECORD_BYTES, 'Invalid recovery plan size.');
        s.version = [SELECT Id, ContentDocumentId, VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
        s.data = decode(s.version.VersionData.toString());
        check(s.data.get('type') == FORMAT, 'Not a native recovery plan.');
        return s;
    }
    static void store(Stage s) {
        String raw = JSON.serialize(s.data);
        decode(raw);
        ContentVersion v = new ContentVersion(Title = 'Atlas recovery review', PathOnClient = 'recovery-review.json', VersionData = Blob.valueOf(raw));
        if (s.version == null) v.FirstPublishLocationId = s.row.Id;
        else v.ContentDocumentId = s.version.ContentDocumentId;
        insert as user v;
        s.row.Data_File__c = v.Id;
        s.row.Revision__c = (s.row.Revision__c ?? 0) + 1;
        update as user s.row;
        s.version = [SELECT Id, ContentDocumentId, VersionData FROM ContentVersion WHERE Id = :v.Id WITH USER_MODE];
    }
    static void checkArchive(Id archiveId, Id archiveVersionId) {
        Id owner = UserInfo.getUserId();
        Atlas_Library__c archive = [SELECT Id, Data_File__c FROM Atlas_Library__c WHERE Id = :archiveId AND OwnerId = :owner WITH USER_MODE];
        Id currentId = (Id)archive.Data_File__c;
        ContentVersion current = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :currentId WITH USER_MODE];
        ContentVersion pinned = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :archiveVersionId WITH USER_MODE];
        check(current.ContentDocumentId == pinned.ContentDocumentId, 'The pinned archive version does not belong to your library entry.');
    }
    static Boolean historyOnly(Map<String, Object> source) {
        return source.get('type') == 'Atlas_Change__c'
            || (source.get('type') == 'Atlas_Library__c' && objectMap(source.get('values')).get('Kind__c') == 'upload');
    }
    static Map<String, Object> project(Map<String, Object> data) {
        Map<String, Object> source = objectMap(data.get('source')), values = objectMap(source.get('values'));
        String kind = text(source.get('type'));
        Map<String, Object> output = new Map<String, Object>(), references = objectMap(data.get('references')), staged = objectMap(data.get('staged'));
        List<String> conflicts = new List<String>(), notices = new List<String>{
            'Insert-only: no existing record is overwritten or deleted. Unique identities that already exist block this item.',
            'System IDs, owners, audit dates and auto-numbers are retained in the private history, not impersonated on new records.',
            'Opaque JSON/text is preserved verbatim. Embedded org/record IDs are NOT rewritten; review them before using recovered drafts or pending updates.',
            'Salesforce ticket field-history rows are retained in this private recovery history, not inserted into Salesforce audit tables.'
        };
        List<Object> before = new List<Object>();
        Set<Id> beforeIds = new Set<Id>();
        Atlas_Workspace.objectType(kind);
        try {
            // Same-org source rows are preserved too, even when recovery only creates a separate copy.
            Map<String, Object> current = Atlas_Workspace.readRecord(kind, (Id)text(source.get('id')));
            before.add(current);
            beforeIds.add((Id)text(current.get('id')));
        } catch (Exception unavailable) { /* A portable source ID need not exist in this org or own-data scope. */ }
        if (historyOnly(source)) {
            notices.add('History only: no Atlas Change or upload job is created. Original status/job IDs are inert history.');
        } else {
            check(WRITABLE.containsKey(kind), 'This native type has no recovery writer.');
            Schema.SObjectType type = Atlas_Workspace.objectType(kind);
            if (!type.getDescribe().isCreateable()) conflicts.add('Create access is missing for ' + kind + '.');
            Map<String, Schema.SObjectField> fields = Atlas_Workspace.fields(kind);
            Set<String> allowed = new Set<String>(WRITABLE.get(kind).split(','));
            for (String key : values.keySet()) {
                Object value = values.get(key);
                if (!allowed.contains(key)) {
                    if (value != null && key.endsWith('__c')) notices.add(key + ' is archive-only; it is not on the native write allowlist.');
                    continue;
                }
                if (!fields.containsKey(key)) { conflicts.add('Target schema is missing ' + key + '.'); continue; }
                Schema.DescribeFieldResult info = fields.get(key).getDescribe();
                if (!info.isAccessible() || !info.isCreateable()) {
                    if (value != null) conflicts.add('Create/read field access is missing for ' + key + '.');
                    continue;
                }
                if (value != null && FILE_FIELDS.contains(key)) {
                    Map<String, Object> file = objectMap(staged.get(text(value)));
                    if (file == null) { conflicts.add('Missing staged immutable File for ' + key + ': ' + value); continue; }
                    if (kind == 'Atlas_Library__c' && key == 'Data_File__c') {
                        if (file.get('jsonObject') != true) conflicts.add('Library payload is not a JSON object; preserve it as history instead.');
                        if (file.get('chunked') == true && file.get('chunkComplete') != true) conflicts.add('Current library chunk manifest is incomplete.');
                        if (Integer.valueOf(file.get('storedBytes')) > 1000000) conflicts.add('Current library File exceeds the storage adapter load limit; use a valid chunk manifest.');
                    }
                    value = file.get('id');
                } else if (value != null && info.getType() == Schema.DisplayType.Reference) {
                    String sourceId = text(value);
                    if (!references.containsKey(sourceId)) { conflicts.add('Missing reference mapping for ' + key + ': ' + sourceId); continue; }
                    value = references.get(sourceId);
                    if (value == null) {
                        if (!info.isNillable()) conflicts.add(key + ' is required and cannot be cleared.');
                        notices.add(key + ' will be explicitly cleared; original reference remains in history.');
                    } else {
                        try {
                            Id target = (Id)text(value);
                            check(info.getReferenceTo().contains(target.getSObjectType()), 'Wrong reference type.');
                            String targetKind = target.getSObjectType().getDescribe().getLocalName();
                            if (Atlas_Workspace.TYPES.containsKey(targetKind)) Atlas_Workspace.readRecord(targetKind, target);
                            else {
                                check(target.getSObjectType() == User.SObjectType, 'Unsupported external reference.');
                                List<User> users = [SELECT Id FROM User WHERE Id = :target WITH USER_MODE];
                                check(users.size() == 1, 'User is not accessible.');
                            }
                            value = target;
                        } catch (Exception e) { conflicts.add('Invalid/inaccessible mapping for ' + key + ': ' + e.getMessage()); continue; }
                    }
                }
                if (value instanceof String && info.getLength() > 0 && ((String)value).length() > info.getLength()) {
                    conflicts.add(key + ' exceeds the target field length; it will not be truncated.'); continue;
                }
                output.put(key, value);
                if (info.isUnique() && value != null) {
                    List<SObject> matches = Database.queryWithBinds('SELECT Id FROM ' + type.getDescribe().getName()
                        + ' WHERE ' + info.getName() + ' = :value LIMIT 2', new Map<String, Object>{'value' => value}, AccessLevel.USER_MODE);
                    for (SObject match : matches) {
                        conflicts.add('Existing unique identity ' + key + '; no overwrite or automatic merge.');
                        try {
                            Id matchId = (Id)match.get('Id');
                            if (!beforeIds.contains(matchId)) { before.add(Atlas_Workspace.readRecord(kind, matchId)); beforeIds.add(matchId); }
                        } catch (Exception e) { notices.add('A conflicting record is outside your own-data recovery scope; its body is not copied.'); }
                    }
                }
            }
            for (String key : allowed) if (fields.containsKey(key)) {
                Schema.DescribeFieldResult info = fields.get(key).getDescribe();
                if (!info.isNillable() && !info.isDefaultedOnCreate() && !info.isAutoNumber() && !info.isCalculated()
                    && output.get(key) == null) conflicts.add('Required field is absent: ' + key);
            }
            if (kind == 'Atlas_Ticket__c' && output.get('Conversation__c') != null)
                Atlas_Data.assertTicketMutationsAllowed((Id)output.get('Conversation__c'));
            if (kind == 'Atlas_Library__c' && !new Set<String>{'document', 'notebook', 'workspace', 'draft'}.contains(text(output.get('Kind__c')))) {
                conflicts.add('Only document, notebook, workspace and draft library entries can be materialized.');
            }
            if (kind == 'Atlas_Person__c') {
                // A recovered person follows the same identity rules as one saved in the directory.
                try {
                    List<String> aliases;
                    if (output.get('Alias_List__c') != null) {
                        Object parsed = JSON.deserializeUntyped(text(output.get('Alias_List__c')));
                        check(parsed instanceof List<Object>, 'Alias_List__c is not a list of names.');
                        aliases = Atlas_Identity.cleanNames((List<Object>)parsed);
                        output.put('Alias_List__c', JSON.serialize(aliases));
                    } else aliases = Atlas_Identity.names(new Atlas_Person__c(Aliases__c = text(output.get('Aliases__c'))));
                    String clash = Atlas_Data.personConflict(null, text(output.get('Name')), aliases,
                        (Id)text(output.get('User__c')), output.get('Active__c') != false);
                    if (clash != null) conflicts.add(clash);
                } catch (Exception e) { conflicts.add('Recovered aliases are not valid: ' + e.getMessage()); }
            }
        }
        Map<String, Object> specs = objectMap(data.get('files'));
        Set<String> requiredFiles = new Set<String>();
        for (String field : FILE_FIELDS) if (values.get(field) != null) requiredFiles.add(text(values.get(field)));
        if (kind == 'Atlas_Change__c' && values.get('Result__c') != null) {
            try {
                Map<String, Object> result = objectMap(JSON.deserializeUntyped(text(values.get('Result__c'))));
                if (result != null && result.get('fileId') != null) requiredFiles.add(text(result.get('fileId')));
            } catch (Exception malformedHistory) { /* Historical JSON is never repaired or normalized. */ }
        }
        for (String id : requiredFiles) if (!specs.containsKey(id)) conflicts.add('Source references a File absent from this review: ' + id);
        Set<String> sourceDocuments = new Set<String>();
        for (Object spec : specs.values()) sourceDocuments.add(text(objectMap(spec).get('documentId')));
        if (source.get('links') instanceof List<Object>) for (Object rawLink : (List<Object>)source.get('links')) {
            String documentId = text(objectMap(rawLink).get('ContentDocumentId'));
            if (!sourceDocuments.contains(documentId)) conflicts.add('Source attachment is absent from this review: ' + documentId);
        }
        for (String id : specs.keySet()) if (!staged.containsKey(id)) conflicts.add('File version not staged: ' + id);
        return new Map<String, Object>{'mode' => historyOnly(source) ? 'history-only' : 'insert', 'fields' => output,
            'conflicts' => conflicts, 'notices' => notices, 'before' => before, 'references' => references};
    }
    /** Call once per selected record after preserving the complete raw archive with atlasStorage. */
    @AuraEnabled
    public static String prepareRecord(Id archiveId, Id archiveVersionId, String recordJson, String filesJson, String referencesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            checkArchive(archiveId, archiveVersionId);
            Map<String, Object> source = decode(recordJson), specs = decode(filesJson), references = decode(referencesJson);
            Atlas_Workspace.objectType(text(source.get('type')));
            check(source.get('id') instanceof String && source.get('values') instanceof Map<String, Object>, 'Invalid native record envelope.');
            check(specs.size() <= 1000, 'At most 1,000 File versions per recovery item; nothing was truncated.');
            for (String id : specs.keySet()) {
                Map<String, Object> spec = objectMap(specs.get(id));
                check(spec.get('base64') == null && spec.get('id') == id, 'Pass File metadata only when preparing a review.');
                check(Integer.valueOf(spec.get('bytes')) >= 0 && Integer.valueOf(spec.get('bytes')) <= Atlas_Workspace.MAX_FILE_BYTES,
                    'Unsupported File size in this recovery item.');
                check(Pattern.matches('[a-f0-9]{64}', text(spec.get('sha256')) ?? ''), 'Every File needs a SHA-256 digest.');
                check(String.isNotBlank(text(spec.get('documentId'))) && Decimal.valueOf(text(spec.get('number'))) > 0,
                    'Every File needs its original document identity and version number.');
                check(String.isNotBlank(text(spec.get('path'))) && text(spec.get('path')).length() <= 500, 'Invalid original File path; no path was truncated.');
            }
            Stage s = new Stage();
            s.data = new Map<String, Object>{'type' => FORMAT, 'sourceArchiveId' => archiveId, 'sourceArchiveVersionId' => archiveVersionId,
                'source' => source, 'references' => references, 'files' => specs, 'staged' => new Map<String, Object>(),
                'status' => 'staging', 'created' => System.now()};
            s.data.put('beforeReview', project(s.data));
            s.row = new Atlas_Library__c(Name = 'Atlas native recovery ' + text(source.get('id')), Kind__c = 'workspace', Revision__c = 0);
            insert as user s.row;
            store(s);
            Database.releaseSavepoint(sp);
            return JSON.serialize(new Map<String, Object>{'id' => s.row.Id, 'versionId' => s.version.Id});
        } catch (Exception e) { Database.rollback(sp); Database.releaseSavepoint(sp); throw Atlas_Api.fail(e); }
    }
    /** One bounded binary per transaction; retries return the same immutable staged version. */
    @AuraEnabled
    public static String stageFile(Id planId, String sourceVersionId, String base64) {
        Savepoint sp = Database.setSavepoint();
        try {
            Stage s = stage(planId, true);
            check(s.data.get('status') == 'staging', 'This recovery is already applied.');
            Map<String, Object> specs = objectMap(s.data.get('files')), staged = objectMap(s.data.get('staged'));
            Map<String, Object> spec = objectMap(specs.get(sourceVersionId));
            check(spec != null, 'File was not included in this recovery review.');
            check(base64 != null && base64.length() <= 2000000, 'File exceeds the bounded request size.');
            Blob bytes = EncodingUtil.base64Decode(base64);
            check(bytes.size() == Integer.valueOf(spec.get('bytes')) && Atlas_Workspace.digest(bytes) == spec.get('sha256'), 'File integrity check failed.');
            if (staged.containsKey(sourceVersionId)) {
                Database.releaseSavepoint(sp);
                return JSON.serialize(staged.get(sourceVersionId));
            }
            // Rebind only the storage manifest's explicit chunk IDs. The original bytes stay in the source archive.
            Map<String, Object> manifest;
            Integer textChars;
            Boolean chunked = false, chunkComplete = false;
            try {
                String raw = bytes.toString();
                textChars = raw.length();
                if (raw.trim().startsWith('{')) manifest = objectMap(JSON.deserializeUntyped(raw));
            } catch (Exception ignored) { manifest = null; }
            if (manifest != null && manifest.get('type') == 'atlas-chunked') {
                chunked = true;
                Map<String, Object> parts = objectMap(manifest.get('parts'));
                Integer count = Integer.valueOf(manifest.get('count')), totalChars = 0, totalBytes = 0;
                check(parts != null && parts.size() <= 600 && count != null && count > 0 && count <= 600, 'Invalid library chunk manifest.');
                for (Object rawPart : parts.values()) {
                    Map<String, Object> part = objectMap(rawPart), replacement = objectMap(staged.get(text(part.get('id'))));
                    check(replacement != null, 'Stage the library chunk dependencies before their manifest.');
                    check(part.get('sha256') == replacement.get('originalSha256') && replacement.get('storedSha256') == replacement.get('originalSha256')
                        && part.get('chars') != null && part.get('bytes') != null
                        && Integer.valueOf(part.get('chars')) == Integer.valueOf(replacement.get('textChars'))
                        && Integer.valueOf(part.get('bytes')) == Integer.valueOf(replacement.get('originalBytes')), 'Chunk does not match its manifest.');
                    totalChars += Integer.valueOf(part.get('chars')); totalBytes += Integer.valueOf(part.get('bytes'));
                    part.put('id', replacement.get('id'));
                }
                chunkComplete = parts.size() == count && totalChars == Integer.valueOf(manifest.get('chars')) && totalBytes == Integer.valueOf(manifest.get('bytes'));
                for (Integer index = 0; index < count; index++) chunkComplete = chunkComplete && parts.containsKey(String.valueOf(index));
                bytes = Blob.valueOf(JSON.serialize(manifest));
            }
            String documentKey = text(spec.get('documentId'));
            Id documentId;
            Decimal latest = -1;
            for (Object raw : staged.values()) {
                Map<String, Object> earlier = objectMap(raw);
                if (earlier.get('sourceDocumentId') == documentKey) {
                    documentId = (Id)text(earlier.get('documentId'));
                    Decimal versionNumber = Decimal.valueOf(text(earlier.get('number')));
                    if (versionNumber > latest) latest = versionNumber;
                }
            }
            Decimal versionNumber = Decimal.valueOf(text(spec.get('number')));
            check(versionNumber > latest, 'Restore versions in original version-number order; no histories are silently reordered.');
            String title = text(spec.get('title')) ?? 'recovered File';
            if (!title.startsWith('Atlas ')) title = 'Atlas ' + title;
            check(title.length() <= 255, 'The recovered File title exceeds 255 characters after the required Atlas prefix; no name was truncated.');
            ContentVersion file = new ContentVersion(Title = title, PathOnClient = text(spec.get('path')) ?? 'recovered.bin',
                VersionData = bytes, Description = 'Original metadata and timestamps are preserved in the Atlas native recovery review.');
            if (documentId == null) file.FirstPublishLocationId = s.row.Id;
            else file.ContentDocumentId = documentId;
            insert as user file;
            file = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :file.Id WITH USER_MODE];
            Map<String, Object> receipt = new Map<String, Object>{'id' => file.Id, 'documentId' => file.ContentDocumentId,
                'sourceDocumentId' => documentKey, 'number' => versionNumber, 'originalSha256' => spec.get('sha256'), 'storedSha256' => Atlas_Workspace.digest(bytes),
                'originalBytes' => spec.get('bytes'), 'storedBytes' => bytes.size(), 'textChars' => textChars,
                'jsonObject' => manifest != null, 'chunked' => chunked, 'chunkComplete' => chunkComplete};
            staged.put(sourceVersionId, receipt);
            store(s);
            Database.releaseSavepoint(sp);
            return JSON.serialize(receipt);
        } catch (Exception e) { Database.rollback(sp); Database.releaseSavepoint(sp); throw Atlas_Api.fail(e); }
    }
    static String beforeTokens(Map<String, Object> preview) {
        List<String> tokens = new List<String>();
        for (Object raw : (List<Object>)preview.get('before')) {
            Map<String, Object> record = objectMap(raw);
            tokens.add(text(record.get('id')) + ':' + text(record.get('token')));
        }
        tokens.sort();
        return JSON.serialize(tokens);
    }
    @AuraEnabled
    public static String reviewRecord(Id planId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Stage s = stage(planId, true);
            Map<String, Object> preview = project(s.data);
            if (s.data.get('status') != 'applied') {
                s.data.put('beforeReview', preview);
                s.data.put('reviewBeforeTokens', beforeTokens(preview));
                store(s);
            }
            preview.put('id', s.row.Id);
            preview.put('versionId', s.version.Id);
            preview.put('digest', Atlas_Workspace.digest(s.version.VersionData));
            preview.put('source', s.data.get('source'));
            preview.put('files', s.data.get('files'));
            preview.put('status', s.data.get('status'));
            preview.put('receipt', s.data.get('receipt'));
            Database.releaseSavepoint(sp);
            return JSON.serialize(preview);
        } catch (Exception e) { Database.rollback(sp); Database.releaseSavepoint(sp); throw Atlas_Api.fail(e); }
    }
    static Object typed(Object value, Schema.DescribeFieldResult field) {
        if (value == null) return null;
        if (field.getType() == Schema.DisplayType.Date) return JSON.deserialize(JSON.serialize(value), Date.class);
        if (field.getType() == Schema.DisplayType.DateTime) return JSON.deserialize(JSON.serialize(value), Datetime.class);
        if (field.getType() == Schema.DisplayType.Reference) return (Id)text(value);
        if (field.getType() == Schema.DisplayType.Integer) return Integer.valueOf(text(value));
        if (new Set<String>{'DOUBLE', 'CURRENCY', 'PERCENT'}.contains(String.valueOf(field.getType()).toUpperCase())) return Decimal.valueOf(text(value));
        return value;
    }
    /** Only the exact reviewed plan is applied. Original records and Files are never updated. */
    @AuraEnabled
    public static String applyRecord(Id planId, Id reviewedVersionId, String reviewedDigest) {
        Savepoint sp = Database.setSavepoint();
        try {
            Stage s = stage(planId, true);
            if (s.data.get('status') == 'applied') {
                check(s.data.get('reviewedVersionId') == String.valueOf(reviewedVersionId) && s.data.get('reviewedDigest') == reviewedDigest,
                    'This is not the review that was applied.');
                Database.releaseSavepoint(sp);
                return JSON.serialize(s.data.get('receipt'));
            }
            check(s.version.Id == reviewedVersionId && Atlas_Workspace.digest(s.version.VersionData) == reviewedDigest,
                'Recovery review changed. Reload and explicitly review the new version before applying.');
            checkArchive((Id)text(s.data.get('sourceArchiveId')), (Id)text(s.data.get('sourceArchiveVersionId')));
            // People are checked for clashing names under the same lock that ordinary saves take.
            if (text(objectMap(s.data.get('source')).get('type')) == 'Atlas_Person__c') Atlas_Data.lockPeople();
            Map<String, Object> preview = project(s.data);
            check(s.data.get('reviewBeforeTokens') != null && s.data.get('reviewBeforeTokens') == beforeTokens(preview),
                'Before-state changed after review. Reload and review again; no native record was changed.');
            check(((List<String>)preview.get('conflicts')).isEmpty(), 'Recovery conflicts remain. No native record was changed. ' + JSON.serialize(preview.get('conflicts')));
            Map<String, Object> source = objectMap(s.data.get('source')), staged = objectMap(s.data.get('staged'));
            Set<Id> versionIds = new Set<Id>(), documents = new Set<Id>();
            for (Object raw : staged.values()) versionIds.add((Id)text(objectMap(raw).get('id')));
            List<ContentVersion> versions = [SELECT Id, ContentDocumentId, FirstPublishLocationId FROM ContentVersion WHERE Id IN :versionIds WITH USER_MODE];
            check(versions.size() == versionIds.size(), 'A reviewed File is no longer accessible.');
            // A forged plan cannot attach an unrelated private document: each staged document must be linked here.
            for (ContentVersion v : versions) documents.add(v.ContentDocumentId);
            Set<Id> linked = new Set<Id>();
            Id stageId = s.row.Id;
            for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :stageId WITH USER_MODE]) linked.add(link.ContentDocumentId);
            check(linked.containsAll(documents), 'A staged File does not belong to this recovery plan.');
            Set<Id> originatedHere = new Set<Id>();
            if (!documents.isEmpty()) for (ContentVersion first : [SELECT ContentDocumentId, FirstPublishLocationId FROM ContentVersion
                WHERE ContentDocumentId IN :documents AND VersionNumber = '1' WITH USER_MODE]) {
                if (first.FirstPublishLocationId == stageId) originatedHere.add(first.ContentDocumentId);
            }
            check(originatedHere.containsAll(documents), 'Only Files created privately for this recovery can be attached.');
            Id recoveredId = s.row.Id;
            if (!historyOnly(source)) {
                String kind = text(source.get('type'));
                SObject record = Atlas_Workspace.objectType(kind).newSObject();
                Map<String, Schema.SObjectField> fields = Atlas_Workspace.fields(kind);
                for (String key : objectMap(preview.get('fields')).keySet()) {
                    Schema.DescribeFieldResult field = fields.get(key).getDescribe();
                    record.put(field.getName(), typed(objectMap(preview.get('fields')).get(key), field));
                }
                insert as user record;
                recoveredId = (Id)record.get('Id');
                List<ContentDocumentLink> links = new List<ContentDocumentLink>();
                for (Id documentId : documents) links.add(new ContentDocumentLink(ContentDocumentId = documentId,
                    LinkedEntityId = recoveredId, ShareType = 'V'));
                if (!links.isEmpty()) insert as user links;
            }
            Map<String, Object> receipt = new Map<String, Object>{'recordId' => recoveredId, 'historyId' => s.row.Id,
                'sourceId' => source.get('id'), 'mode' => preview.get('mode'), 'appliedAt' => System.now(),
                'note' => 'New data only; originals unchanged. Change jobs were not restarted or deployed.'};
            // The before-state matched the review's tokens above, so beforeReview already holds it.
            // Only the tokens are kept here; another full copy could push the plan past its size limit.
            s.data.put('beforeApply', new Map<String, Object>{'tokens' => beforeTokens(preview), 'sameAs' => 'beforeReview'});
            s.data.put('status', 'applied');
            s.data.put('reviewedVersionId', reviewedVersionId);
            s.data.put('reviewedDigest', reviewedDigest);
            s.data.put('receipt', receipt);
            store(s);
            Database.releaseSavepoint(sp);
            return JSON.serialize(receipt);
        } catch (Exception e) { Database.rollback(sp); Database.releaseSavepoint(sp); throw Atlas_Api.fail(e); }
    }
}
