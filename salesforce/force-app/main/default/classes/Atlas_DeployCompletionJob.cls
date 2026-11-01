/** Bounded status-only worker. Carries an exact deployment ID, never a session or a ZIP. */
public with sharing class Atlas_DeployCompletionJob implements Queueable, Database.AllowsCallouts {
    Id changeId;
    String deploymentId;
    Integer attempt;

    public Atlas_DeployCompletionJob(Id changeId, String deploymentId, Integer attempt) {
        this.changeId = changeId;
        this.deploymentId = deploymentId;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        Atlas_Changes.completeDeployment(changeId, deploymentId, attempt);
    }
}
