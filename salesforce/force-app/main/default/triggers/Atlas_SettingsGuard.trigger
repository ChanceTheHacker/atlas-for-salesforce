trigger Atlas_SettingsGuard on Atlas_Setting__c (before insert, before update, before delete, after undelete) {
    if (Trigger.isUndelete) Atlas_Jira.restored(Trigger.new);
    else Atlas_Jira.guardSettings(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isInsert ? null : Trigger.oldMap, Trigger.isDelete);
}
