/** Queueable execution starts only after the approval transaction commits. */
public with sharing class Atlas_JiraWriteJob implements Queueable, Database.AllowsCallouts {
    private Id operationId;
    private Atlas_Jira.CredentialInspector inspector;
    public Atlas_JiraWriteJob(Id operationId) {
        this.operationId=operationId;
        this.inspector=Atlas_Jira.credentialInspector();
    }
    public void execute(QueueableContext context) {
        Atlas_JiraWrites.executeApproved(operationId,context.getJobId(),inspector);
    }
}
