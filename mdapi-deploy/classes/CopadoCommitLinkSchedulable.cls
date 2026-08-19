/**
 * Delayed follow-up after Builder starts deploy-then-commit.
 * Custom Job Templates push Git but often skip User Story Commit rows;
 * this job attaches Snapshot Commit + USC once the JE is complete.
 */
public without sharing class CopadoCommitLinkSchedulable implements Schedulable {
  private final Id jobExecutionId;
  private final Id userStoryId;
  private final Id sessionId;
  private final Integer attempt;

  public CopadoCommitLinkSchedulable(Id jobExecutionId, Id userStoryId, Id sessionId) {
    this(jobExecutionId, userStoryId, sessionId, 0);
  }

  public CopadoCommitLinkSchedulable(
    Id jobExecutionId,
    Id userStoryId,
    Id sessionId,
    Integer attempt
  ) {
    this.jobExecutionId = jobExecutionId;
    this.userStoryId = userStoryId;
    this.sessionId = sessionId;
    this.attempt = attempt == null ? 0 : attempt;
  }

  public void execute(SchedulableContext sc) {
    if (jobExecutionId == null) {
      return;
    }
    CopadoDevopsService.JobStatus status =
      CopadoDevopsService.getJobExecutionStatus(String.valueOf(jobExecutionId));
    String linkMsg = status != null ? status.summary : null;

    if (status != null && status.isComplete == true && status.isFailed != true) {
      linkMsg = CopadoDevopsService.ensureUserStoryCommitFromJob(jobExecutionId);
      postSessionMessage(linkMsg);
      return;
    }

    if (status != null && status.isFailed == true) {
      postSessionMessage(
        'USC link skipped: Job '
          + String.valueOf(jobExecutionId)
          + ' failed ('
          + status.status
          + ').'
      );
      return;
    }

    // Still running — retry a few times (jobs often take 2–3 minutes).
    if (attempt < 4) {
      CopadoDevopsService.scheduleUserStoryCommitLinkAttempt(
        jobExecutionId,
        userStoryId,
        sessionId,
        90,
        attempt + 1
      );
    } else {
      postSessionMessage(
        'USC link pending: Job '
          + String.valueOf(jobExecutionId)
          + ' not complete after retries. Click Refresh job status / Link commit.'
      );
    }
  }

  private void postSessionMessage(String linkMsg) {
    if (sessionId == null || String.isBlank(linkMsg)) {
      return;
    }
    try {
      insert new AI_Builder_Message__c(
        Session__c = sessionId,
        Role__c = 'System',
        Message__c = linkMsg,
        Step__c = 'Committed'
      );
    } catch (Exception ignore) {
    }
  }
}
