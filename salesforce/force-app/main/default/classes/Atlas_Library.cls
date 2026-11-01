/** Versioned personal library. JSON is validated, never normalized or truncated. */
public with sharing class Atlas_Library {
    public static final Integer MAX_JSON_BYTES = 1000000;
    public static final Integer MAX_PAGE_SIZE = 50;
    static final Set<String> KINDS = new Set<String>{ 'document', 'notebook', 'workspace', 'draft' };

    static void access(Boolean writing, Boolean creating) {
        Schema.DescribeSObjectResult objectInfo = Atlas_Library__c.SObjectType.getDescribe();
        if (!objectInfo.isAccessible() || (writing && !(creating ? objectInfo.isCreateable() : objectInfo.isUpdateable()))) {
            throw new Atlas_Api.AtlasException('Atlas Library access is required. Ask your administrator for the Atlas permission set.');
        }
        for (Schema.SObjectField field : new List<Schema.SObjectField>{
            Atlas_Library__c.Name, Atlas_Library__c.Kind__c,
            Atlas_Library__c.Data_File__c, Atlas_Library__c.Revision__c
        }) {
            Schema.DescribeFieldResult info = field.getDescribe();
            if (!info.isAccessible() || (writing && !(creating ? info.isCreateable() : info.isUpdateable()))) {
                throw new Atlas_Api.AtlasException('Read/write access to the Atlas Library fields is required.');
            }
        }
    }

    static Integer pageLimit(Integer pageSize) {
        if (pageSize == null) return 25;
        if (pageSize < 1 || pageSize > MAX_PAGE_SIZE) throw new Atlas_Api.AtlasException('Page size must be 1–50.');
        return pageSize;
    }

    static Id cursorId(String cursor, Schema.SObjectType expectedType) {
        if (String.isBlank(cursor)) return null;
        Id result = (Id) cursor;
        if (result.getSObjectType() != expectedType) throw new Atlas_Api.AtlasException('Invalid library cursor.');
        return result;
    }

    static Map<String, Object> summary(Atlas_Library__c row) {
        return new Map<String, Object>{
            'id' => row.Id, 'title' => row.Name, 'kind' => row.Kind__c,
            'revision' => row.Revision__c, 'versionId' => row.Data_File__c,
            'updated' => row.LastModifiedDate, 'maxJsonBytes' => MAX_JSON_BYTES
        };
    }

    /** Stable ID keyset paging, newest first; the cursor is exclusive, and no JSON bodies are fetched. */
    @AuraEnabled
    public static String listEntries(String kind, String search, String cursor, Integer pageSize) {
        try {
            access(false, false);
            if (String.isNotBlank(kind) && !KINDS.contains(kind)) throw new Atlas_Api.AtlasException('Unknown library kind.');
            if (search != null && search.length() > 80) throw new Atlas_Api.AtlasException('Search is limited to 80 characters.');
            Id afterId = cursorId(cursor, Atlas_Library__c.SObjectType);
            String wanted = String.isBlank(kind) ? null : kind;
            String needle = '%' + (search == null ? '' : search.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')) + '%';
            Integer count = pageLimit(pageSize), fetch = count + 1;
            String query = 'SELECT Id, Name, Kind__c, Revision__c, Data_File__c, LastModifiedDate FROM Atlas_Library__c WHERE Kind__c != \'upload\' AND Data_File__c != null AND Name LIKE :needle';
            if (wanted != null) query += ' AND Kind__c = :wanted';
            if (afterId != null) query += ' AND Id < :afterId';
            List<Atlas_Library__c> rows = Database.queryWithBinds(query + ' ORDER BY Id DESC LIMIT :fetch',
                new Map<String, Object>{ 'needle' => needle, 'wanted' => wanted, 'afterId' => afterId, 'fetch' => fetch }, AccessLevel.USER_MODE);
            Boolean more = rows.size() > count;
            if (more) rows.remove(rows.size() - 1);
            List<Object> items = new List<Object>();
            for (Atlas_Library__c row : rows) items.add(summary(row));
            return JSON.serialize(new Map<String, Object>{ 'items' => items, 'hasMore' => more,
                'nextCursor' => more ? String.valueOf(rows[rows.size() - 1].Id) : null, 'maxJsonBytes' => MAX_JSON_BYTES });
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static Atlas_Library__c entry(Id recordId) {
        access(false, false);
        return [SELECT Id, Name, Kind__c, Revision__c, Data_File__c, LastModifiedDate
            FROM Atlas_Library__c WHERE Id = :recordId WITH USER_MODE];
    }

    static ContentVersion version(Id versionId) {
        ContentVersion metadata = [SELECT Id, ContentDocumentId, ContentSize FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
        if (metadata.ContentSize > MAX_JSON_BYTES) throw new Atlas_Api.AtlasException('Stored JSON exceeds the 1,000,000-byte load limit. Download its Salesforce File instead.');
        return [SELECT Id, ContentDocumentId, VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
    }

    @AuraEnabled
    public static String loadEntry(Id recordId) {
        try {
            Atlas_Library__c row = entry(recordId);
            Map<String, Object> result = summary(row);
            result.put('dataJson', version((Id) row.Data_File__c).VersionData.toString());
            return JSON.serialize(result);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    /** A new record expects revision 0; an update must supply the exact loaded revision. */
    @AuraEnabled
    public static String saveEntry(Id recordId, String title, String kind, Integer expectedRevision, String dataJson) {
        Savepoint beforeSave = Database.setSavepoint();
        try {
            Boolean creating = recordId == null;
            access(true, creating);
            if (String.isBlank(title) || title.length() > 80) throw new Atlas_Api.AtlasException('Enter a title of 1–80 characters.');
            if (!KINDS.contains(kind)) throw new Atlas_Api.AtlasException('Unknown library kind.');
            if (dataJson == null || dataJson.length() > MAX_JSON_BYTES) throw new Atlas_Api.AtlasException('JSON exceeds the 1,000,000-byte limit. Nothing was saved; split the data explicitly.');
            Blob bytes = Blob.valueOf(dataJson);
            if (bytes.size() > MAX_JSON_BYTES) throw new Atlas_Api.AtlasException('JSON exceeds the 1,000,000-byte UTF-8 limit. Nothing was saved.');
            JSONParser parser = JSON.createParser(dataJson);
            if (parser.nextToken() != JSONToken.START_OBJECT) throw new Atlas_Api.AtlasException('Library JSON must be an object.');
            Integer depth = 1;
            while (true) {
                JSONToken token = parser.nextToken();
                if (token == null) break;
                if (depth == 0) throw new Atlas_Api.AtlasException('Library JSON must contain exactly one object.');
                if (token == JSONToken.START_OBJECT || token == JSONToken.START_ARRAY) depth++;
                if (token == JSONToken.END_OBJECT || token == JSONToken.END_ARRAY) depth--;
            }
            if (depth != 0) throw new Atlas_Api.AtlasException('Incomplete library JSON.');
            Atlas_Library__c row;
            Id documentId;
            Integer revision = 0;
            if (creating) {
                if (expectedRevision != 0) throw new Atlas_Api.AtlasException('New library entries require revision 0.');
                row = new Atlas_Library__c(Name = title, Kind__c = kind, Revision__c = 0);
                insert as user row;
            } else {
                row = [SELECT Id, Name, Kind__c, Revision__c, Data_File__c FROM Atlas_Library__c WHERE Id = :recordId WITH USER_MODE FOR UPDATE];
                revision = row.Revision__c == null ? 0 : row.Revision__c.intValue();
                if (expectedRevision == null || revision != expectedRevision) {
                    if (expectedRevision != null && revision == expectedRevision + 1 && row.Name.equals(title) && row.Kind__c == kind && row.Data_File__c != null &&
                        Atlas_Api.sha256(version((Id)row.Data_File__c).VersionData) == Atlas_Api.sha256(bytes)) {
                        String replay = JSON.serialize(summary(entry(row.Id)));
                        Database.releaseSavepoint(beforeSave);
                        return replay;
                    }
                    throw new Atlas_Api.AtlasException('Library revision conflict. Your edits are still on screen. Export them, then reload before merging.');
                }
                if (row.Kind__c != kind) throw new Atlas_Api.AtlasException('An existing entry cannot change library kind.');
                if (row.Data_File__c != null) documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :row.Data_File__c WITH USER_MODE].ContentDocumentId;
            }
            ContentVersion file = new ContentVersion(Title = 'Atlas ' + title, PathOnClient = 'atlas-library.json', VersionData = bytes);
            if (documentId == null) file.FirstPublishLocationId = row.Id;
            else file.ContentDocumentId = documentId;
            insert as user file;
            row.Name = title;
            row.Data_File__c = file.Id;
            row.Revision__c = revision + 1;
            update as user row;
            String result = JSON.serialize(summary(entry(row.Id)));
            Database.releaseSavepoint(beforeSave);
            return result;
        } catch (Exception e) {
            Database.rollback(beforeSave);
            Database.releaseSavepoint(beforeSave);
            throw Atlas_Api.fail(e);
        }
    }

    /** Idempotent, additive recovery. A reservation is hidden until its complete body commits. */
    @AuraEnabled
    public static String reserveRecovery(String recoveryKey, String title, String kind) {
        try {
            access(true, true);
            if (String.isBlank(recoveryKey) || recoveryKey.length() > 200 || String.isBlank(title) || title.length() > 80 || !KINDS.contains(kind))
                throw new Atlas_Api.AtlasException('Choose a recovery identity, title and library kind.');
            String key = Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId() + ':' + recoveryKey));
            List<Atlas_Library__c> existing = [SELECT Id FROM Atlas_Library__c WHERE Recovery_Key__c = :key WITH USER_MODE];
            if (!existing.isEmpty()) return JSON.serialize(summary(entry(existing[0].Id)));
            Atlas_Library__c row = new Atlas_Library__c(Name=title, Kind__c=kind, Revision__c=0, Recovery_Key__c=key);
            insert as user row;
            return JSON.serialize(summary(entry(row.Id)));
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    /** Large archives use immutable chunks so no request assembles a workspace in Apex heap. */
    @AuraEnabled
    public static String beginUpload(Id recordId, String title, String kind, Integer expectedRevision, Integer chars, Integer bytes, Integer count) {
        try {
            access(true, recordId == null);
            if (String.isBlank(title) || title.length() > 80 || !KINDS.contains(kind)) throw new Atlas_Api.AtlasException('Choose a library title and kind.');
            if (chars == null || chars < 2 || chars > 104857600 || bytes == null || bytes < chars || bytes > 104857600 || count == null || count < 1 || count > 600)
                throw new Atlas_Api.AtlasException('Workspace limit is 100 MiB in at most 600 chunks.');
            if (recordId != null) {
                Atlas_Library__c target = entry(recordId);
                if (target.Revision__c != expectedRevision || target.Kind__c != kind) throw new Atlas_Api.AtlasException('Library revision conflict. Reload before merging.');
            } else if (expectedRevision != 0) throw new Atlas_Api.AtlasException('A new library starts at revision 0.');
            Atlas_Library__c stage = new Atlas_Library__c(Name = 'Atlas pending archive', Kind__c = 'upload', Revision__c = 0);
            insert as user stage;
            Map<String,Object> data = new Map<String,Object>{'type' => 'atlas-chunked', 'target' => recordId, 'title' => title, 'kind' => kind,
                'expectedRevision' => expectedRevision, 'chars' => chars, 'bytes' => bytes, 'count' => count, 'parts' => new Map<String,Object>()};
            ContentVersion file = new ContentVersion(Title = 'Atlas archive upload', PathOnClient = 'manifest.json', VersionData = Blob.valueOf(JSON.serialize(data)), FirstPublishLocationId = stage.Id);
            insert as user file;
            stage.Data_File__c = file.Id;
            update as user stage;
            return stage.Id;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    static Atlas_Library__c upload(Id uploadId) {
        access(true, false);
        Atlas_Library__c stage = [SELECT Id, OwnerId, Kind__c, Data_File__c FROM Atlas_Library__c WHERE Id = :uploadId WITH USER_MODE FOR UPDATE];
        if (stage.OwnerId != UserInfo.getUserId() || stage.Kind__c != 'upload') throw new Atlas_Api.AtlasException('This is not your pending upload.');
        return stage;
    }

    @AuraEnabled
    public static void writePart(Id uploadId, Integer index, String text) {
        try {
            Atlas_Library__c stage = upload(uploadId);
            ContentVersion current = version((Id)stage.Data_File__c);
            Map<String,Object> manifest = (Map<String,Object>)JSON.deserializeUntyped(current.VersionData.toString());
            if (manifest.get('committed') != null) throw new Atlas_Api.AtlasException('This archive is already committed.');
            if (index == null || index < 0 || index >= Integer.valueOf(manifest.get('count')) || text == null || text.length() > 200000)
                throw new Atlas_Api.AtlasException('Invalid archive chunk.');
            Map<String,Object> parts = (Map<String,Object>)manifest.get('parts');
            String key = String.valueOf(index), hash = Atlas_Api.sha256(Blob.valueOf(text));
            if (parts.containsKey(key)) {
                if (((Map<String,Object>)parts.get(key)).get('sha256') != hash) throw new Atlas_Api.AtlasException('A stored chunk cannot change. Restart this upload.');
                return;
            }
            Blob bytes = Blob.valueOf(text);
            ContentVersion part = new ContentVersion(Title = 'Atlas archive chunk ' + index, PathOnClient = 'chunk.txt', VersionData = bytes, FirstPublishLocationId = stage.Id);
            insert as user part;
            parts.put(key, new Map<String,Object>{'id' => part.Id, 'sha256' => hash, 'chars' => text.length(), 'bytes' => bytes.size()});
            ContentVersion next = new ContentVersion(Title = 'Atlas archive upload', PathOnClient = 'manifest.json', VersionData = Blob.valueOf(JSON.serialize(manifest)), ContentDocumentId = current.ContentDocumentId);
            insert as user next;
            stage.Data_File__c = next.Id;
            update as user stage;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String commitUpload(Id uploadId) {
        try {
            Atlas_Library__c stage = upload(uploadId);
            ContentVersion current = version((Id)stage.Data_File__c);
            Map<String,Object> manifest = (Map<String,Object>)JSON.deserializeUntyped(current.VersionData.toString());
            if (manifest.get('committed') != null) return JSON.serialize(summary(entry((Id)manifest.get('committed'))));
            Map<String,Object> parts = (Map<String,Object>)manifest.get('parts');
            Integer chars = 0, bytes = 0, count = Integer.valueOf(manifest.get('count'));
            if (parts.size() != count) throw new Atlas_Api.AtlasException('Archive is incomplete; no library entry was changed.');
            for (Integer i = 0; i < count; i++) {
                Map<String,Object> part = (Map<String,Object>)parts.get(String.valueOf(i));
                if (part == null) throw new Atlas_Api.AtlasException('Archive is missing a chunk.');
                chars += Integer.valueOf(part.get('chars')); bytes += Integer.valueOf(part.get('bytes'));
            }
            if (chars != Integer.valueOf(manifest.get('chars')) || bytes != Integer.valueOf(manifest.get('bytes')))
                throw new Atlas_Api.AtlasException('Archive size verification failed; nothing was replaced.');
            Id targetId = (Id)manifest.get('target');
            Atlas_Library__c target;
            Id documentId;
            if (targetId == null) {
                target = new Atlas_Library__c(Name = (String)manifest.get('title'), Kind__c = (String)manifest.get('kind'), Revision__c = 0);
                insert as user target;
            } else {
                target = [SELECT Id, Name, Kind__c, Revision__c, Data_File__c FROM Atlas_Library__c WHERE Id = :targetId WITH USER_MODE FOR UPDATE];
                if (target.Revision__c != (Decimal)manifest.get('expectedRevision')) throw new Atlas_Api.AtlasException('Library revision conflict. Archive staging is preserved; reload and merge.');
                if (target.Data_File__c != null) documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :target.Data_File__c WITH USER_MODE].ContentDocumentId;
            }
            ContentVersion archive = new ContentVersion(Title = 'Atlas ' + manifest.get('title'), PathOnClient = 'atlas-library.json', VersionData = Blob.valueOf(JSON.serialize(manifest)));
            if (documentId == null) archive.FirstPublishLocationId = target.Id;
            else archive.ContentDocumentId = documentId;
            insert as user archive;
            target.Data_File__c = archive.Id; target.Name = (String)manifest.get('title'); target.Revision__c += 1;
            update as user target;
            manifest.put('committed', target.Id);
            ContentVersion receipt = new ContentVersion(Title = 'Atlas archive upload receipt', PathOnClient = 'manifest.json', VersionData = Blob.valueOf(JSON.serialize(manifest)), ContentDocumentId = current.ContentDocumentId);
            insert as user receipt;
            stage.Data_File__c = receipt.Id; update as user stage;
            return JSON.serialize(summary(entry(target.Id)));
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String readPart(Id recordId, Id versionId, Integer index) {
        try {
            Map<String,Object> historical = (Map<String,Object>)JSON.deserializeUntyped(loadVersion(recordId, versionId));
            Map<String,Object> manifest = (Map<String,Object>)JSON.deserializeUntyped((String)historical.get('dataJson'));
            Map<String,Object> part = (Map<String,Object>)((Map<String,Object>)manifest.get('parts')).get(String.valueOf(index));
            if (manifest.get('type') != 'atlas-chunked' || part == null) throw new Atlas_Api.AtlasException('Invalid archive chunk.');
            Id partId = (Id)part.get('id');
            Blob data = version(partId).VersionData;
            if (Atlas_Api.sha256(data) != part.get('sha256')) throw new Atlas_Api.AtlasException('Archive integrity check failed.');
            return data.toString();
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String listVersions(Id recordId, String cursor, Integer pageSize) {
        try {
            Atlas_Library__c row = entry(recordId);
            Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :row.Data_File__c WITH USER_MODE].ContentDocumentId;
            Id afterId = cursorId(cursor, ContentVersion.SObjectType);
            Integer count = pageLimit(pageSize), fetch = count + 1;
            String query = 'SELECT Id, VersionNumber, CreatedDate, ContentSize FROM ContentVersion WHERE ContentDocumentId = :documentId';
            if (afterId != null) query += ' AND Id > :afterId';
            List<ContentVersion> rows = Database.queryWithBinds(query + ' ORDER BY Id LIMIT :fetch',
                new Map<String, Object>{ 'documentId' => documentId, 'afterId' => afterId, 'fetch' => fetch }, AccessLevel.USER_MODE);
            Boolean more = rows.size() > count;
            if (more) rows.remove(rows.size() - 1);
            List<Object> items = new List<Object>();
            for (ContentVersion v : rows) items.add(new Map<String, Object>{ 'id' => v.Id, 'number' => v.VersionNumber, 'created' => v.CreatedDate, 'bytes' => v.ContentSize });
            return JSON.serialize(new Map<String, Object>{ 'items' => items, 'hasMore' => more,
                'nextCursor' => more ? String.valueOf(rows[rows.size() - 1].Id) : null });
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    @AuraEnabled
    public static String loadVersion(Id recordId, Id versionId) {
        try {
            Atlas_Library__c row = entry(recordId);
            Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :row.Data_File__c WITH USER_MODE].ContentDocumentId;
            ContentVersion historical = version(versionId);
            if (historical.ContentDocumentId != documentId) throw new Atlas_Api.AtlasException('That version does not belong to this library entry.');
            Map<String, Object> result = summary(row);
            result.put('dataJson', historical.VersionData.toString());
            result.put('loadedVersionId', versionId);
            return JSON.serialize(result);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
}
