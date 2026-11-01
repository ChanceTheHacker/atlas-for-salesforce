/** Accessible native workspace reads. Sharing and field access apply; no arbitrary object access. */
public with sharing class Atlas_Workspace {
    public static final Integer MAX_FILE_BYTES = 1500000;
    public static final Integer MAX_RECORD_BYTES = 1000000;
    public static final Map<String, Schema.SObjectType> TYPES = new Map<String, Schema.SObjectType>{
        'Atlas_Conversation__c' => Atlas_Conversation__c.SObjectType,
        'Atlas_Message__c' => Atlas_Message__c.SObjectType,
        'Atlas_Ticket__c' => Atlas_Ticket__c.SObjectType,
        'Atlas_Person__c' => Atlas_Person__c.SObjectType,
        'Atlas_Setting__c' => Atlas_Setting__c.SObjectType,
        'Atlas_Change__c' => Atlas_Change__c.SObjectType,
        'Atlas_Library__c' => Atlas_Library__c.SObjectType
    };
    public class WorkspaceException extends Exception {}

    public static void require(Boolean condition, String message) {
        if (!condition) throw new WorkspaceException(message);
    }
    public static String digest(Blob bytes) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', bytes)).toLowerCase();
    }
    public static Object portableScalar(Object value) {
        if (value instanceof Decimal || value instanceof Double || value instanceof Integer || value instanceof Long) return String.valueOf(value);
        return value;
    }
    public static Schema.SObjectType objectType(String kind) {
        require(TYPES.containsKey(kind), 'Only the seven native Atlas object types are supported.');
        Schema.SObjectType result = TYPES.get(kind);
        require(result.getDescribe().isAccessible(), 'Read access is missing for ' + kind + '.');
        return result;
    }
    public static Map<String, Schema.SObjectField> fields(String kind) {
        Map<String, Schema.SObjectField> result = new Map<String, Schema.SObjectField>();
        for (Schema.SObjectField field : objectType(kind).getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult info = field.getDescribe();
            String local = info.getLocalName();
            if (info.isCustom() || new Set<String>{'Id', 'Name', 'OwnerId', 'CreatedById', 'CreatedDate',
                'LastModifiedById', 'LastModifiedDate', 'SystemModstamp'}.contains(local)) result.put(local, field);
        }
        return result;
    }
    public static String fieldName(String kind, String local) {
        Schema.SObjectField field = fields(kind).get(local);
        require(field != null, 'Unknown Atlas field: ' + local);
        return field.getDescribe().getName();
    }
    static Id cursorId(String cursor, Schema.SObjectType expected) {
        if (String.isBlank(cursor)) return null;
        Id value = (Id)cursor;
        require(value.getSObjectType() == expected, 'Wrong keyset cursor type.');
        return value;
    }
    static void cutoffCheck(Datetime cutoff) {
        require(cutoff != null && cutoff <= System.now().addMinutes(1), 'An export cutoff is required.');
    }
    static Map<String, Object> page(List<SObject> rows, Integer count) {
        Boolean more = rows.size() > count;
        if (more) rows.remove(rows.size() - 1);
        return new Map<String, Object>{'items' => rows, 'hasMore' => more,
            'nextCursor' => more ? rows[rows.size() - 1].get('Id') : null};
    }
    static Map<String, Object> schema(String kind) {
        Map<String, Object> readable = new Map<String, Object>();
        List<String> omitted = new List<String>();
        Map<String, Schema.SObjectField> descriptions = fields(kind);
        for (String key : descriptions.keySet()) {
            Schema.DescribeFieldResult field = descriptions.get(key).getDescribe();
            if (!field.isAccessible()) { omitted.add(key); continue; }
            List<String> references = new List<String>();
            for (Schema.SObjectType ref : field.getReferenceTo()) references.add(ref.getDescribe().getLocalName());
            readable.put(key, new Map<String, Object>{'type' => String.valueOf(field.getType()), 'references' => references,
                'createable' => field.isCreateable(), 'unique' => field.isUnique(), 'length' => field.getLength()});
        }
        return new Map<String, Object>{'fields' => readable, 'inaccessibleFields' => omitted};
    }
    @AuraEnabled
    public static String beginExport() {
        Map<String, Object> schemas = new Map<String, Object>();
        for (String kind : TYPES.keySet()) {
            try { schemas.put(kind, schema(kind)); }
            catch (Exception e) { schemas.put(kind, new Map<String, Object>{'error' => e.getMessage()}); }
        }
        return JSON.serialize(new Map<String, Object>{'schemas' => schemas, 'scope' => new Map<String, Object>{
            'ownership' => 'accessible-records', 'orgId' => UserInfo.getOrganizationId(), 'userId' => UserInfo.getUserId(),
            'cutoff' => System.now(), 'consistency' => 'Two-pass verification, not a transactional point-in-time snapshot.',
            'exclusions' => new List<String>{'Records and fields the current user cannot access', 'Deleted records', 'Unsaved browser state',
                'Salesforce metadata and jobs', 'Legacy HTML workspaces', 'Legacy Attachment, Notes, feeds and sharing grants',
                'Field history other than accessible ticket history'},
            'numberEncoding' => 'Native numeric scalars and numeric history values are decimal strings; JSON text fields remain verbatim.',
            'maxFileBytes' => MAX_FILE_BYTES, 'maxRecordBytes' => MAX_RECORD_BYTES, 'maxArchiveBytes' => 104857600
        }});
    }
    /** Enumerate IDs separately: a page never aggregates long-text record bodies. */
    @AuraEnabled
    public static String recordPage(String kind, String cursor, Datetime cutoff) {
        cutoffCheck(cutoff);
        Schema.SObjectType type = objectType(kind);
        Id afterId = cursorId(cursor, type);
        String query = 'SELECT Id FROM ' + type.getDescribe().getName() + ' WHERE CreatedDate <= :cutoff';
        if (afterId != null) query += ' AND Id > :afterId';
        List<SObject> rows = Database.queryWithBinds(query + ' ORDER BY Id LIMIT 51',
            new Map<String, Object>{'cutoff' => cutoff, 'afterId' => afterId}, AccessLevel.USER_MODE);
        return JSON.serialize(page(rows, 50));
    }
    public static Map<String, Object> readRecord(String kind, Id recordId) {
        Schema.SObjectType type = objectType(kind);
        require(recordId != null && recordId.getSObjectType() == type, 'Wrong Atlas record type.');
        Map<String, Schema.SObjectField> descriptions = fields(kind);
        List<String> keys = new List<String>(descriptions.keySet()), selected = new List<String>();
        keys.sort();
        for (String key : keys) if (descriptions.get(key).getDescribe().isAccessible()) selected.add(descriptions.get(key).getDescribe().getName());
        List<SObject> rows = Database.queryWithBinds('SELECT ' + String.join(selected, ',') + ' FROM ' + type.getDescribe().getName()
            + ' WHERE Id = :recordId', new Map<String, Object>{'recordId' => recordId}, AccessLevel.USER_MODE);
        require(rows.size() == 1, 'Record is missing or inaccessible.');
        Map<String, Object> values = new Map<String, Object>();
        List<Object> canonical = new List<Object>();
        for (String key : keys) if (descriptions.get(key).getDescribe().isAccessible()) {
            Object value = rows[0].get(descriptions.get(key).getDescribe().getName());
            values.put(key, portableScalar(value));
            canonical.add(new List<Object>{key, value});
        }
        String raw = JSON.serialize(values);
        require(Blob.valueOf(raw).size() <= MAX_RECORD_BYTES, 'Record exceeds the 1,000,000-byte record limit; it was NOT truncated.');
        return new Map<String, Object>{'type' => kind, 'id' => recordId, 'values' => values,
            'token' => digest(Blob.valueOf(JSON.serialize(canonical)))};
    }
    @AuraEnabled
    public static String recordBody(String kind, Id recordId) { return JSON.serialize(readRecord(kind, recordId)); }

    @AuraEnabled
    public static String linkPage(String kind, Id recordId, String cursor) {
        readRecord(kind, recordId);
        Id afterId = cursorId(cursor, ContentDocumentLink.SObjectType);
        String query = 'SELECT Id, ContentDocumentId, ShareType, Visibility FROM ContentDocumentLink WHERE LinkedEntityId = :recordId';
        if (afterId != null) query += ' AND Id > :afterId';
        List<SObject> rows = Database.queryWithBinds(query + ' ORDER BY Id LIMIT 51',
            new Map<String, Object>{'recordId' => recordId, 'afterId' => afterId}, AccessLevel.USER_MODE);
        return JSON.serialize(page(rows, 50));
    }
    @AuraEnabled
    public static String versionPage(Id documentId, String cursor, Datetime cutoff) {
        cutoffCheck(cutoff);
        require(documentId != null && documentId.getSObjectType() == ContentDocument.SObjectType, 'Invalid document ID.');
        Id afterId = cursorId(cursor, ContentVersion.SObjectType);
        String query = 'SELECT Id FROM ContentVersion WHERE ContentDocumentId = :documentId AND CreatedDate <= :cutoff';
        if (afterId != null) query += ' AND Id > :afterId';
        List<SObject> rows = Database.queryWithBinds(query + ' ORDER BY Id LIMIT 51',
            new Map<String, Object>{'documentId' => documentId, 'cutoff' => cutoff, 'afterId' => afterId}, AccessLevel.USER_MODE);
        return JSON.serialize(page(rows, 50));
    }
    /** Immutable version IDs only. Size is checked BEFORE loading the Blob. */
    @AuraEnabled
    public static String fileBody(Id versionId) {
        require(versionId != null && versionId.getSObjectType() == ContentVersion.SObjectType, 'An immutable ContentVersion ID is required.');
        ContentVersion meta = [SELECT Id, ContentDocumentId, ContentSize, ContentLocation, Title, PathOnClient, Description,
            VersionNumber, CreatedDate FROM ContentVersion WHERE Id = :versionId WITH USER_MODE];
        require(meta.ContentLocation == 'S', 'External Files are not portable binaries; this archive is incomplete.');
        require(meta.ContentSize <= MAX_FILE_BYTES, 'File exceeds the 1,500,000-byte per-version limit; this archive is incomplete. Download that version separately.');
        Blob bytes = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE].VersionData;
        return JSON.serialize(new Map<String, Object>{'id' => meta.Id, 'documentId' => meta.ContentDocumentId,
            'bytes' => meta.ContentSize, 'title' => meta.Title, 'path' => meta.PathOnClient, 'description' => meta.Description,
            'number' => meta.VersionNumber, 'created' => meta.CreatedDate, 'sha256' => digest(bytes), 'base64' => EncodingUtil.base64Encode(bytes)});
    }
    @AuraEnabled
    public static String historyPage(Id recordId, String cursor, Datetime cutoff) {
        cutoffCheck(cutoff);
        readRecord('Atlas_Ticket__c', recordId);
        Id afterId = cursorId(cursor, Atlas_Ticket__History.SObjectType);
        String query = 'SELECT Id, ParentId, Field, OldValue, NewValue, CreatedById, CreatedDate FROM '
            + Atlas_Ticket__History.SObjectType.getDescribe().getName() + ' WHERE ParentId = :recordId AND CreatedDate <= :cutoff';
        if (afterId != null) query += ' AND Id > :afterId';
        List<SObject> rows = Database.queryWithBinds(query + ' ORDER BY Id LIMIT 51',
            new Map<String, Object>{'recordId' => recordId, 'cutoff' => cutoff, 'afterId' => afterId}, AccessLevel.USER_MODE);
        Map<String, Object> result = page(rows, 50);
        List<Object> items = new List<Object>();
        for (SObject row : rows) {
            Map<String, Object> values = row.getPopulatedFieldsAsMap();
            values.put('OldValue', portableScalar(row.get('OldValue')));
            values.put('NewValue', portableScalar(row.get('NewValue')));
            items.add(values);
        }
        result.put('items', items);
        return JSON.serialize(result);
    }
}
