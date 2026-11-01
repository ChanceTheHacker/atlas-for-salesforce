trigger Atlas_PeopleGuard on Atlas_Person__c (before insert, before update, after undelete) {
    Atlas_ManagerGuard.checkPeople(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
