@IsTest
private class Atlas_WorkspaceTest {
    static Map<String, Object> parsed(String raw) { return (Map<String, Object>)JSON.deserializeUntyped(raw); }
    static Map<String, Object> source(String kind, Map<String, Object> values) {
        return new Map<String, Object>{'type' => kind, 'id' => 'portable-source', 'values' => values,
            'links' => new List<Object>(), 'history' => new List<Object>()};
    }
    static Map<String, Object> archive() {
        return parsed(Atlas_Library.saveEntry(null, 'Atlas native test source', 'workspace', 0,
            '{"type":"atlas-native-workspace","version":1,"future":900719925474099312345}'));
    }
    static Id prepare(Map<String, Object> saved, Map<String, Object> item, Map<String, Object> files, Map<String, Object> references) {
        return (Id)parsed(Atlas_WorkspaceRecovery.prepareRecord((Id)saved.get('id'), (Id)saved.get('versionId'),
            JSON.serialize(item), JSON.serialize(files), JSON.serialize(references))).get('id');
    }
    static Map<String, Object> apply(Map<String, Object> review) {
        return parsed(Atlas_WorkspaceRecovery.applyRecord((Id)review.get('id'), (Id)review.get('versionId'), (String)review.get('digest')));
    }
    static Map<String, Object> fileSpec(String id, String raw, String doc, Integer versionNumber) {
        return new Map<String, Object>{'id' => id, 'documentId' => doc, 'number' => versionNumber, 'title' => 'Atlas original',
            'path' => 'original.txt', 'bytes' => Blob.valueOf(raw).size(), 'sha256' => Atlas_Workspace.digest(Blob.valueOf(raw))};
    }

    @IsTest
    static void keysetScopeAndLongTextAreNotTheUiListCaps() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<Atlas_Conversation__c> rows = new List<Atlas_Conversation__c>();
            for (Integer i = 0; i < 57; i++) rows.add(new Atlas_Conversation__c(Name = 'Atlas workspace ' + i, Mode__c = 'Source'));
            insert rows;
            String body = 'x'.repeat(130000) + 'END';
            rows[0].Request__c = body;
            rows[0].UI_State__c = '{ "future":900719925474099312345 }';
            update rows[0];
            Test.startTest();
            Map<String, Object> start = parsed(Atlas_Workspace.beginExport());
            System.assertEquals('accessible-records', ((Map<String, Object>)start.get('scope')).get('ownership'));
            Map<String, Object> first = parsed(Atlas_Workspace.recordPage('Atlas_Conversation__c', null, System.now()));
            System.assertEquals(50, ((List<Object>)first.get('items')).size());
            System.assertEquals(true, first.get('hasMore'));
            Map<String, Object> next = parsed(Atlas_Workspace.recordPage('Atlas_Conversation__c', (String)first.get('nextCursor'), System.now()));
            System.assertEquals(7, ((List<Object>)next.get('items')).size());
            System.assertEquals(false, next.get('hasMore'));
            Map<String, Object> detail = parsed(Atlas_Workspace.recordBody('Atlas_Conversation__c', rows[0].Id));
            Map<String, Object> values = (Map<String, Object>)detail.get('values');
            System.assertEquals(body, values.get('Request__c'));
            System.assertEquals(rows[0].UI_State__c, values.get('UI_State__c'));
            String token = (String)detail.get('token');
            rows[0].Request__c = 'changed'; update rows[0];
            System.assertNotEquals(token, parsed(Atlas_Workspace.recordBody('Atlas_Conversation__c', rows[0].Id)).get('token'));
            Test.stopTest();
        }
    }

    @IsTest
    static void exportsPinnedBinaryVersionsAndRejectsOversizeBeforeBlobLoad() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c row = new Atlas_Conversation__c(Name = 'Atlas files'); insert row;
            ContentVersion old = new ContentVersion(Title = 'Atlas binary', PathOnClient = 'original.bin',
                VersionData = EncodingUtil.convertFromHex('0001ff80'), FirstPublishLocationId = row.Id); insert old;
            Id doc = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :old.Id].ContentDocumentId;
            ContentVersion current = new ContentVersion(Title = 'Atlas binary', PathOnClient = 'original.bin', VersionData = Blob.valueOf('new'), ContentDocumentId = doc); insert current;
            Test.startTest();
            Map<String, Object> pinned = parsed(Atlas_Workspace.fileBody(old.Id));
            System.assertEquals('0001ff80', EncodingUtil.convertToHex(EncodingUtil.base64Decode((String)pinned.get('base64'))));
            System.assertEquals(old.Id, pinned.get('id'));
            Map<String, Object> versions = parsed(Atlas_Workspace.versionPage(doc, null, System.now()));
            System.assertEquals(2, ((List<Object>)versions.get('items')).size());
            System.assertEquals(1, ((List<Object>)parsed(Atlas_Workspace.linkPage('Atlas_Conversation__c', row.Id, null)).get('items')).size());
            Test.stopTest();
            ContentVersion huge = new ContentVersion(Title = 'Atlas oversized', PathOnClient = 'large.txt', VersionData = Blob.valueOf('x'.repeat(1500001))); insert huge;
            try { Atlas_Workspace.fileBody(huge.Id); System.assert(false, 'Expected explicit size refusal'); }
            catch (Atlas_Workspace.WorkspaceException e) { System.assert(e.getMessage().contains('1,500,000')); }
        }
    }

    @IsTest
    static void additiveRecoveryPreservesUnknownJsonAndReplaysTheSameReceipt() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> saved = archive();
            String raw = '{ "future":900719925474099312345,"unknown":{"value":true}}';
            Map<String, Object> item = source('Atlas_Conversation__c', new Map<String, Object>{'Name' => 'Atlas recovered',
                'Mode__c' => 'Files', 'UI_State__c' => raw, 'Future_Field__c' => 'archive only'});
            Test.startTest();
            Id planId = prepare(saved, item, new Map<String, Object>(), new Map<String, Object>());
            System.assertEquals(0, [SELECT count() FROM Atlas_Conversation__c]);
            Map<String, Object> review = parsed(Atlas_WorkspaceRecovery.reviewRecord(planId));
            System.assertEquals(0, ((List<Object>)review.get('conflicts')).size());
            System.assert(JSON.serialize(review.get('notices')).contains('Future_Field__c'));
            Map<String, Object> receipt = apply(review);
            System.assertEquals(receipt.get('recordId'), apply(review).get('recordId'));
            System.assertEquals(1, [SELECT count() FROM Atlas_Conversation__c]);
            Id id = (Id)receipt.get('recordId');
            System.assertEquals(raw, [SELECT UI_State__c FROM Atlas_Conversation__c WHERE Id = :id].UI_State__c);
            System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Atlas_Library__c WHERE Id = :planId].OwnerId);
            System.assert(Atlas_Library.loadEntry(planId).contains('Future_Field__c'));
            Test.stopTest();
        }
    }

    @IsTest
    static void uniqueIdentityConflictsPreserveBeforeStateAndNeverOverwrite() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Setting__c existing = new Atlas_Setting__c(Name = 'Atlas existing', Key__c = 'workspace-test', Data__c = '{"before":true}'); insert existing;
            Map<String, Object> saved = archive();
            Test.startTest();
            Id planId = prepare(saved, source('Atlas_Setting__c', new Map<String, Object>{'Name' => 'Atlas replacement',
                'Key__c' => 'workspace-test', 'Data__c' => '{"new":true}'}), new Map<String, Object>(), new Map<String, Object>());
            Map<String, Object> review = parsed(Atlas_WorkspaceRecovery.reviewRecord(planId));
            System.assert(!((List<Object>)review.get('conflicts')).isEmpty());
            System.assertEquals(1, ((List<Object>)review.get('before')).size());
            try { apply(review); System.assert(false, 'Existing unique keys must conflict'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('conflicts')); }
            System.assertEquals('{"before":true}', [SELECT Data__c FROM Atlas_Setting__c WHERE Id = :existing.Id].Data__c);
            System.assertEquals(1, [SELECT count() FROM Atlas_Setting__c]);
            Test.stopTest();
        }
    }

    @IsTest
    static void staleReviewsAndConcurrentBeforeStateChangesAreRejected() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c existing = new Atlas_Conversation__c(Name = 'Atlas existing', Request__c = 'before'); insert existing;
            Map<String, Object> saved = archive();
            Map<String, Object> item = parsed(Atlas_Workspace.recordBody('Atlas_Conversation__c', existing.Id));
            Test.startTest();
            Id planId = prepare(saved, item, new Map<String, Object>(), new Map<String, Object>());
            Map<String, Object> first = parsed(Atlas_WorkspaceRecovery.reviewRecord(planId));
            Map<String, Object> latest = parsed(Atlas_WorkspaceRecovery.reviewRecord(planId));
            try { apply(first); System.assert(false, 'Re-reviewed versions invalidate prior approval'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('review changed')); }
            existing.Request__c = 'concurrent edit'; update existing;
            try { apply(latest); System.assert(false, 'Before-state changed'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('Before-state changed')); }
            System.assertEquals(1, [SELECT count() FROM Atlas_Conversation__c]);
            Test.stopTest();
        }
    }

    @IsTest
    static void completeFileBackedBodiesAndOriginalVersionHistoryAreMaterialized() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Atlas_Conversation__c parent = new Atlas_Conversation__c(Name = 'Atlas parent'); insert parent;
            Map<String, Object> saved = archive();
            String old = 'first body', body = 'x'.repeat(140000) + 'END';
            Map<String, Object> specs = new Map<String, Object>{'old' => fileSpec('old', old, 'body-doc', 1), 'current' => fileSpec('current', body, 'body-doc', 2)};
            Test.startTest();
            Id planId = prepare(saved, source('Atlas_Message__c', new Map<String, Object>{'Conversation__c' => 'source-parent',
                'Body__c' => 'preview only', 'Body_File__c' => 'current', 'Direction__c' => 'From Agent', 'Kind__c' => 'chat'}),
                specs, new Map<String, Object>{'source-parent' => parent.Id});
            String first = Atlas_WorkspaceRecovery.stageFile(planId, 'old', EncodingUtil.base64Encode(Blob.valueOf(old)));
            System.assertEquals(parsed(first), parsed(Atlas_WorkspaceRecovery.stageFile(planId, 'old', EncodingUtil.base64Encode(Blob.valueOf(old)))));
            Map<String, Object> current = parsed(Atlas_WorkspaceRecovery.stageFile(planId, 'current', EncodingUtil.base64Encode(Blob.valueOf(body))));
            Map<String, Object> receipt = apply(parsed(Atlas_WorkspaceRecovery.reviewRecord(planId)));
            Id id = (Id)receipt.get('recordId');
            Atlas_Message__c restored = [SELECT Conversation__c, Body_File__c FROM Atlas_Message__c WHERE Id = :id];
            System.assertEquals(parent.Id, restored.Conversation__c);
            System.assertEquals(current.get('id'), restored.Body_File__c);
            System.assertEquals(body, [SELECT VersionData FROM ContentVersion WHERE Id = :restored.Body_File__c].VersionData.toString());
            Id documentId = (Id)current.get('documentId');
            System.assertEquals(2, [SELECT count() FROM ContentVersion WHERE ContentDocumentId = :documentId]);
            System.assertEquals(1, [SELECT count() FROM ContentDocumentLink WHERE LinkedEntityId = :id AND ContentDocumentId = :documentId]);
            Test.stopTest();
        }
    }

    @IsTest
    static void missingReferencesAndTamperedFileBodiesCannotBeApplied() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> saved = archive();
            Test.startTest();
            Id planId = prepare(saved, source('Atlas_Message__c', new Map<String, Object>{'Conversation__c' => 'unmapped',
                'Body_File__c' => 'file', 'Direction__c' => 'To Agent'}), new Map<String, Object>{'file' => fileSpec('file', 'correct', 'doc', 1)}, new Map<String, Object>());
            try { Atlas_WorkspaceRecovery.stageFile(planId, 'file', EncodingUtil.base64Encode(Blob.valueOf('wrong'))); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('integrity')); }
            Map<String, Object> review = parsed(Atlas_WorkspaceRecovery.reviewRecord(planId));
            System.assert(JSON.serialize(review.get('conflicts')).contains('Missing reference mapping'));
            try { apply(review); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('conflicts')); }
            System.assertEquals(0, [SELECT count() FROM Atlas_Message__c]);
            Test.stopTest();
        }
    }

    @IsTest
    static void changeHistoriesKeepJobsInertAndNeverCreateNativeChanges() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> saved = archive();
            Map<String, Object> item = source('Atlas_Change__c', new Map<String, Object>{'Status__c' => 'Deploying',
                'Deploy_Id__c' => '0Af000000000001', 'Components__c' => '{"retrieveId":"old-job","unknown":true}', 'Result__c' => '{"outcomeUnknown":true}'});
            Test.startTest();
            Id planId = prepare(saved, item, new Map<String, Object>(), new Map<String, Object>());
            Map<String, Object> receipt = apply(parsed(Atlas_WorkspaceRecovery.reviewRecord(planId)));
            System.assertEquals('history-only', receipt.get('mode'));
            System.assertEquals(planId, receipt.get('recordId'));
            System.assertEquals(0, [SELECT count() FROM Atlas_Change__c]);
            System.assertEquals(0, Limits.getQueueableJobs());
            System.assertEquals(0, Limits.getCallouts());
            System.assert(Atlas_Library.loadEntry(planId).contains('old-job'));
            Test.stopTest();
        }
    }

    @IsTest
    static void chunkManifestRecoveryRebindsOnlyStorageReferencesAndKeepsLibraryPrivate() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> saved = archive();
            String raw = '{ "unknown":900719925474099312345 }';
            Map<String, Object> part = fileSpec('part', raw, 'part-doc', 1);
            String manifest = JSON.serialize(new Map<String, Object>{'type' => 'atlas-chunked', 'count' => 1, 'bytes' => Blob.valueOf(raw).size(),
                'chars' => raw.length(), 'parts' => new Map<String, Object>{'0' => new Map<String, Object>{'id' => 'part', 'sha256' => part.get('sha256'), 'chars' => raw.length(), 'bytes' => Blob.valueOf(raw).size()}}});
            Test.startTest();
            Id planId = prepare(saved, source('Atlas_Library__c', new Map<String, Object>{'Name' => 'Atlas restored library', 'Kind__c' => 'workspace',
                'Revision__c' => 4, 'Data_File__c' => 'manifest'}), new Map<String, Object>{'part' => part, 'manifest' => fileSpec('manifest', manifest, 'manifest-doc', 1)}, new Map<String, Object>());
            try { Atlas_WorkspaceRecovery.stageFile(planId, 'manifest', EncodingUtil.base64Encode(Blob.valueOf(manifest))); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('dependencies')); }
            Map<String, Object> copiedPart = parsed(Atlas_WorkspaceRecovery.stageFile(planId, 'part', EncodingUtil.base64Encode(Blob.valueOf(raw))));
            Map<String, Object> copiedManifest = parsed(Atlas_WorkspaceRecovery.stageFile(planId, 'manifest', EncodingUtil.base64Encode(Blob.valueOf(manifest))));
            Map<String, Object> receipt = apply(parsed(Atlas_WorkspaceRecovery.reviewRecord(planId)));
            Id id = (Id)receipt.get('recordId'), versionId = (Id)copiedManifest.get('id');
            System.assertEquals(UserInfo.getUserId(), [SELECT OwnerId FROM Atlas_Library__c WHERE Id = :id].OwnerId);
            String restored = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId].VersionData.toString();
            System.assert(restored.contains((String)copiedPart.get('id')));
            System.assertEquals(raw, Atlas_Library.readPart(id, versionId, 0));
            Test.stopTest();
        }
    }

    @IsTest
    static void numericScalarsDoNotRoundThroughJavascriptAndAccessibleSharedRecordsAreIncluded() {
        User tester = Atlas_Mock.atlasUser();
        Atlas_Conversation__c foreign = new Atlas_Conversation__c(Name = 'Atlas foreign');
        insert as system foreign;
        Atlas_Message__c foreignMessage = new Atlas_Message__c(Conversation__c = foreign.Id, Body__c = 'private foreign body');
        insert as system foreignMessage;
        System.runAs(tester) {
            Atlas_Conversation__c own = new Atlas_Conversation__c(Name = 'Atlas own', State_Revision__c = 9007199254740993L);
            insert own;
            Map<String, Object> detail = parsed(Atlas_Workspace.recordBody('Atlas_Conversation__c', own.Id));
            System.assertEquals('9007199254740993', ((Map<String, Object>)detail.get('values')).get('State_Revision__c'));
            Map<String, Object> page = parsed(Atlas_Workspace.recordPage('Atlas_Conversation__c', null, System.now()));
            System.assertEquals(2, ((List<Object>)page.get('items')).size(), 'Accessible records must not disappear from a shared workspace backup');
            System.assertEquals(1, ((List<Object>)parsed(Atlas_Workspace.recordPage('Atlas_Message__c', null, System.now())).get('items')).size());
            System.assertEquals(foreign.Id, parsed(Atlas_Workspace.recordBody('Atlas_Conversation__c', foreign.Id)).get('id'));
        }
    }

    @IsTest
    static void arbitraryObjectsAndCrossTypeCursorsAreRefused() {
        System.runAs(Atlas_Mock.atlasUser()) {
            try { Atlas_Workspace.recordPage('Account', null, System.now()); System.assert(false); }
            catch (Atlas_Workspace.WorkspaceException e) { System.assert(e.getMessage().contains('seven native')); }
            try { Atlas_Workspace.recordPage('Atlas_Person__c', UserInfo.getUserId(), System.now()); System.assert(false); }
            catch (Atlas_Workspace.WorkspaceException e) { System.assert(e.getMessage().contains('cursor')); }
            Map<String, Object> saved = archive();
            try { prepare(saved, source('Account', new Map<String, Object>{'Name' => 'Forbidden'}), new Map<String, Object>(), new Map<String, Object>()); System.assert(false); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('seven native')); }
            System.assertEquals(0, [SELECT count() FROM Account]);
        }
    }

    @IsTest
    static void recoveredPeopleKeepTheirAliasListAndFollowDirectoryRules() {
        System.runAs(Atlas_Mock.atlasUser()) {
            List<String> aliases = new List<String>();
            for (Integer i = 0; i < 30; i++) aliases.add('Recovered alias number ' + i);
            Map<String, Object> saved = archive();
            Test.startTest();
            Map<String, Object> review = parsed(Atlas_WorkspaceRecovery.reviewRecord(prepare(saved, source('Atlas_Person__c', new Map<String, Object>{
                'Name' => 'Atlas Recovered Person', 'Active__c' => true, 'Alias_List__c' => JSON.serialize(aliases)}),
                new Map<String, Object>(), new Map<String, Object>())));
            System.assertEquals(0, ((List<Object>)review.get('conflicts')).size(), JSON.serialize(review.get('conflicts')));
            Id id = (Id)apply(review).get('recordId');
            Atlas_Person__c person = [SELECT Alias_List__c FROM Atlas_Person__c WHERE Id = :id];
            System.assertEquals(aliases, Atlas_Identity.names(person), 'Aliases longer than the legacy field survive recovery.');

            // The same Salesforce user cannot be linked twice, and an active alias cannot point to two people.
            insert new Atlas_Person__c(Name = 'Atlas Linked', User__c = UserInfo.getUserId(), Active__c = true);
            Map<String, Object> users = parsed(Atlas_WorkspaceRecovery.reviewRecord(prepare(saved, source('Atlas_Person__c', new Map<String, Object>{
                'Name' => 'Atlas Second Link', 'Active__c' => true, 'User__c' => 'source-user'}),
                new Map<String, Object>(), new Map<String, Object>{'source-user' => UserInfo.getUserId()})));
            System.assert(JSON.serialize(users.get('conflicts')).contains('already links to Atlas Linked'), JSON.serialize(users.get('conflicts')));
            Map<String, Object> names = parsed(Atlas_WorkspaceRecovery.reviewRecord(prepare(saved, source('Atlas_Person__c', new Map<String, Object>{
                'Name' => 'Atlas Name Clash', 'Active__c' => true, 'Aliases__c' => 'Recovered alias number 3'}),
                new Map<String, Object>(), new Map<String, Object>())));
            System.assert(JSON.serialize(names.get('conflicts')).contains('already points to Atlas Recovered Person'), JSON.serialize(names.get('conflicts')));
            try { apply(names); System.assert(false, 'A clashing person must not be recovered'); }
            catch (AuraHandledException e) { System.assert(e.getMessage().contains('conflicts')); }
            Map<String, Object> bad = parsed(Atlas_WorkspaceRecovery.reviewRecord(prepare(saved, source('Atlas_Person__c', new Map<String, Object>{
                'Name' => 'Atlas Bad Aliases', 'Active__c' => true, 'Alias_List__c' => '{"not":"a list"}'}),
                new Map<String, Object>(), new Map<String, Object>())));
            System.assert(JSON.serialize(bad.get('conflicts')).contains('Recovered aliases are not valid'), JSON.serialize(bad.get('conflicts')));
            Test.stopTest();
            System.assertEquals(2, [SELECT count() FROM Atlas_Person__c]);
        }
    }

    @IsTest
    static void applyingARecoveryKeepsOnlyTokensForTheBeforeState() {
        System.runAs(Atlas_Mock.atlasUser()) {
            Map<String, Object> saved = archive();
            Test.startTest();
            Id planId = prepare(saved, source('Atlas_Conversation__c', new Map<String, Object>{'Name' => 'Atlas compact',
                'Mode__c' => 'Files', 'UI_State__c' => '{"long":"' + 'x'.repeat(50000) + '"}'}), new Map<String, Object>(), new Map<String, Object>());
            apply(parsed(Atlas_WorkspaceRecovery.reviewRecord(planId)));
            Test.stopTest();
            String stored = (String)parsed(Atlas_Library.loadEntry(planId)).get('dataJson');
            Map<String, Object> plan = parsed(stored);
            System.assertEquals('beforeReview', ((Map<String, Object>)plan.get('beforeApply')).get('sameAs'),
                'Apply records tokens that point at the reviewed before-state.');
            System.assert(stored.length() < 2 * 50000 + 25000, 'The plan holds the source and one review projection, not another full copy: ' + stored.length());
        }
    }
}
