/** Cross-user duplicate guard. Returns no operation contents and is not remotely callable. */
public without sharing class Atlas_JiraReservations {
    public static String key(Id ticketId,String part,String updateId) {
        return Atlas_Api.sha256(Blob.valueOf(ticketId+':'+part+':'+updateId));
    }
    /** Acquire existing reservations before any ticket lock, including another owner's private row. */
    public static void lockForPreparation(String key) {
        for (Atlas_Jira_Operation__c row : [SELECT OwnerId,State__c FROM Atlas_Jira_Operation__c WHERE Ticket_Request_Key__c=:key FOR UPDATE]) {
            if (row.OwnerId!=UserInfo.getUserId() || row.State__c!='reviewed')
                throw new Atlas_Api.AtlasException('This ticket action already has a saved Jira operation. Recover that operation; do not create a duplicate.');
        }
    }
    /** Caller must first lock and authorize the affected tickets in user mode. */
    public static void assertManualAllowed(Set<String> keys) {
        if (keys.isEmpty()) return;
        if ([SELECT COUNT() FROM Atlas_Jira_Operation__c WHERE Ticket_Request_Key__c IN :keys AND State__c IN ('queued','unknown','succeeded') LIMIT 1]>0)
            throw new Atlas_Api.AtlasException('This action already has a queued, uncertain, or confirmed live Jira operation. Recover its saved result and reconcile Jira; do not repeat it through CSV or manual completion.');
    }
}
