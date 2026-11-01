/** Global uniqueness only. No person data is returned across sharing boundaries. */
public without sharing class Atlas_ManagerGuard {
    static Boolean same(String a, String b) { return a == null ? b == null : a.equals(b); }
    public static void checkPeople(List<Atlas_Person__c> records, Map<Id,Atlas_Person__c> before) {
        // Read the legacy selection only after taking the same lock used by setting writes.
        Atlas_Data.lockPeople();
        Map<String,Object> legacy = Atlas_Jira.legacyManagerSetting();
        String legacyId = (String)legacy.get('reviewManagerPersonId');
        Boolean relevant = false, invalidateLegacy = false;
        Set<Id> changed = new Set<Id>();
        for (Atlas_Person__c row : records) {
            if (row.Id != null) changed.add(row.Id);
            Atlas_Person__c old = before == null ? null : before.get(row.Id);
            if (row.Atlas_Is_Manager__c && old?.Atlas_Is_Manager__c != true && row.Active__c != true)
                row.addError('Choose an active person as Manager.');
            if (old != null && (!same(row.Jira_Account_Id__c, old.Jira_Account_Id__c) || row.User__c != old.User__c)) {
                // A confirmation belongs to the saved identity, not to an arbitrary replacement.
                row.Atlas_Jira_Identity_Type__c = null;
                if (String.valueOf(row.Id) == legacyId) invalidateLegacy = true;
            }
            if (row.Atlas_Is_Manager__c || old?.Atlas_Is_Manager__c == true || String.valueOf(row.Id) == legacyId) relevant = true;
        }
        if (!relevant) return;
        if (invalidateLegacy) {
            List<Atlas_Setting__c> settings = [SELECT Id,Data__c FROM Atlas_Setting__c WHERE Key__c='jira' FOR UPDATE];
            if (!settings.isEmpty()) {
                Map<String,Object> saved = (Map<String,Object>)JSON.deserializeUntyped(settings[0].Data__c);
                saved.put('reviewManagerIdentityType','');
                settings[0].Data__c = JSON.serialize(saved);
                update as user settings;
            }
        }
        Integer managers = [SELECT count() FROM Atlas_Person__c WHERE Atlas_Is_Manager__c = true AND Id NOT IN :changed];
        for (Atlas_Person__c row : records) if (row.Atlas_Is_Manager__c) managers++;
        if (managers > 1) {
            for (Atlas_Person__c row : records) if (row.Atlas_Is_Manager__c)
                row.addError('Only one Manager can be configured for this workspace. Clear the current Manager before selecting another person.');
        }
        for (Atlas_Person__c row : records) if (row.Atlas_Is_Manager__c && String.isNotBlank(legacyId) && String.valueOf(row.Id) != legacyId)
            row.addError('A different Manager is saved in the earlier settings. Edit that person and clear Manager before choosing a replacement.');
    }

    /** Absence, not lack of sharing, permits an explicit replacement of an orphaned legacy role. */
    public static Boolean missingPerson(String personId) {
        Id selected = (Id)personId;
        return [SELECT count() FROM Atlas_Person__c WHERE Id = :selected] == 0;
    }

    /** Used by legacy setting writes as well as native recovery. Never allow two authorities. */
    public static void checkLegacy(String personId) {
        if (String.isBlank(personId)) return;
        Atlas_Data.lockPeople();
        Id selected = (Id)personId;
        if ([SELECT count() FROM Atlas_Person__c WHERE Atlas_Is_Manager__c = true AND Id != :selected] > 0)
            throw new Atlas_Api.AtlasException('A different Manager is already configured in People. Clear that role before selecting another person.');
    }
}
