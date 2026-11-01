@IsTest
private class Atlas_LibraryTest {
    static Map<String, Object> parsed(String raw) { return (Map<String, Object>) JSON.deserializeUntyped(raw); }
    static Map<String, Object> create(String kind, String title, String raw) {
        return parsed(Atlas_Library.saveEntry(null, title, kind, 0, raw));
    }
    static void rejectsSave(Id recordId, String title, String kind, Integer revision, String raw, String expected) {
        try {
            Atlas_Library.saveEntry(recordId, title, kind, revision, raw);
            System.assert(false, 'Expected save rejection');
        } catch (AuraHandledException e) { System.assert(e.getMessage().contains(expected), e.getMessage()); }
    }

    @IsTest
    static void newSmallEntryReservationAndCommitReplayExactlyOnce() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String raw = '{ "future":900719925474099312345, "text":"Exact" }';
            Map<String,Object> first = parsed(Atlas_Library.reserveRecovery('create:new-small-entry', 'New entry', 'notebook'));
            // The reservation committed but its response was lost. The original identity survives reload.
            Map<String,Object> reserved = parsed(Atlas_Library.reserveRecovery('create:new-small-entry', 'New entry', 'notebook'));
            System.assertEquals(first.get('id'), reserved.get('id'));
            Id id = (Id)reserved.get('id');
            Map<String,Object> saved = parsed(Atlas_Library.saveEntry(id, 'New entry', 'notebook', 0, raw));
            // The body committed but its response was lost. Reserve again, never replace revision 0 with 1.
            Map<String,Object> retry = parsed(Atlas_Library.reserveRecovery('create:new-small-entry', 'New entry', 'notebook'));
            System.assertEquals(id, retry.get('id'));
            Map<String,Object> replay = parsed(Atlas_Library.saveEntry(id, 'New entry', 'notebook', 0, raw));
            System.assertEquals(saved, replay);
            System.assertEquals(1, [SELECT COUNT() FROM Atlas_Library__c]);
            System.assertEquals(1, [SELECT COUNT() FROM ContentVersion]);
            rejectsSave(id, 'New entry', 'notebook', 0, raw.replace('Exact', 'exact'), 'revision conflict');
            rejectsSave(id, 'new entry', 'notebook', 0, raw, 'revision conflict');
            rejectsSave(id, 'New entry', 'draft', 0, raw, 'revision conflict');
            Map<String,Object> distinct = parsed(Atlas_Library.reserveRecovery('create:intentionally-distinct', 'New entry', 'notebook'));
            System.assertNotEquals(id, distinct.get('id'), 'Equal content is not a creation identity');
            Atlas_Library.saveEntry((Id)distinct.get('id'), 'New entry', 'notebook', 0, raw);
            System.assertEquals(2, [SELECT COUNT() FROM ContentVersion]);
            Atlas_Library.saveEntry(id, 'New entry', 'notebook', 1, '{"newer":true}');
            rejectsSave(id, 'New entry', 'notebook', 0, raw, 'revision conflict');
            System.assertEquals('{"newer":true}', parsed(Atlas_Library.loadEntry(id)).get('dataJson'));
        }
    }

    @IsTest
    static void recoveryReservationsSurviveRetriesWithoutOverwritingEdits() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> reserved = parsed(Atlas_Library.reserveRecovery('archive:item:1','Recovered notes','notebook'));
            Id id = (Id)reserved.get('id');
            System.assertEquals(0,reserved.get('revision'));
            System.assertEquals(id,parsed(Atlas_Library.reserveRecovery('archive:item:1','Recovered notes','notebook')).get('id'));
            System.assertEquals(0,((List<Object>)parsed(Atlas_Library.listEntries(null,null,null,50)).get('items')).size());
            Atlas_Library.saveEntry(id,'Recovered notes','notebook',0,'{"original":900719925474099312345}');
            Atlas_Library.saveEntry(id,'Edited recovery','notebook',1,'{"newer":true}');
            Map<String,Object> replay=parsed(Atlas_Library.reserveRecovery('archive:item:1','Recovered notes','notebook'));
            System.assertEquals(id,replay.get('id'));
            System.assertEquals(2,replay.get('revision'));
            System.assertNotEquals(null,replay.get('versionId'));
            System.assertEquals('{"newer":true}',parsed(Atlas_Library.loadEntry(id)).get('dataJson'));
            Map<String,Object> large=parsed(Atlas_Library.reserveRecovery('archive:item:2','Recovered archive','workspace'));
            Id upload=Atlas_Library.beginUpload((Id)large.get('id'),'Recovered archive','workspace',0,2,2,1);
            Atlas_Library.writePart(upload,0,'{}');
            System.assertEquals(large.get('id'),parsed(Atlas_Library.commitUpload(upload)).get('id'));
            System.assertEquals(2,((List<Object>)parsed(Atlas_Library.listEntries(null,null,null,50)).get('items')).size());
        }
    }

    @IsTest
    static void chunkedArchivesCommitOnlyWhenCompleteAndReplaySafely() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String text = 'é'.repeat(190000);
            Id upload = Atlas_Library.beginUpload(null, 'Large archive', 'workspace', 0, text.length() * 6, Blob.valueOf(text).size() * 6, 6);
            try { Atlas_Library.commitUpload(upload); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('incomplete')); }
            System.assertEquals(0, ((List<Object>)parsed(Atlas_Library.listEntries(null,null,null,50)).get('items')).size());
            for (Integer i=0; i<6; i++) Atlas_Library.writePart(upload, i, text);
            Atlas_Library.writePart(upload, 0, text);
            try { Atlas_Library.writePart(upload, 0, 'different'); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('cannot change')); }
            Map<String,Object> saved = parsed(Atlas_Library.commitUpload(upload));
            System.assertEquals(saved.get('id'), parsed(Atlas_Library.commitUpload(upload)).get('id'));
            System.assertEquals(text, Atlas_Library.readPart((Id)saved.get('id'), (Id)saved.get('versionId'), 5));
            System.assertEquals(1, ((List<Object>)parsed(Atlas_Library.listEntries(null,null,null,50)).get('items')).size());
            try { Atlas_Library.writePart(upload, 0, text); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('committed')); }
        }
    }

    @IsTest
    static void chunkedUpdatesKeepHistoryAndRejectChangedTargets() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> original = create('workspace', 'Original', '{"unknown":900719925474099312345}');
            Id id = (Id)original.get('id');
            Id upload = Atlas_Library.beginUpload(id, 'Updated', 'workspace', 1, 2, 2, 1);
            Atlas_Library.writePart(upload, 0, '{}');
            Map<String,Object> saved = parsed(Atlas_Library.commitUpload(upload));
            System.assertEquals(2, saved.get('revision'));
            System.assertEquals('{}', Atlas_Library.readPart(id,(Id)saved.get('versionId'),0));
            System.assertEquals('{"unknown":900719925474099312345}',parsed(Atlas_Library.loadVersion(id,(Id)original.get('versionId'))).get('dataJson'));
            Id stale = Atlas_Library.beginUpload(id, 'Stale', 'workspace', 2, 2, 2, 1);
            Atlas_Library.writePart(stale, 0, '{}');
            Atlas_Library.saveEntry(id,'Latest','workspace',2,'{"latest":true}');
            try { Atlas_Library.commitUpload(stale); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('revision conflict')); }
            System.assertEquals('{"latest":true}',parsed(Atlas_Library.loadEntry(id)).get('dataJson'));
            try { Atlas_Library.beginUpload(id,'Wrong','workspace',1,2,2,1); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('revision conflict')); }
            Id wrongSize = Atlas_Library.beginUpload(null,'Wrong size','workspace',0,3,3,1);
            Atlas_Library.writePart(wrongSize,0,'{}');
            try { Atlas_Library.commitUpload(wrongSize); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('size verification')); }
        }
    }

    @IsTest
    static void retainsExactUnknownJsonAndLongTextInFiles() {
        System.runAs(Atlas_Mock.atlasUser()) {
            String raw = '{ "notes": "' + 'x'.repeat(150000) + 'END", "future": {"number":900719925474099312345}, "taskAtlas":{"items":[]}}';
            Map<String, Object> saved = create('workspace', 'Legacy backup', raw);
            Id recordId = (Id) saved.get('id');
            Map<String, Object> loaded = parsed(Atlas_Library.loadEntry(recordId));
            System.assertEquals(raw, loaded.get('dataJson'));
            System.assertEquals(1, loaded.get('revision'));
            Id versionId = (Id) loaded.get('versionId');
            ContentVersion version = [SELECT VersionData, ContentDocumentId FROM ContentVersion WHERE Id = :versionId];
            System.assertEquals(raw, version.VersionData.toString());
            System.assertEquals(1, [SELECT count() FROM ContentDocumentLink WHERE LinkedEntityId = :recordId AND ContentDocumentId = :version.ContentDocumentId]);
        }
    }

    @IsTest
    static void optimisticLocksRejectStaleSavesAndRetainEveryVersion() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> first = create('notebook', 'Notes', '{"notes":{"A.cls":{"notes":"first"}},"future":true}');
            Id recordId = (Id) first.get('id'), firstVersion = (Id) first.get('versionId');
            Map<String, Object> second = parsed(Atlas_Library.saveEntry(recordId, 'Notes updated', 'notebook', 1, '{"projectNotes":"second"}'));
            System.assertEquals(2, second.get('revision'));
            rejectsSave(recordId, 'Stale', 'notebook', 1, '{"projectNotes":"lost update"}', 'revision conflict');
            System.assertEquals('{"projectNotes":"second"}', parsed(Atlas_Library.loadEntry(recordId)).get('dataJson'));
            Map<String, Object> old = parsed(Atlas_Library.loadVersion(recordId, firstVersion));
            System.assertEquals(2, old.get('revision'), 'Historical loads must keep the current optimistic revision');
            System.assertEquals('{"notes":{"A.cls":{"notes":"first"}},"future":true}', old.get('dataJson'));
            Map<String, Object> page = parsed(Atlas_Library.listVersions(recordId, null, 1));
            System.assertEquals(true, page.get('hasMore'));
            System.assertEquals(1, ((List<Object>) page.get('items')).size());
            Map<String, Object> next = parsed(Atlas_Library.listVersions(recordId, (String) page.get('nextCursor'), 1));
            System.assertEquals(false, next.get('hasMore'));
            System.assertEquals(1, ((List<Object>) next.get('items')).size());
            System.assertEquals(2, [SELECT count() FROM ContentVersion WHERE Title LIKE 'Atlas Notes%']);
        }
    }

    @IsTest
    static void exactSaveRetriesReuseTheVersionButNeverOverwriteLaterEdits() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String,Object> first = create('draft', 'Retry draft', '{"initial":true}');
            Id id = (Id)first.get('id');
            String raw = '{ "future":900719925474099312345, "draft":"exact" }';
            Map<String,Object> saved = parsed(Atlas_Library.saveEntry(id, 'Retry draft', 'draft', 1, raw));
            Map<String,Object> replay = parsed(Atlas_Library.saveEntry(id, 'Retry draft', 'draft', 1, raw));
            System.assertEquals(saved, replay);
            System.assertEquals(2, [SELECT count() FROM ContentVersion]);
            rejectsSave(id, 'Different title', 'draft', 1, raw, 'revision conflict');
            rejectsSave(id, 'Retry draft', 'draft', 1, '{"different":true}', 'revision conflict');
            Atlas_Library.saveEntry(id, 'Later edit', 'draft', 2, '{"later":true}');
            rejectsSave(id, 'Retry draft', 'draft', 1, raw, 'revision conflict');
            System.assertEquals('{"later":true}', parsed(Atlas_Library.loadEntry(id)).get('dataJson'));
            System.assertEquals(3, [SELECT count() FROM ContentVersion]);
        }
    }

    @IsTest
    static void pagesDocumentsNotebooksWorkspacesAndDraftsWithoutBodies() {
        System.runAs(Atlas_Mock.atlasUser()) {
            for (String kind : new List<String>{ 'document', 'notebook', 'workspace', 'draft' }) create(kind, kind + ' title', '{"unknown":"kept"}');
            Set<String> seen = new Set<String>();
            String cursor;
            for (Integer pageNumber = 0; pageNumber < 4; pageNumber++) {
                Map<String, Object> page = parsed(Atlas_Library.listEntries(null, null, cursor, 1));
                List<Object> items = (List<Object>) page.get('items');
                System.assertEquals(1, items.size());
                Map<String, Object> item = (Map<String, Object>) items[0];
                System.assert(!item.containsKey('dataJson'));
                System.assert(!seen.contains((String) item.get('id')));
                if (pageNumber == 0) System.assertEquals('draft title', item.get('title'), 'Newest entry is listed first');
                seen.add((String) item.get('id'));
                cursor = (String) page.get('nextCursor');
                System.assertEquals(pageNumber < 3, page.get('hasMore'));
            }
            System.assertEquals(null, cursor);
            Map<String, Object> drafts = parsed(Atlas_Library.listEntries('draft', 'title', null, 50));
            System.assertEquals(1, ((List<Object>) drafts.get('items')).size());
            System.assertEquals(0, ((List<Object>) parsed(Atlas_Library.listEntries(null, '%', null, 50)).get('items')).size(), 'Search wildcard must be literal');
        }
    }

    @IsTest
    static void rejectsOversizeInvalidJsonKindsTitlesAndForeignVersions() {
        System.runAs(Atlas_Mock.atlasUser()) {
            rejectsSave(null, 'Bad', 'draft', 0, '[]', 'object');
            rejectsSave(null, 'Bad', 'draft', 0, '{"x":', '');
            rejectsSave(null, 'Bad', 'draft', 1, '{}', 'revision 0');
            rejectsSave(null, 'Bad', 'unknown', 0, '{}', 'Unknown');
            rejectsSave(null, '', 'draft', 0, '{}', 'title');
            rejectsSave(null, 'x'.repeat(81), 'draft', 0, '{}', '80');
            rejectsSave(null, 'Large', 'draft', 0, '{"text":"' + 'x'.repeat(1000000) + '"}', '1,000,000');
            rejectsSave(null, 'Unicode', 'draft', 0, '{"text":"' + 'é'.repeat(500001) + '"}', 'UTF-8');
            System.assertEquals(0, [SELECT count() FROM Atlas_Library__c], 'Rejected saves leave no empty records');
            Map<String, Object> first = create('draft', 'First', '{"request":"unfinished","paste":"keep"}');
            Map<String, Object> other = create('workspace', 'Other', '{"unknown":true}');
            rejectsSave((Id) first.get('id'), 'First', 'document', 1, '{}', 'cannot change');
            try {
                Atlas_Library.loadVersion((Id) first.get('id'), (Id) other.get('versionId'));
                System.assert(false, 'Expected foreign version rejection');
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('does not belong')); }
            for (Integer size : new List<Integer>{ 0, 51 }) {
                try {
                    Atlas_Library.listEntries(null, null, null, size);
                    System.assert(false);
                } catch (AuraHandledException e) { System.assert(e.getMessage().contains('1–50')); }
            }
            try {
                Atlas_Library.listEntries(null, null, UserInfo.getUserId(), 10);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('cursor')); }
            try {
                Atlas_Library.listEntries('unknown', '', null, 10);
                System.assert(false);
            } catch (AuraHandledException e) { System.assert(e.getMessage().contains('Unknown')); }
        }
    }
}
