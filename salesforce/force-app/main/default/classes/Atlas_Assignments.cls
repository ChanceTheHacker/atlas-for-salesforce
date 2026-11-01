/** Human-reviewed Case ownership only. Jira assignments remain manual ticket proposals. */
public with sharing class Atlas_Assignments {
    static Map<String,Object> identity(String name) {
        Map<String,Object> result = (Map<String,Object>)JSON.deserializeUntyped(Atlas_Identity.lookup(name));
        Map<String,Object> person = (Map<String,Object>)result.get('resolved');
        if (result.get('status') != 'resolved' || person == null || person.get('userId') == null)
            throw new Atlas_Api.AtlasException('Cannot assign to "' + name + '": resolve the Salesforce/Jira identity in Team & Jira first.');
        return person;
    }
    static String identityKey(Map<String,Object> person) {
        return String.valueOf(person.get('personId')) + ':' + person.get('userId') + ':' + person.get('jiraId');
    }
    static void accessibleConversation(Id conversationId) {
        Atlas_Conversation__c conversation = [SELECT Id FROM Atlas_Conversation__c WHERE Id=:conversationId WITH USER_MODE FOR UPDATE];
    }
    static List<Object> rows(String text) {
        List<Object> rows = (List<Object>)JSON.deserializeUntyped(text);
        if (rows == null || rows.isEmpty() || rows.size() > 10) throw new Atlas_Api.AtlasException('Review 1–10 Case assignments at a time.');
        return rows;
    }

    @AuraEnabled
    public static String prepare(Id conversationId, String assignmentsJson) {
        try {
            accessibleConversation(conversationId);
            Atlas_Data.assertSourceChangesAllowed(conversationId);
            List<Object> requested = rows(assignmentsJson);
            Set<Id> ids = new Set<Id>();
            for (Object item : requested) {
                Id id = (Id)((Map<String,Object>)item).get('caseId');
                if (id == null || id.getSObjectType() != Case.SObjectType || !ids.add(id))
                    throw new Atlas_Api.AtlasException('Each assignment needs a distinct Salesforce Case ID. Query the Cases first.');
            }
            Map<Id,Case> cases = new Map<Id,Case>([SELECT Id, CaseNumber, Subject, OwnerId, Owner.Name, LastModifiedDate FROM Case WHERE Id IN :ids WITH USER_MODE]);
            List<Object> review = new List<Object>();
            for (Object item : requested) {
                Map<String,Object> input = (Map<String,Object>)item;
                Case record = cases.get((Id)input.get('caseId'));
                if (record == null) throw new Atlas_Api.AtlasException('A requested Case is not accessible.');
                String reason = (String)input.get('reason');
                if (String.isBlank(reason) || reason.length() > 1000) throw new Atlas_Api.AtlasException('Each Case assignment needs a reason of 1–1,000 characters.');
                String who = (String)input.get('assignee');
                Map<String,Object> person = identity(who);
                review.add(new Map<String,Object>{'caseId'=>record.Id, 'caseNumber'=>record.CaseNumber, 'subject'=>record.Subject,
                    'oldOwnerId'=>record.OwnerId, 'oldOwnerName'=>record.Owner.Name, 'version'=>String.valueOf(record.LastModifiedDate.getTime()),
                    'assignee'=>who, 'userId'=>person.get('userId'), 'name'=>person.get('userName'), 'jiraId'=>person.get('jiraId'),
                    'identityKey'=>identityKey(person), 'reason'=>reason});
            }
            return JSON.serialize(review);
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }

    /** Decision and result message commit with the Case updates. Lost-response retries replay the receipt. */
    @AuraEnabled
    public static String decide(Id conversationId, String reviewJson, Boolean approve, String note, String nonce) {
        try {
            accessibleConversation(conversationId);
            // Recheck the stored mode at approval, including reviews prepared
            // elsewhere or restored from legacy/relinked conversation state.
            if (approve == true) Atlas_Data.assertSourceChangesAllowed(conversationId);
            if (String.isBlank(nonce) || nonce.length() > 80 || note != null && note.length() > 2000 || approve == null)
                throw new Atlas_Api.AtlasException('A decision receipt and a note of at most 2,000 characters are required.');
            String receipt = 'Atlas Case assignment receipt ' + Atlas_Api.sha256(Blob.valueOf(UserInfo.getUserId() + ':' + nonce));
            String digest = Atlas_Api.sha256(Blob.valueOf(reviewJson + ':' + approve + ':' + note));
            List<Atlas_Message__c> messages = [SELECT Body__c, Body_File__c FROM Atlas_Message__c
                WHERE Conversation__c=:conversationId AND Kind__c='case-assignment' AND Direction__c='To Agent' WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 2001];
            for (Atlas_Message__c message : messages) if (message.Body__c.startsWith(receipt + '\n')) {
                String body = message.Body_File__c == null ? message.Body__c : [SELECT VersionData FROM ContentVersion WHERE Id=:message.Body_File__c WITH USER_MODE].VersionData.toString();
                if (!body.startsWith(receipt + '\n' + digest + '\n')) throw new Atlas_Api.AtlasException('This decision receipt belongs to a different review. Reopen the saved result before making another decision.');
                return body;
            }
            if (messages.size() > 2000) throw new Atlas_Api.AtlasException('Too many assignment receipts in this conversation. Start a new conversation.');
            List<Object> review = rows(reviewJson);
            String problem;
            if (approve) {
                Set<Id> ids = new Set<Id>();
                for (Object item : review) {
                    Id id = (Id)((Map<String,Object>)item).get('caseId');
                    if (id == null || id.getSObjectType() != Case.SObjectType || !ids.add(id)) throw new Atlas_Api.AtlasException('Invalid Case review.');
                }
                Map<Id,Case> cases = new Map<Id,Case>([SELECT Id, OwnerId, LastModifiedDate FROM Case WHERE Id IN :ids WITH USER_MODE FOR UPDATE]);
                List<Case> updates = new List<Case>();
                for (Object item : review) {
                    Map<String,Object> row = (Map<String,Object>)item;
                    Map<String,Object> person;
                    try { person = identity((String)row.get('assignee')); }
                    catch (Exception e) { problem = e.getMessage(); break; }
                    if (identityKey(person) != row.get('identityKey') || person.get('userId') != row.get('userId')) {
                        problem = 'The identity mapping changed. Prepare and review the assignments again.'; break;
                    }
                    Case record = cases.get((Id)row.get('caseId'));
                    if (record == null || String.valueOf(record.LastModifiedDate.getTime()) != row.get('version') || String.valueOf(record.OwnerId) != row.get('oldOwnerId')) {
                        problem = 'A Case changed since this review. Prepare and review the assignments again; nothing was changed.'; break;
                    }
                    if (record.OwnerId != (Id)person.get('userId')) updates.add(new Case(Id=record.Id, OwnerId=(Id)person.get('userId')));
                }
                if (problem == null && !updates.isEmpty()) {
                    try { update as user updates; }
                    catch (DmlException e) { problem = 'Salesforce rejected the assignments; no Cases were changed. ' + e.getDmlMessage(0); }
                }
            }
            String body = receipt + '\n' + digest + '\n' + JSON.serializePretty(new Map<String,Object>{'type'=>'atlas-assign-result',
                'requestId'=>conversationId, 'status'=>problem != null ? 'not_applied' : approve ? 'applied' : 'rejected', 'problem'=>problem, 'note'=>note, 'cases'=>review,
                'jira'=>'No Jira API call or ticket update was made. Use a separate atlas-tickets proposal; Jira export/updates remain manual.'});
            Atlas_Data.addMessage(conversationId, 'To Agent', 'case-assignment', body);
            return body;
        } catch (Exception e) { throw Atlas_Api.fail(e); }
    }
}
