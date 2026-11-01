/** One reserved deployment worker per approval; never serializes a session token. */
public with sharing class Atlas_DeployJob implements Queueable, Database.AllowsCallouts {
    Id changeId;
    String retrieveId;
    Integer attempt;

    public Atlas_DeployJob(Id changeId, String retrieveId, Integer attempt) {
        this.changeId = changeId;
        this.retrieveId = retrieveId;
        this.attempt = attempt;
    }

    /** Stay inside Developer Edition's default five-job chain, including completion.
     * Also respect an explicitly smaller stack limit and the one-child async limit. */
    public static Boolean canEnqueue(Integer slots) {
        Integer depth = System.isQueueable() ? AsyncInfo.getCurrentQueueableStackDepth() : 0;
        Integer maximum = System.isQueueable() && AsyncInfo.hasMaxStackDepth() ? AsyncInfo.getMaximumQueueableStackDepth() : 5;
        return fitsChain(depth, maximum, slots) && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
    }

    @TestVisible
    static Boolean fitsChain(Integer depth, Integer maximum, Integer slots) {
        return depth + slots <= Math.min(5, maximum);
    }

    public void execute(QueueableContext context) {
        Atlas_Changes.executeDeployment(changeId, retrieveId, attempt);
    }
}
