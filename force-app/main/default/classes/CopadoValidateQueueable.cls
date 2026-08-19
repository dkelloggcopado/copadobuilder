/**
 * Runs Validate or Deploy-Next CreateExecution in a fresh transaction so Copado's
 * template instantiation does not share the Builder request's SOQL budget (101).
 * AllowsCallouts: Copado CreateExecution / Promotion Deployment Invocable start
 * the job engine via HTTP — without this, the queueable fails silently and the
 * Promotion stays Draft.
 */
public without sharing class CopadoValidateQueueable implements Queueable, Database.AllowsCallouts {
  private final Id sessionId;
  private final Id userStoryId;
  private final Id promotionId;
  private final Id sourceEnvId;
  private final Id destEnvId;
  private final Id pipelineId;
  private final String sourceCredentialOrEnvId;
  private final String destEnvName;
  private final String promoteTemplate;
  private final String deployTemplate;
  private final String dataJson;
  /** Validate (dry-run) or DeployNext (real). */
  private final String jobAction;

  public CopadoValidateQueueable(
    Id sessionId,
    Id userStoryId,
    Id promotionId,
    Id sourceEnvId,
    Id destEnvId,
    Id pipelineId,
    String sourceCredentialOrEnvId,
    String destEnvName,
    String promoteTemplate,
    String deployTemplate,
    String dataJson
  ) {
    this(
      sessionId,
      userStoryId,
      promotionId,
      sourceEnvId,
      destEnvId,
      pipelineId,
      sourceCredentialOrEnvId,
      destEnvName,
      promoteTemplate,
      deployTemplate,
      dataJson,
      'Validate'
    );
  }

  public CopadoValidateQueueable(
    Id sessionId,
    Id userStoryId,
    Id promotionId,
    Id sourceEnvId,
    Id destEnvId,
    Id pipelineId,
    String sourceCredentialOrEnvId,
    String destEnvName,
    String promoteTemplate,
    String deployTemplate,
    String dataJson,
    String jobAction
  ) {
    this.sessionId = sessionId;
    this.userStoryId = userStoryId;
    this.promotionId = promotionId;
    this.sourceEnvId = sourceEnvId;
    this.destEnvId = destEnvId;
    this.pipelineId = pipelineId;
    this.sourceCredentialOrEnvId = sourceCredentialOrEnvId;
    this.destEnvName = destEnvName;
    this.promoteTemplate = promoteTemplate;
    this.deployTemplate = deployTemplate;
    this.dataJson = dataJson;
    this.jobAction = String.isNotBlank(jobAction) ? jobAction : 'Validate';
  }

  public void execute(QueueableContext ctx) {
    Id promoId = promotionId;
    Id pipeId = pipelineId;

    // Recover Promotion Id if constructor serialization lost it.
    if (promoId == null && String.isNotBlank(dataJson)) {
      try {
        Map<String, Object> seed = (Map<String, Object>) JSON.deserializeUntyped(dataJson);
        if (seed != null && seed.get('promotionId') != null) {
          promoId = (Id) String.valueOf(seed.get('promotionId'));
        }
        if (pipeId == null && seed != null && seed.get('pipelineId') != null) {
          pipeId = (Id) String.valueOf(seed.get('pipelineId'));
        }
      } catch (Exception ignore) {
      }
    }
    if (promoId == null && sessionId != null) {
      try {
        AI_Builder_Session__c session = [
          SELECT Last_Promotion_Id__c
          FROM AI_Builder_Session__c
          WHERE Id = :sessionId
          LIMIT 1
        ];
        if (String.isNotBlank(session.Last_Promotion_Id__c)) {
          promoId = (Id) session.Last_Promotion_Id__c;
        }
      } catch (Exception ignore) {
      }
    }

    CopadoDevopsService.JobResult job;
    try {
      job = CopadoDevopsService.runQueuedValidateExecution(
        userStoryId,
        promoId,
        sourceEnvId,
        destEnvId,
        pipeId,
        sourceCredentialOrEnvId,
        destEnvName,
        promoteTemplate,
        deployTemplate,
        dataJson
      );
    } catch (Exception ex) {
      job = new CopadoDevopsService.JobResult();
      job.method = 'CreateExecution';
      job.status = 'Failed';
      job.jobId = null;
      job.errorDetail = ex.getMessage();
      job.summary =
        '[BuilderValidate/v27] '
        + ('DeployNext'.equalsIgnoreCase(jobAction) ? 'Deploy' : 'Validate')
        + ' queueable failed: '
        + ex.getMessage()
        + (promoId != null ? (' (Promotion ' + promoId + ')') : '');
      if (promoId != null) {
        job.promotionId = String.valueOf(promoId);
      }
    }
    if (job != null && String.isNotBlank(job.summary)
      && !job.summary.contains('[BuilderValidate/v27]')) {
      job.summary = '[BuilderValidate/v27] ' + job.summary;
    }
    if (job != null && String.isBlank(job.promotionId) && promoId != null) {
      job.promotionId = String.valueOf(promoId);
    }
    persistResult(job);
  }

  private void persistResult(CopadoDevopsService.JobResult job) {
    if (sessionId == null || job == null) {
      return;
    }
    Boolean isDeployNext = 'DeployNext'.equalsIgnoreCase(jobAction);
    try {
      AI_Builder_Session__c session = [
        SELECT Id, Current_Step__c, Last_Job_Id__c, Last_Job_Action__c, Summary__c, Last_Promotion_Id__c
        FROM AI_Builder_Session__c
        WHERE Id = :sessionId
        LIMIT 1
      ];
      session.Last_Job_Action__c = isDeployNext ? 'DeployNext' : 'Validate';
      if (String.isNotBlank(job.promotionId)) {
        session.Last_Promotion_Id__c = job.promotionId;
      }
      Boolean hasRealJob =
        String.isNotBlank(job.jobId)
        && !job.jobId.startsWith('create-execution-pending')
        && !job.jobId.startsWith('validate-manual')
        && !job.jobId.startsWith('validate-queued')
        && !job.jobId.startsWith('deploy-next-queued')
        && !job.jobId.startsWith('prepared-')
        && !job.jobId.startsWith('webhook-');
      if (hasRealJob) {
        session.Last_Job_Id__c = job.jobId;
        session.Current_Step__c = isDeployNext ? 'DeployingNext' : 'Validating';
      } else {
        session.Last_Job_Id__c = null;
        session.Current_Step__c = isDeployNext ? 'Validated' : 'Committed';
      }
      String summary = job.summary;
      if (isDeployNext && String.isNotBlank(summary) && summary.startsWith('Validate ')) {
        summary = summary.replaceFirst('Validate ', 'Deploy ');
      }
      session.Summary__c = summary;
      update session;

      insert new AI_Builder_Message__c(
        Session__c = sessionId,
        Role__c = 'System',
        Message__c = String.isNotBlank(summary)
          ? summary
          : (isDeployNext
            ? 'Deploy to next finished queueing.'
            : 'Validate job finished queueing.'),
        Step__c = hasRealJob
          ? (isDeployNext ? 'DeployingNext' : 'Validating')
          : (isDeployNext ? 'DeployNext' : 'Validate')
      );
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.ERROR,
        'CopadoValidateQueueable session update failed: ' + ex.getMessage()
      );
    }
  }
}
