/**
 * Copado DevOps facade: pipeline orgs, commit, and deploy using in-org Copado
 * objects and optional Actions/Webhook job templates.
 *
 * without sharing: must create User Story Metadata / User Story Commit / Snapshot
 * Commit rows the running user may not own via sharing rules.
 */
public without sharing class CopadoDevopsService {

  /** Bump when Validate/Promotion path changes — surfaces in Builder UI + chat. */
  public static final String BUILDER_CODE_VERSION = 'BuilderValidate/v68';

  public class JobResult {
    @AuraEnabled public String jobId;
    @AuraEnabled public String status;
    @AuraEnabled public String summary;
    @AuraEnabled public String method;
    @AuraEnabled public String contentDocumentId;
    @AuraEnabled public String promotionId;
    /** Populated when CreateExecution / Promote invoke fails (for chat diagnostics). */
    @AuraEnabled public String errorDetail;
    /** Parent Id that succeeded for CreateExecution (Promotion or Promoted US). */
    public String parentIdUsed;
  }

  public class JobStatus {
    @AuraEnabled public String jobId;
    @AuraEnabled public String status;
    @AuraEnabled public String summary;
    @AuraEnabled public String errorMessage;
    @AuraEnabled public Boolean isComplete;
    @AuraEnabled public Boolean isFailed;
  }

  public class SnapshotCreateResult {
    public Id snapshotId;
    public String error;
  }

  public class UscLinkResult {
    public Id uscId;
    public String error;
  }

  private static final List<String> USC_SNAPSHOT_LOOKUP_CANDIDATES = new List<String>{
    'copado__Snapshot_Commit__c',
    'copado__SnapshotCommit__c',
    'copado__Git_Backup__c',
    'copado__Git_Commit__c'
  };

  private static final List<String> SNAPSHOT_OBJECT_TYPES = new List<String>{
    'copado__Snapshot_Commit__c',
    'copado__Git_Backup__c'
  };

  public class DevopsSettings {
    public String commitJobTemplate;
    public String deployJobTemplate;
    public String deployThenCommitJobTemplate;
    public String validatePromoteJobTemplate;
    public String validateDeployJobTemplate;
    public String defaultDevEnvironmentId;
    public String actionsWebhookPath;
  }

  public class ProjectInfo {
    @AuraEnabled public String projectId;
    @AuraEnabled public String projectName;
  }

  public static DevopsSettings getDevopsSettings() {
    DevopsSettings s = new DevopsSettings();
    // Dynamic field list so Apex can compile/deploy before optional
    // custom metadata fields exist in the org.
    Map<String, Schema.SObjectField> cmdFields =
      Copado_Builder_Settings__mdt.SObjectType.getDescribe().fields.getMap();
    List<String> selectFields = new List<String>{
      'Commit_Job_Template__c',
      'Deploy_Job_Template__c',
      'Default_Dev_Environment_Id__c',
      'Actions_Webhook_Path__c'
    };
    Boolean hasDeployThenCommit = cmdFields.containsKey('Deploy_Then_Commit_Job_Template__c');
    if (hasDeployThenCommit) {
      selectFields.add('Deploy_Then_Commit_Job_Template__c');
    }
    Boolean hasValidatePromote = cmdFields.containsKey('Validate_Promote_Job_Template__c');
    if (hasValidatePromote) {
      selectFields.add('Validate_Promote_Job_Template__c');
    }
    Boolean hasValidateDeploy = cmdFields.containsKey('Validate_Deploy_Job_Template__c');
    if (hasValidateDeploy) {
      selectFields.add('Validate_Deploy_Job_Template__c');
    }
    List<SObject> rows = Database.query(
      'SELECT ' + String.join(selectFields, ',')
      + ' FROM Copado_Builder_Settings__mdt'
      + ' WHERE DeveloperName = \'Default\' LIMIT 1'
    );
    if (!rows.isEmpty()) {
      SObject row = rows[0];
      s.commitJobTemplate = (String) row.get('Commit_Job_Template__c');
      s.deployJobTemplate = (String) row.get('Deploy_Job_Template__c');
      if (hasDeployThenCommit) {
        s.deployThenCommitJobTemplate = (String) row.get('Deploy_Then_Commit_Job_Template__c');
      }
      if (hasValidatePromote) {
        s.validatePromoteJobTemplate = (String) row.get('Validate_Promote_Job_Template__c');
      }
      if (hasValidateDeploy) {
        s.validateDeployJobTemplate = (String) row.get('Validate_Deploy_Job_Template__c');
      }
      // Optional org-wide fallback only — developers should pick their own env in the UI
      s.defaultDevEnvironmentId = (String) row.get('Default_Dev_Environment_Id__c');
      s.actionsWebhookPath = (String) row.get('Actions_Webhook_Path__c');
    }
    return s;
  }

  /**
   * Preferred Dev environment for the running user (project-specific, then ALL).
   */
  public static String getPreferredEnvironmentId(String projectId) {
    if (Test.isRunningTest()) {
      return null;
    }
    Id userId = UserInfo.getUserId();
    String projectKey = String.isNotBlank(projectId) ? projectId : 'ALL';
    String specificKey = String.valueOf(userId) + '_' + projectKey;
    String allKey = String.valueOf(userId) + '_ALL';
    List<Copado_Builder_User_Preference__c> prefs = [
      SELECT Environment_Id__c, External_Key__c
      FROM Copado_Builder_User_Preference__c
      WHERE OwnerId = :userId
        AND External_Key__c IN :new List<String>{ specificKey, allKey }
      ORDER BY LastModifiedDate DESC
      LIMIT 10
    ];
    for (Copado_Builder_User_Preference__c pref : prefs) {
      if (pref.External_Key__c == specificKey && String.isNotBlank(pref.Environment_Id__c)) {
        return pref.Environment_Id__c;
      }
    }
    for (Copado_Builder_User_Preference__c pref : prefs) {
      if (pref.External_Key__c == allKey && String.isNotBlank(pref.Environment_Id__c)) {
        return pref.Environment_Id__c;
      }
    }
    return null;
  }

  public static void saveUserPreference(String environmentId, String projectId) {
    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException('Select a Dev environment to remember.');
    }
    Id userId = UserInfo.getUserId();
    String projectKey = String.isNotBlank(projectId) ? projectId : 'ALL';
    String externalKey = String.valueOf(userId) + '_' + projectKey;
    Copado_Builder_User_Preference__c pref = new Copado_Builder_User_Preference__c(
      OwnerId = userId,
      Project_Id__c = projectKey == 'ALL' ? null : projectKey,
      Environment_Id__c = environmentId,
      External_Key__c = externalKey
    );
    upsert pref External_Key__c;
  }

  /**
   * Remember which Copado Project this user creates stories in.
   * Uses preference External_Key = userId_DEFAULT_PROJECT.
   */
  public static void savePreferredProject(String projectId) {
    if (String.isBlank(projectId)) {
      throw new CopadoAiApiService.ApiException('Select a Copado Project.');
    }
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_DEFAULT_PROJECT';
    // Environment_Id__c is required on the preference object — store project Id there too.
    Copado_Builder_User_Preference__c pref = new Copado_Builder_User_Preference__c(
      OwnerId = userId,
      Project_Id__c = projectId,
      Environment_Id__c = projectId,
      External_Key__c = externalKey
    );
    upsert pref External_Key__c;
  }

  public static String getPreferredProjectId() {
    if (Test.isRunningTest()) {
      return null;
    }
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_DEFAULT_PROJECT';
    List<Copado_Builder_User_Preference__c> prefs = [
      SELECT Project_Id__c
      FROM Copado_Builder_User_Preference__c
      WHERE OwnerId = :userId AND External_Key__c = :externalKey
      LIMIT 1
    ];
    if (!prefs.isEmpty() && String.isNotBlank(prefs[0].Project_Id__c)) {
      return prefs[0].Project_Id__c;
    }
    return null;
  }

  /**
   * Remember which Copado AI cicd integration (User Level) this user binds Org Context to.
   * External_Key = userId_DEFAULT_INTEGRATION; Id stored in Environment_Id__c (Text 80).
   */
  public static void savePreferredIntegration(String integrationId) {
    if (String.isBlank(integrationId)) {
      throw new CopadoAiApiService.ApiException('Select a Copado AI Integration.');
    }
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_DEFAULT_INTEGRATION';
    Copado_Builder_User_Preference__c pref = new Copado_Builder_User_Preference__c(
      OwnerId = userId,
      Project_Id__c = null,
      Environment_Id__c = integrationId.left(80),
      External_Key__c = externalKey
    );
    upsert pref External_Key__c;
  }

  public static String getPreferredIntegrationId() {
    if (Test.isRunningTest()) {
      return null;
    }
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_DEFAULT_INTEGRATION';
    List<Copado_Builder_User_Preference__c> prefs = [
      SELECT Environment_Id__c
      FROM Copado_Builder_User_Preference__c
      WHERE OwnerId = :userId AND External_Key__c = :externalKey
      LIMIT 1
    ];
    if (!prefs.isEmpty() && String.isNotBlank(prefs[0].Environment_Id__c)) {
      return prefs[0].Environment_Id__c;
    }
    return null;
  }

  /** Persist first-run setup: Project + Integration for the running user. */
  public static void saveUserSetupDefaults(String projectId, String integrationId) {
    savePreferredProject(projectId);
    savePreferredIntegration(integrationId);
    clearUserSetupBypass();
  }

  /**
   * Skip first-run Project/Integration modal so the user can chat with Copado AI.
   * Org Context / Deploy still need Project + Integration later from the sidebar.
   */
  public static void saveUserSetupBypass() {
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_SETUP_BYPASSED';
    Copado_Builder_User_Preference__c pref = new Copado_Builder_User_Preference__c(
      OwnerId = userId,
      Project_Id__c = null,
      Environment_Id__c = 'BYPASS',
      External_Key__c = externalKey
    );
    upsert pref External_Key__c;
  }

  public static Boolean isUserSetupBypassed() {
    if (Test.isRunningTest()) {
      return false;
    }
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_SETUP_BYPASSED';
    List<Copado_Builder_User_Preference__c> prefs = [
      SELECT Id
      FROM Copado_Builder_User_Preference__c
      WHERE OwnerId = :userId AND External_Key__c = :externalKey
      LIMIT 1
    ];
    return !prefs.isEmpty();
  }

  public static void clearUserSetupBypass() {
    Id userId = UserInfo.getUserId();
    String externalKey = String.valueOf(userId) + '_SETUP_BYPASSED';
    List<Copado_Builder_User_Preference__c> prefs = [
      SELECT Id
      FROM Copado_Builder_User_Preference__c
      WHERE OwnerId = :userId AND External_Key__c = :externalKey
      LIMIT 1
    ];
    if (!prefs.isEmpty()) {
      delete prefs;
    }
  }

  public static List<ProjectInfo> listProjects() {
    List<ProjectInfo> results = new List<ProjectInfo>();
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      ProjectInfo a = new ProjectInfo();
      a.projectId = 'proj-demo-001';
      a.projectName = 'Demo Project A';
      results.add(a);
      ProjectInfo b = new ProjectInfo();
      b.projectId = 'proj-demo-002';
      b.projectName = 'Demo Project B';
      results.add(b);
      return results;
    }
    if (Schema.getGlobalDescribe().get('copado__Project__c') == null) {
      return results;
    }
    try {
      for (SObject row : Database.query(
        'SELECT Id, Name FROM copado__Project__c ORDER BY Name ASC LIMIT 100'
      )) {
        ProjectInfo p = new ProjectInfo();
        p.projectId = String.valueOf(row.get('Id'));
        p.projectName = String.valueOf(row.get('Name'));
        results.add(p);
      }
    } catch (Exception ignore) {
    }
    return results;
  }

  /**
   * Sets Environment / Org Credential on the Copado User Story from the selected Dev target.
   * Returns a short status message for the chat.
   */
  public static String assignEnvironmentToUserStory(Id userStoryId, String environmentId) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required.');
    }
    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException(
        'Select a Dev environment in the Status panel. Copado Builder will add it to the user story.'
      );
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return 'Using selected Dev environment ' + environmentId + ' (mock).';
    }

    CopadoAiApiService.OrgInfo org = findNonProductionOrg(environmentId);
    if (org == null) {
      throw new CopadoAiApiService.ApiException(
        'Only non-production Dev environments are allowed. Production is never permitted.'
      );
    }

    Id envId;
    try {
      envId = (Id) environmentId;
    } catch (Exception ex) {
      throw new CopadoAiApiService.ApiException('Invalid environment Id: ' + environmentId);
    }

    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      throw new CopadoAiApiService.ApiException('Copado User Story object is not available.');
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();

    String envField = firstExisting(fields, new List<String>{
      'copado__Environment__c'
    });
    String orgCredField = firstExisting(fields, new List<String>{
      'copado__Org_Credential__c', 'copado__Org__c'
    });

    SObject us = usType.newSObject();
    us.put('Id', userStoryId);
    Boolean wrote = false;

    // Prefer Environment field when the selected Id is an Environment
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    Boolean isEnvironment = envType != null && String.valueOf(envId.getSobjectType()) == String.valueOf(envType);

    if (isEnvironment && envField != null) {
      us.put(envField, envId);
      wrote = true;
      // Also set org credential from environment when possible
      Id credId = resolveOrgCredentialFromEnvironment(envId, fields);
      if (credId != null && orgCredField != null) {
        us.put(orgCredField, credId);
      }
    } else if (orgCredField != null) {
      us.put(orgCredField, envId);
      wrote = true;
    } else if (envField != null) {
      us.put(envField, envId);
      wrote = true;
    }

    if (!wrote) {
      throw new CopadoAiApiService.ApiException(
        'Could not find Environment or Org Credential fields on the Copado User Story. '
        + 'Add an environment on the user story in Copado, then retry.'
      );
    }

    update us;
    return 'Set Dev environment "' + org.orgName + '" on the user story.';
  }

  public static String getUserStoryEnvironmentId(Id userStoryId) {
    return resolveOrgCredentialId(getUserStoryEnvironmentRawId(userStoryId));
  }

  /**
   * Raw Environment / Org Credential lookup from the story (may be Environment Id).
   */
  public static String getUserStoryEnvironmentRawId(Id userStoryId) {
    if (userStoryId == null || isMockDevops()) {
      return null;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String credField = firstExisting(fields, new List<String>{
      'copado__Org_Credential__c', 'copado__Org__c'
    });
    String envField = firstExisting(fields, new List<String>{ 'copado__Environment__c' });
    List<String> selectFields = new List<String>{ 'Id' };
    if (credField != null) {
      selectFields.add(credField);
    }
    if (envField != null && envField != credField) {
      selectFields.add(envField);
    }
    if (selectFields.size() == 1) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
          + ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return null;
      }
      SObject row = rows[0];
      // Prefer explicit org credential on the story.
      if (credField != null && row.get(credField) != null) {
        return String.valueOf(row.get(credField));
      }
      if (envField != null && row.get(envField) != null) {
        return String.valueOf(row.get(envField));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Normalize an Environment Id or Org Credential Id to a validated Org Credential Id.
   */
  public static String resolveOrgCredentialId(String environmentOrCredentialId) {
    if (String.isBlank(environmentOrCredentialId) || isMockDevops()) {
      return environmentOrCredentialId;
    }
    Id rawId;
    try {
      rawId = (Id) environmentOrCredentialId;
    } catch (Exception ex) {
      return environmentOrCredentialId;
    }
    Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
    if (credType == null) {
      credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
    }
    if (credType != null && String.valueOf(rawId.getSobjectType()) == String.valueOf(credType)) {
      return String.valueOf(rawId);
    }
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType != null && String.valueOf(rawId.getSobjectType()) == String.valueOf(envType)) {
      Id fromEnv = resolveOrgCredentialFromEnvironment(rawId, new Map<String, Schema.SObjectField>());
      if (fromEnv != null) {
        return String.valueOf(fromEnv);
      }
      // Fallback: any validated credential linked to this environment.
      if (credType != null) {
        Map<String, Schema.SObjectField> credFields = credType.getDescribe().fields.getMap();
        String envOnCred = firstExisting(credFields, new List<String>{ 'copado__Environment__c' });
        if (envOnCred != null) {
          try {
            String objectName = credType.getDescribe().getName();
            List<SObject> creds = Database.query(
              'SELECT Id FROM ' + objectName
                + ' WHERE ' + envOnCred + ' = :rawId LIMIT 1'
            );
            if (!creds.isEmpty()) {
              return String.valueOf(creds[0].get('Id'));
            }
          } catch (Exception ignore) {
          }
        }
      }
    }
    return environmentOrCredentialId;
  }

  /**
   * Load one org credential by Id for display / pipeline fallback.
   */
  public static CopadoAiApiService.OrgInfo findOrgCredentialById(String orgCredentialId) {
    if (String.isBlank(orgCredentialId) || isMockDevops()) {
      return null;
    }
    String resolved = resolveOrgCredentialId(orgCredentialId);
    List<CopadoAiApiService.OrgInfo> all = queryValidatedOrgCredentials(new Set<String>{ resolved });
    return all.isEmpty() ? null : all[0];
  }

  /**
   * Copado-sourced org context for the Build Agent when live Org Intelligence
   * tools are unavailable in the chat session. Includes story metadata selections
   * and linked Dev credential — not a live Metadata API query.
   */
  public static String buildOrgContextSummary(Id userStoryId, String orgCredentialId) {
    if (userStoryId == null) {
      return null;
    }
    List<String> lines = new List<String>();
    lines.add(
      '[Copado Builder org context — from Copado CI/CD records for this session, '
        + 'NOT live Org Intelligence metadata API. Prefer this over guessing when '
        + 'the Build Agent lacks metadata tools.]'
    );

    UserStoryContext ctx = getUserStoryContext(userStoryId);
    if (ctx != null) {
      lines.add('User Story: ' + blankTo(ctx.name, String.valueOf(userStoryId)));
      if (String.isNotBlank(ctx.title)) {
        lines.add('Title: ' + ctx.title);
      }
      if (String.isNotBlank(ctx.gitBranch)) {
        lines.add('Feature branch: ' + ctx.gitBranch);
      }
      if (String.isNotBlank(ctx.status)) {
        lines.add('Story status: ' + ctx.status);
      }
    }

    CopadoAiApiService.OrgInfo org = findOrgCredentialById(orgCredentialId);
    if (org != null) {
      lines.add('Dev Org Credential: ' + org.orgName + ' (Id ' + org.orgId + ')');
    } else if (String.isNotBlank(orgCredentialId)) {
      lines.add('Dev Org Credential Id: ' + orgCredentialId);
    }

    Schema.SObjectType metaType = Schema.getGlobalDescribe().get('copado__User_Story_Metadata__c');
    if (metaType != null) {
      Map<String, Schema.SObjectField> fields = metaType.getDescribe().fields.getMap();
      String storyField = firstExisting(fields, new List<String>{ 'copado__User_Story__c' });
      String apiField = firstExisting(fields, new List<String>{
        'copado__Metadata_API_Name__c', 'copado__Api_Name__c', 'Name'
      });
      String typeField = firstExisting(fields, new List<String>{
        'copado__Type__c', 'copado__Metadata_Type__c'
      });
      if (storyField != null && apiField != null) {
        List<String> selectFields = new List<String>{ apiField };
        if (typeField != null) {
          selectFields.add(typeField);
        }
        try {
          List<String> components = new List<String>();
          for (SObject row : Database.query(
            'SELECT ' + String.join(selectFields, ',')
              + ' FROM copado__User_Story_Metadata__c WHERE '
              + storyField + ' = :userStoryId ORDER BY '
              + apiField + ' ASC LIMIT 40'
          )) {
            String apiName = String.valueOf(row.get(apiField));
            String typeVal = typeField != null && row.get(typeField) != null
              ? String.valueOf(row.get(typeField))
              : 'Metadata';
            components.add(typeVal + ':' + apiName);
          }
          if (!components.isEmpty()) {
            lines.add('Metadata on this story: ' + String.join(components, '; '));
          }
        } catch (Exception ignore) {
        }
      }
    }

    return lines.size() > 1 ? String.join(lines, '\n') : null;
  }

  /**
   * Live Copado governance-org data (User Story records). These live in the org
   * where Copado is installed — NOT in the Dev sandbox Org Intelligence targets.
   */
  public static String buildGovernanceBacklogSummary(
    String orgCredentialId,
    String orgName
  ) {
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return '[Copado governance] copado__User_Story__c is not available in this org.';
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    List<String> lines = new List<String>();
    lines.add(
      '[COPADO GOVERNANCE DATA — queried live from THIS Copado org via SOQL. '
        + 'This is NOT Org Intelligence. Answer backlog / User Story count / '
        + '"what to work on" questions from this block.]'
    );

    try {
      Integer total = Database.countQuery('SELECT COUNT() FROM copado__User_Story__c');
      lines.add('Total User Stories in Copado org: ' + total);
    } catch (Exception ex) {
      lines.add('Could not count User Stories: ' + ex.getMessage());
      return String.join(lines, '\n');
    }

    String envLabel = String.isNotBlank(orgName) ? orgName : null;
    Id envRecordId = null;
    Id credId = null;
    if (String.isNotBlank(orgCredentialId)) {
      try {
        credId = (Id) orgCredentialId;
      } catch (Exception ignore) {
      }
      if (credId != null) {
        envRecordId = resolveEnvironmentRecordId(orgCredentialId);
        CopadoAiApiService.OrgInfo org = findOrgCredentialById(orgCredentialId);
        if (org != null && String.isNotBlank(org.orgName)) {
          envLabel = org.orgName;
        }
      }
    }

    String credField = firstExisting(fields, new List<String>{
      'copado__Org_Credential__c', 'copado__Org__c'
    });
    String envField = firstExisting(fields, new List<String>{ 'copado__Environment__c' });
    String titleField = firstExisting(fields, new List<String>{
      'copado__User_Story_Title__c', 'copado__Title__c'
    });
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'copado__User_Story_Status__c'
    });
    String branchField = firstExisting(fields, new List<String>{
      'copado__Git_Branch__c', 'copado__Branch__c'
    });

    if (envLabel != null || credId != null || envRecordId != null) {
      Integer envCount = countUserStoriesForEnvironment(
        credField, envField, credId, envRecordId
      );
      String scope = String.isNotBlank(envLabel) ? envLabel : String.valueOf(credId);
      lines.add(
        'User Stories assigned to Dev environment "' + scope + '": '
          + (envCount != null ? String.valueOf(envCount) : 'n/a')
      );
    }

    List<String> selectFields = new List<String>{ 'Id', 'Name', 'LastModifiedDate' };
    if (titleField != null) {
      selectFields.add(titleField);
    }
    if (statusField != null) {
      selectFields.add(statusField);
    }
    if (branchField != null) {
      selectFields.add(branchField);
    }
    if (credField != null) {
      selectFields.add(credField);
    }
    if (envField != null) {
      selectFields.add(envField);
    }

    try {
      String soql = 'SELECT ' + String.join(selectFields, ',')
        + ' FROM copado__User_Story__c';
      List<String> whereParts = new List<String>();
      if (credField != null && credId != null) {
        whereParts.add(credField + ' = :credId');
      }
      if (envField != null && envRecordId != null) {
        whereParts.add(envField + ' = :envRecordId');
      }
      if (!whereParts.isEmpty()) {
        soql += ' WHERE (' + String.join(whereParts, ' OR ') + ')';
      }
      soql += ' ORDER BY LastModifiedDate DESC LIMIT 12';

      List<String> recent = new List<String>();
      for (SObject row : Database.query(soql)) {
        String name = String.valueOf(row.get('Name'));
        String title = titleField != null && row.get(titleField) != null
          ? String.valueOf(row.get(titleField))
          : '';
        String status = statusField != null && row.get(statusField) != null
          ? String.valueOf(row.get(statusField))
          : '';
        String branch = branchField != null && row.get(branchField) != null
          ? String.valueOf(row.get(branchField))
          : '';
        String line = name;
        if (String.isNotBlank(title)) {
          line += ' — ' + title;
        }
        if (String.isNotBlank(status)) {
          line += ' [' + status + ']';
        }
        if (String.isNotBlank(branch)) {
          line += ' (' + branch + ')';
        }
        recent.add(line);
      }
      if (recent.isEmpty() && (credId != null || envRecordId != null)) {
        for (SObject row : Database.query(
          'SELECT ' + String.join(selectFields, ',')
            + ' FROM copado__User_Story__c ORDER BY LastModifiedDate DESC LIMIT 12'
        )) {
          String name = String.valueOf(row.get('Name'));
          String title = titleField != null && row.get(titleField) != null
            ? String.valueOf(row.get(titleField))
            : '';
          recent.add(String.isBlank(title) ? name : name + ' — ' + title);
        }
        lines.add('No stories matched the selected Dev environment filter; showing recent org-wide:');
      } else if (!recent.isEmpty()) {
        lines.add('Recent stories'
          + (String.isNotBlank(envLabel) ? ' for ' + envLabel : '')
          + ':');
      }
      for (String r : recent) {
        lines.add('- ' + r);
      }
    } catch (Exception ex) {
      lines.add('Could not list recent User Stories: ' + ex.getMessage());
    }

    lines.add(
      'Guidance: Prefer stories In Progress or recently modified on the selected Dev '
        + 'environment. Story dependencies (if any) are on Copado User Story records — '
        + 'not Dev-org metadata. Org Intelligence cannot count User Stories.'
    );
    return String.join(lines, '\n');
  }

  private static Integer countUserStoriesForEnvironment(
    String credField,
    String envField,
    Id credId,
    Id envRecordId
  ) {
    try {
      List<String> parts = new List<String>();
      if (credField != null && credId != null) {
        parts.add(credField + ' = :credId');
      }
      if (envField != null && envRecordId != null) {
        parts.add(envField + ' = :envRecordId');
      }
      if (parts.isEmpty()) {
        return null;
      }
      return Database.countQuery(
        'SELECT COUNT() FROM copado__User_Story__c WHERE ('
          + String.join(parts, ' OR ')
          + ')'
      );
    } catch (Exception ignore) {
      return null;
    }
  }

  public static String getProjectIdFromUserStory(Id userStoryId) {
    if (userStoryId == null || isMockDevops()) {
      return null;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String projectField = firstExisting(fields, new List<String>{
      'copado__Project__c', 'Project__c'
    });
    if (projectField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + projectField + ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(projectField) != null) {
        return String.valueOf(rows[0].get(projectField));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /** Full Copado User Story context for Builder "Use Existing Story". */
  public class UserStoryContext {
    @AuraEnabled public Id recordId;
    @AuraEnabled public String name;
    @AuraEnabled public String title;
    @AuraEnabled public String asA;
    @AuraEnabled public String iWantTo;
    @AuraEnabled public String soThat;
    @AuraEnabled public String acceptanceCriteria;
    @AuraEnabled public String functionalSpecs;
    @AuraEnabled public String technicalSpecs;
    @AuraEnabled public String projectId;
    @AuraEnabled public String environmentId;
    @AuraEnabled public String gitBranch;
    @AuraEnabled public String status;
    @AuraEnabled public String summaryText;
  }

  public static UserStoryContext getUserStoryContext(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      UserStoryContext mock = new UserStoryContext();
      mock.recordId = userStoryId;
      mock.name = 'US-MOCK';
      mock.title = 'Mock existing story';
      mock.acceptanceCriteria = 'Given mock; When build; Then code is generated.';
      mock.summaryText = formatUserStorySummary(mock);
      return mock;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    Map<String, String> fieldMap = new Map<String, String>{
      'title' => firstExisting(fields, new List<String>{
        'copado__User_Story_Title__c', 'copado__Title__c'
      }),
      'asA' => firstExisting(fields, new List<String>{
        'copado__As_a__c', 'copado__Persona__c', 'copado__US_As_a__c'
      }),
      'iWantTo' => firstExisting(fields, new List<String>{
        'copado__I_want_to__c', 'copado__Want__c', 'copado__US_I_want_to__c'
      }),
      'soThat' => firstExisting(fields, new List<String>{
        'copado__So_that__c', 'copado__US_So_that__c'
      }),
      'acceptance' => firstExisting(fields, new List<String>{
        'copado__Acceptance_Criteria__c', 'copado__AcceptanceCriteria__c'
      }),
      'functional' => firstExisting(fields, new List<String>{
        'copado__Functional_Specifications__c', 'copado__Functional_Specs__c'
      }),
      'technical' => firstExisting(fields, new List<String>{
        'copado__Technical_Specifications__c', 'copado__Technical_Specs__c'
      }),
      'project' => firstExisting(fields, new List<String>{
        'copado__Project__c', 'Project__c'
      }),
      'environment' => firstExisting(fields, new List<String>{
        'copado__Environment__c', 'copado__Org_Credential__c', 'copado__Org__c'
      }),
      'branch' => firstExisting(fields, new List<String>{
        'copado__Git_Branch__c', 'copado__Branch__c', 'copado__Feature_Branch__c'
      }),
      'status' => firstExisting(fields, new List<String>{
        'copado__Status__c', 'copado__User_Story_Status__c'
      })
    };

    List<String> selectFields = new List<String>{ 'Id', 'Name' };
    for (String key : fieldMap.keySet()) {
      String api = fieldMap.get(key);
      if (api != null && !selectFields.contains(api)) {
        selectFields.add(api);
      }
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
          + ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return null;
      }
      SObject row = rows[0];
      UserStoryContext ctx = new UserStoryContext();
      ctx.recordId = userStoryId;
      ctx.name = String.valueOf(row.get('Name'));
      ctx.title = textVal(row, fieldMap.get('title'));
      ctx.asA = textVal(row, fieldMap.get('asA'));
      ctx.iWantTo = textVal(row, fieldMap.get('iWantTo'));
      ctx.soThat = textVal(row, fieldMap.get('soThat'));
      ctx.acceptanceCriteria = textVal(row, fieldMap.get('acceptance'));
      ctx.functionalSpecs = textVal(row, fieldMap.get('functional'));
      ctx.technicalSpecs = textVal(row, fieldMap.get('technical'));
      ctx.projectId = textVal(row, fieldMap.get('project'));
      ctx.environmentId = textVal(row, fieldMap.get('environment'));
      ctx.gitBranch = textVal(row, fieldMap.get('branch'));
      ctx.status = textVal(row, fieldMap.get('status'));
      ctx.summaryText = formatUserStorySummary(ctx);
      return ctx;
    } catch (Exception ignore) {
      return null;
    }
  }

  private static String textVal(SObject row, String fieldApi) {
    if (row == null || String.isBlank(fieldApi) || row.get(fieldApi) == null) {
      return null;
    }
    return String.valueOf(row.get(fieldApi));
  }

  @TestVisible
  private static String formatUserStorySummary(UserStoryContext ctx) {
    if (ctx == null) {
      return '';
    }
    List<String> lines = new List<String>();
    String header = String.isNotBlank(ctx.name) ? ctx.name : 'User Story';
    if (String.isNotBlank(ctx.title)) {
      header += ' — ' + ctx.title;
    }
    lines.add(header);
    if (String.isNotBlank(ctx.asA) || String.isNotBlank(ctx.iWantTo) || String.isNotBlank(ctx.soThat)) {
      lines.add(
        'As a ' + blankTo(ctx.asA, '…')
        + ', I want to ' + blankTo(ctx.iWantTo, '…')
        + ' so that ' + blankTo(ctx.soThat, '…')
      );
    }
    if (String.isNotBlank(ctx.acceptanceCriteria)) {
      lines.add('Acceptance Criteria:\n' + ctx.acceptanceCriteria);
    }
    if (String.isNotBlank(ctx.functionalSpecs)) {
      lines.add('Functional Specifications:\n' + ctx.functionalSpecs);
    }
    if (String.isNotBlank(ctx.technicalSpecs)) {
      lines.add('Technical Specifications:\n' + ctx.technicalSpecs);
    }
    if (String.isNotBlank(ctx.gitBranch)) {
      lines.add('Feature branch: ' + ctx.gitBranch);
    }
    return String.join(lines, '\n\n');
  }

  private static String blankTo(String value, String fallback) {
    return String.isNotBlank(value) ? value : fallback;
  }

  public static CopadoAiApiService.OrgInfo findNonProductionOrg(String orgId) {
    return findNonProductionOrg(orgId, null);
  }

  public static CopadoAiApiService.OrgInfo findNonProductionOrg(String orgId, String projectId) {
    if (String.isBlank(orgId)) {
      return null;
    }
    String resolved = resolveOrgCredentialId(orgId);
    String want = String.isNotBlank(resolved) ? resolved : orgId;
    for (CopadoAiApiService.OrgInfo org : listPipelineOrgs(projectId)) {
      if (org.isProduction == true) {
        continue;
      }
      if (sameSalesforceId(org.orgId, want) || sameSalesforceId(org.orgId, orgId)) {
        return org;
      }
    }
    // Fallback: direct credential load (owned picker Ids must still Connect).
    CopadoAiApiService.OrgInfo direct = findOrgCredentialById(want);
    if (direct != null && direct.isProduction != true) {
      return direct;
    }
    return null;
  }

  @TestVisible
  private static Boolean sameSalesforceId(String a, String b) {
    if (String.isBlank(a) || String.isBlank(b)) {
      return false;
    }
    if (a.equals(b)) {
      return true;
    }
    try {
      return ((Id) a) == ((Id) b);
    } catch (Exception ignore) {
      return a.left(15) == b.left(15);
    }
  }

  private static Id resolveOrgCredentialFromEnvironment(Id environmentId, Map<String, Schema.SObjectField> usFields) {
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> envFields = envType.getDescribe().fields.getMap();
    String credOnEnv = firstExisting(envFields, new List<String>{
      'copado__Org_Credential__c', 'copado__Org__c', 'copado__Default_Org_Credential__c'
    });
    if (credOnEnv == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + credOnEnv + ' FROM copado__Environment__c WHERE Id = :environmentId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(credOnEnv) != null) {
        return (Id) rows[0].get(credOnEnv);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  public static Boolean isMockDevops() {
    if (Test.isRunningTest()) {
      return true;
    }
    // When Copado package objects are missing, fall back to mock org list only
    return Schema.getGlobalDescribe().get('copado__User_Story__c') == null;
  }

  // ---------------------------------------------------------------------------
  // Pipeline orgs
  // ---------------------------------------------------------------------------

  public static List<CopadoAiApiService.OrgInfo> listPipelineOrgs() {
    return listPipelineOrgs(null);
  }

  /**
   * Validated Org Credentials only. When projectId is set, prefer credentials
   * that belong to that project's pipeline (avoids "credential not in pipeline").
   */
  public static List<CopadoAiApiService.OrgInfo> listPipelineOrgs(String projectId) {
    return listPipelineOrgs(projectId, false);
  }

  /**
   * @param ownedByRunningUserOnly when true, only credentials the running user
   *   owns or created (temporary Org Context / Org Intelligence picker rule —
   *   Copado AI credentials are per-user and not shareable).
   */
  public static List<CopadoAiApiService.OrgInfo> listPipelineOrgs(
    String projectId,
    Boolean ownedByRunningUserOnly
  ) {
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return CopadoAiApiService.mockListPipelineOrgsPublic();
    }

    List<CopadoAiApiService.OrgInfo> all = queryValidatedOrgCredentials(
      null,
      ownedByRunningUserOnly == true
    );
    if (String.isBlank(projectId)) {
      return all;
    }

    Set<String> allowedIds = getAllowedCredentialIdsForProject(projectId);
    if (allowedIds.isEmpty()) {
      // Pipeline mapping unavailable — return all validated rather than empty
      return all;
    }

    List<CopadoAiApiService.OrgInfo> filtered = new List<CopadoAiApiService.OrgInfo>();
    for (CopadoAiApiService.OrgInfo org : all) {
      if (allowedIds.contains(org.orgId)) {
        filtered.add(org);
      }
    }
    return filtered.isEmpty() ? all : filtered;
  }

  /** True when the Org Credential is owned or created by the running user. */
  public static Boolean isOrgCredentialOwnedByRunningUser(String orgCredentialId) {
    if (String.isBlank(orgCredentialId)) {
      return false;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return true;
    }
    String resolved = resolveOrgCredentialId(orgCredentialId);
    if (String.isBlank(resolved)) {
      resolved = orgCredentialId;
    }
    // Prefer validated owned match (same as picker).
    List<CopadoAiApiService.OrgInfo> owned = queryValidatedOrgCredentials(
      new Set<String>{ resolved },
      true
    );
    if (!owned.isEmpty()) {
      return true;
    }
    // Fallback: ownership without Validated=OK (Connect must not fail after bind).
    return isCredentialOwnedByRunningUserRaw(resolved);
  }

  private static Boolean isCredentialOwnedByRunningUserRaw(String orgCredentialId) {
    Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
    if (credType == null) {
      credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
    }
    if (credType == null || String.isBlank(orgCredentialId)) {
      return false;
    }
    Map<String, Schema.SObjectField> fields = credType.getDescribe().fields.getMap();
    Id runningUserId = UserInfo.getUserId();
    Id credId;
    try {
      credId = (Id) orgCredentialId;
    } catch (Exception ex) {
      return false;
    }
    List<String> ownerParts = new List<String>();
    if (fields.containsKey('OwnerId')) {
      ownerParts.add('OwnerId = :runningUserId');
    }
    if (fields.containsKey('CreatedById')) {
      ownerParts.add('CreatedById = :runningUserId');
    }
    if (ownerParts.isEmpty()) {
      return false;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + credType.getDescribe().getName()
          + ' WHERE Id = :credId AND (' + String.join(ownerParts, ' OR ') + ') LIMIT 1'
      );
      return !rows.isEmpty();
    } catch (Exception ignore) {
      return false;
    }
  }

  /**
   * Lists Copado Org Credentials (copado__Org__c) where Validated Status is OK.
   * Unvalidated / Error / None credentials are excluded.
   */
  private static List<CopadoAiApiService.OrgInfo> queryValidatedOrgCredentials(
    Set<String> restrictIds
  ) {
    return queryValidatedOrgCredentials(restrictIds, false);
  }

  private static List<CopadoAiApiService.OrgInfo> queryValidatedOrgCredentials(
    Set<String> restrictIds,
    Boolean ownedByRunningUserOnly
  ) {
    List<CopadoAiApiService.OrgInfo> results = new List<CopadoAiApiService.OrgInfo>();
    Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
    if (credType == null) {
      credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
    }
    if (credType == null) {
      return results;
    }
    String objectName = credType.getDescribe().getName();
    Map<String, Schema.SObjectField> fields = credType.getDescribe().fields.getMap();
    List<String> selectFields = new List<String>{ 'Id', 'Name' };
    if (fields.containsKey('OwnerId')) {
      selectFields.add('OwnerId');
    }
    if (fields.containsKey('CreatedById')) {
      selectFields.add('CreatedById');
    }
    String envTypeField = firstExisting(fields, new List<String>{
      'copado__Environment_Type__c', 'copado__Org_Type__c', 'copado__Type__c'
    });
    String validatedField = firstExisting(fields, new List<String>{
      'copado__Validated_Status__c'
    });
    String envLookupField = firstExisting(fields, new List<String>{
      'copado__Environment__c'
    });
    if (envTypeField != null) {
      selectFields.add(envTypeField);
    }
    if (validatedField != null) {
      selectFields.add(validatedField);
    }
    if (envLookupField != null) {
      selectFields.add(envLookupField);
    }

    Id runningUserId = UserInfo.getUserId();
    String soql = 'SELECT ' + String.join(selectFields, ',')
      + ' FROM ' + objectName;
    List<String> whereParts = new List<String>();
    if (validatedField != null) {
      whereParts.add(validatedField + ' = \'OK\'');
    }
    if (ownedByRunningUserOnly == true) {
      List<String> ownerParts = new List<String>();
      if (fields.containsKey('OwnerId')) {
        ownerParts.add('OwnerId = :runningUserId');
      }
      if (fields.containsKey('CreatedById')) {
        ownerParts.add('CreatedById = :runningUserId');
      }
      if (!ownerParts.isEmpty()) {
        whereParts.add('(' + String.join(ownerParts, ' OR ') + ')');
      }
    }
    if (!whereParts.isEmpty()) {
      soql += ' WHERE ' + String.join(whereParts, ' AND ');
    }
    soql += ' ORDER BY Name ASC LIMIT 200';

    try {
      Integer order = 1;
      for (SObject row : Database.query(soql)) {
        if (validatedField != null) {
          String status = row.get(validatedField) != null
            ? String.valueOf(row.get(validatedField))
            : '';
          if (status != 'OK') {
            continue;
          }
        }
        String credId = String.valueOf(row.get('Id'));
        if (restrictIds != null && !restrictIds.isEmpty() && !restrictIds.contains(credId)) {
          String envId = envLookupField != null && row.get(envLookupField) != null
            ? String.valueOf(row.get(envLookupField))
            : null;
          if (envId == null || !restrictIds.contains(envId)) {
            continue;
          }
        }
        CopadoAiApiService.OrgInfo org = new CopadoAiApiService.OrgInfo();
        org.orgId = credId;
        org.orgName = String.valueOf(row.get('Name'));
        String typeVal = envTypeField != null && row.get(envTypeField) != null
          ? String.valueOf(row.get(envTypeField))
          : 'Sandbox';
        org.orgType = typeVal;
        org.isProduction = isProductionLabel(typeVal) || isProductionLabel(org.orgName);
        org.pipelineOrder = order++;
        results.add(org);
      }
    } catch (Exception ignore) {
    }
    results.sort();
    return results;
  }

  /**
   * Collect Environment + Org Credential Ids that sit on the project's pipeline.
   */
  private static Set<String> getAllowedCredentialIdsForProject(String projectId) {
    Set<String> allowed = new Set<String>();
    if (String.isBlank(projectId) || Schema.getGlobalDescribe().get('copado__Project__c') == null) {
      return allowed;
    }

    Id flowId = null;
    try {
      Map<String, Schema.SObjectField> projectFields =
        Schema.getGlobalDescribe().get('copado__Project__c').getDescribe().fields.getMap();
      String flowField = firstExisting(projectFields, new List<String>{
        'copado__Deployment_Flow__c', 'copado__Pipeline__c'
      });
      if (flowField == null) {
        return allowed;
      }
      List<SObject> projects = Database.query(
        'SELECT ' + flowField + ' FROM copado__Project__c WHERE Id = :projectId LIMIT 1'
      );
      if (projects.isEmpty() || projects[0].get(flowField) == null) {
        return allowed;
      }
      flowId = (Id) projects[0].get(flowField);
    } catch (Exception ignore) {
      return allowed;
    }

    Set<Id> environmentIds = new Set<Id>();
    for (String stepObject : new List<String>{
      'copado__Deployment_Flow_Step__c', 'copado__Pipeline_Connection__c'
    }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(stepObject);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> stepFields = stepType.getDescribe().fields.getMap();
      String flowOnStep = firstExisting(stepFields, new List<String>{
        'copado__Deployment_Flow__c', 'copado__Pipeline__c'
      });
      List<String> envFields = new List<String>();
      for (String candidate : new List<String>{
        'copado__Source_Environment__c',
        'copado__Destination_Environment__c',
        'copado__Environment__c',
        'copado__Source_Org_Credential__c',
        'copado__Destination_Org_Credential__c',
        'copado__Org_Credential__c'
      }) {
        if (firstExisting(stepFields, new List<String>{ candidate }) != null) {
          envFields.add(candidate);
        }
      }
      if (flowOnStep == null || envFields.isEmpty()) {
        continue;
      }
      try {
        String soql = 'SELECT ' + String.join(envFields, ',')
          + ' FROM ' + stepObject
          + ' WHERE ' + flowOnStep + ' = :flowId LIMIT 200';
        for (SObject step : Database.query(soql)) {
          for (String f : envFields) {
            if (step.get(f) != null) {
              Id relatedId = (Id) step.get(f);
              allowed.add(String.valueOf(relatedId));
              // Track environments separately so we can expand to credentials
              Schema.SObjectType relatedType = relatedId.getSobjectType();
              if (Schema.getGlobalDescribe().get('copado__Environment__c') != null
                && relatedType == Schema.getGlobalDescribe().get('copado__Environment__c')) {
                environmentIds.add(relatedId);
              }
            }
          }
        }
      } catch (Exception ignore) {
      }
    }

    // Expand environments → org credentials
    if (!environmentIds.isEmpty()) {
      Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
      if (credType == null) {
        credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
      }
      if (credType != null) {
        Map<String, Schema.SObjectField> credFields = credType.getDescribe().fields.getMap();
        String envOnCred = firstExisting(credFields, new List<String>{ 'copado__Environment__c' });
        if (envOnCred != null) {
          try {
            String objectName = credType.getDescribe().getName();
            for (SObject cred : Database.query(
              'SELECT Id FROM ' + objectName + ' WHERE ' + envOnCred + ' IN :environmentIds LIMIT 200'
            )) {
              allowed.add(String.valueOf(cred.get('Id')));
            }
          } catch (Exception ignore) {
          }
        }
      }
    }

    return allowed;
  }

  /**
   * Copado/Salesforce org type labels are inconsistent. "Production/Developer"
   * is a Developer sandbox, NOT production — but it contains the substring "prod".
   */
  @TestVisible
  private static Boolean isProductionLabel(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    String lower = value.toLowerCase().trim();
    // Explicit non-production signals (check before prod substring).
    if (
      lower.contains('developer')
      || lower.contains('sandbox')
      || lower.contains('scratch')
      || lower.contains('partial')
      || lower.contains('non-prod')
      || lower.contains('nonprod')
      || lower.contains('uat')
      || lower.contains('integration')
      || lower.contains('staging')
      || lower.contains('test')
    ) {
      return false;
    }
    // dev1, dev2, etc. — Dev environment names, never production targets.
    if (lower.startsWith('dev') || lower.contains('-dev') || lower.contains('_dev')) {
      return false;
    }
    // True production only.
    return lower == 'production'
      || lower == 'prod'
      || lower.startsWith('production ')
      || (lower.contains('production') && !lower.contains('/'));
  }

  // ---------------------------------------------------------------------------
  // Commit / Deploy
  // ---------------------------------------------------------------------------

  /**
   * Legacy entry point — delegates to deploy-then-commit (package must land in Dev
   * before Copado can commit from the Org Credential).
   */
  public static JobResult commitToUserStory(
    Id userStoryId,
    String packageJson,
    String commitMessage,
    List<String> artifactPaths,
    String environmentId
  ) {
    return commitPackageFromDev(
      userStoryId,
      packageJson,
      commitMessage,
      artifactPaths,
      environmentId,
      null,
      false
    );
  }

  /**
   * After Build: attach generated members to the User Story without starting a job.
   * Replaces prior Builder metadata selections so a re-build does not keep stale
   * components (e.g. old User.object after a new Apex package).
   */
  public static Integer stampUserStoryBuildArtifacts(
    Id userStoryId,
    String packageJson,
    List<String> artifactPaths
  ) {
    List<String> paths = artifactPaths;
    if (paths == null || paths.isEmpty()) {
      paths = extractArtifactPathsFromPackage(packageJson);
    }
    if (userStoryId == null || paths == null || paths.isEmpty()) {
      return 0;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return paths.size();
    }
    Id packageDocId = storePackageContent(userStoryId, packageJson);
    if (packageDocId != null) {
      linkContentToUserStory(packageDocId, userStoryId);
    }
    return replaceUserStoryMetadata(userStoryId, paths, packageJson);
  }

  /**
   * Drop User Story Metadata rows stamped by a prior Builder package so Improve /
   * re-Build does not leave stale commit selections (e.g. User.object after moving
   * the story to Account).
   */
  public static Integer clearUserStoryBuildArtifacts(Id userStoryId) {
    if (userStoryId == null) {
      return 0;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return 0;
    }
    return deleteAllUserStoryMetadata(userStoryId);
  }

  /**
   * Delete all User Story Metadata for the story, then insert selections from the
   * current package. Used when Builder regenerates a package so commit selections
   * match the latest artifacts only.
   */
  @TestVisible
  private static Integer replaceUserStoryMetadata(
    Id userStoryId,
    List<String> artifactPaths,
    String packageJson
  ) {
    deleteAllUserStoryMetadata(userStoryId);
    return upsertUserStoryMetadata(userStoryId, artifactPaths, packageJson);
  }

  @TestVisible
  private static Integer deleteAllUserStoryMetadata(Id userStoryId) {
    if (userStoryId == null) {
      return 0;
    }
    Schema.SObjectType metaType = Schema.getGlobalDescribe().get('copado__User_Story_Metadata__c');
    if (metaType == null) {
      return 0;
    }
    Map<String, Schema.SObjectField> fields = metaType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'User_Story__c'
    });
    if (usField == null) {
      return 0;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + metaType.getDescribe().getName()
        + ' WHERE ' + usField + ' = :userStoryId'
      );
      if (rows.isEmpty()) {
        return 0;
      }
      Database.delete(rows, false);
      return rows.size();
    } catch (Exception ignore) {
      return 0;
    }
  }

  /**
   * Deploy AI package into the selected Dev org via Copado Job Template, then commit.
   * Callouts (optional Actions webhook) must run before this method's DML, or the
   * caller must invoke prepareDeployThenCommitCallout first.
   *
   * @param contentDocumentId optional ContentDocument Id already stored for the package
   */
  public static JobResult deployPackageThenCommit(
    Id userStoryId,
    String packageJson,
    String commitMessage,
    List<String> artifactPaths,
    String environmentId,
    Id contentDocumentId
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for deploy/commit.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('deployThenCommit', userStoryId, commitMessage);
      mock.summary =
        'Mock deploy-to-Dev then commit for story '
        + userStoryId
        + (String.isNotBlank(commitMessage) ? ' (' + commitMessage + ')' : '')
        + '.';
      return mock;
    }

    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException(
        'Select a Dev environment in the Status panel. Copado Builder will add it to the user story before deploy/commit.'
      );
    }
    if (findNonProductionOrg(environmentId) == null) {
      throw new CopadoAiApiService.ApiException(
        'Only non-production Dev environments are allowed. Production is never permitted.'
      );
    }
    if (String.isBlank(packageJson)) {
      throw new CopadoAiApiService.ApiException('Package JSON is required to deploy into Dev before commit.');
    }

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.deployThenCommitJobTemplate)
      ? settings.deployThenCommitJobTemplate
      : 'builder_deploy_then_commit';

    // Callouts before any DML (webhook receives inline packageJson)
    JobResult webhookJob = null;
    if (String.isNotBlank(settings.actionsWebhookPath)) {
      webhookJob = callActionsWebhook(
        settings.actionsWebhookPath,
        template,
        userStoryId,
        environmentId,
        commitMessage,
        packageJson,
        'deployThenCommit'
      );
    }

    // DML after callouts: store package, stamp environment, metadata, then job
    Id packageDocId = contentDocumentId;
    if (packageDocId == null) {
      packageDocId = storePackageContent(userStoryId, packageJson);
    } else {
      linkContentToUserStory(packageDocId, userStoryId);
    }

    assignEnvironmentToUserStory(userStoryId, environmentId);
    List<String> paths = artifactPaths;
    if (paths == null || paths.isEmpty()) {
      paths = extractArtifactPathsFromPackage(packageJson);
    }
    Integer metaCount = replaceUserStoryMetadata(userStoryId, paths, packageJson);

    // DataJson.fileWithSelectedChanges is built from User Story Metadata (created above).
    Map<String, Object> dataPayload = buildDeployThenCommitData(
      userStoryId,
      environmentId,
      commitMessage,
      packageDocId,
      packageJson
    );

    // Copado ties Git commits to the User Story via a User Story Commit record.
    // Parent CreateExecution on that record (not only the US) so selections + commit
    // land on the story the same way the Commit Changes UI does.
    Id userStoryCommitId = createUserStoryCommit(
      userStoryId,
      commitMessage,
      dataPayload.containsKey('fileWithSelectedChanges')
        ? resolveContentDocumentId(
            (Id) String.valueOf(dataPayload.get('fileWithSelectedChanges'))
          )
        : null
    );
    Id executionParentId = userStoryCommitId != null ? userStoryCommitId : userStoryId;
    if (userStoryCommitId != null) {
      dataPayload.put('userStoryCommitId', String.valueOf(userStoryCommitId));
    }

    JobResult job = webhookJob;
    if (job == null) {
      job = usableExecutionOrNull(
        tryCreateExecutionApi(template, executionParentId, environmentId, dataPayload)
      );
    }
    if (job == null) {
      job = tryCreateJobExecution(template, executionParentId, environmentId, commitMessage, dataPayload);
    }
    if (job == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not start Copado Job Template "'
        + template
        + '". Install the builder_deploy_then_commit template (see copado-functions/README.md), '
        + 'set Deploy Then Commit Job Template to the template API Name (e.g. builder_deploy_then_commit), '
        + 'and ensure your user has the Copado Job Engine permission set.'
      );
    }

    if (packageDocId != null) {
      job.contentDocumentId = String.valueOf(packageDocId);
    }
    if (String.isNotBlank(job.jobId) && !job.jobId.startsWith('create-execution')) {
      try {
        stampJobExecutionCommitContext(
          (Id) job.jobId,
          userStoryId,
          userStoryCommitId
        );
      } catch (Exception ignore) {
      }
    }
    job.summary =
      'Commit started for '
      + blankToOrgName(environmentId)
      + ' ('
      + metaCount
      + ' component'
      + (metaCount == 1 ? '' : 's')
      + '). Job '
      + job.jobId
      + '.';
    return job;
  }

  /**
   * Deploy AI package into the selected Dev org only (no Git commit).
   * Parent CreateExecution on the User Story (not USC).
   */
  public static JobResult deployPackageToDev(
    Id userStoryId,
    String packageJson,
    String message,
    List<String> artifactPaths,
    String environmentId,
    Id contentDocumentId
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for deploy.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('deployOnly', userStoryId, message);
      mock.summary =
        'Mock deploy to Dev for story '
        + userStoryId
        + (String.isNotBlank(message) ? ' (' + message + ')' : '')
        + '.';
      return mock;
    }

    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException(
        'Select a Dev environment in the Status panel. Copado Builder will add it to the user story before deploy.'
      );
    }
    if (findNonProductionOrg(environmentId) == null) {
      throw new CopadoAiApiService.ApiException(
        'Only non-production Dev environments are allowed. Production is never permitted.'
      );
    }
    if (String.isBlank(packageJson)) {
      throw new CopadoAiApiService.ApiException(
        'Package JSON is required to deploy into Dev. Run Build first.'
      );
    }

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.deployJobTemplate)
      ? settings.deployJobTemplate
      : 'builder_deploy_only';

    JobResult webhookJob = null;
    if (String.isNotBlank(settings.actionsWebhookPath)) {
      webhookJob = callActionsWebhook(
        settings.actionsWebhookPath,
        template,
        userStoryId,
        environmentId,
        message,
        packageJson,
        'deployOnly'
      );
    }

    Id packageDocId = contentDocumentId;
    if (packageDocId == null) {
      packageDocId = storePackageContent(userStoryId, packageJson);
    } else {
      linkContentToUserStory(packageDocId, userStoryId);
    }

    assignEnvironmentToUserStory(userStoryId, environmentId);
    List<String> paths = artifactPaths;
    if (paths == null || paths.isEmpty()) {
      paths = extractArtifactPathsFromPackage(packageJson);
    }
    Integer metaCount = replaceUserStoryMetadata(userStoryId, paths, packageJson);

    Map<String, Object> dataPayload = buildDeployThenCommitData(
      userStoryId,
      environmentId,
      message,
      packageDocId,
      packageJson
    );
    dataPayload.put('action', 'deployOnly');

    JobResult job = webhookJob;
    if (job == null) {
      job = usableExecutionOrNull(
        tryCreateExecutionApi(template, userStoryId, environmentId, dataPayload)
      );
    }
    if (job == null) {
      job = tryCreateJobExecution(template, userStoryId, environmentId, message, dataPayload);
    }
    if (job == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not start Copado Job Template "'
        + template
        + '". Install the builder_deploy_only template (see copado-functions/README.md), '
        + 'set Deploy Job Template to the template API Name (e.g. builder_deploy_only), '
        + 'and ensure your user has the Copado Job Engine permission set.'
      );
    }

    if (packageDocId != null) {
      job.contentDocumentId = String.valueOf(packageDocId);
    }
    job.summary =
      'Deploy started for '
      + blankToOrgName(environmentId)
      + ' ('
      + metaCount
      + ' component'
      + (metaCount == 1 ? '' : 's')
      + '). Job '
      + job.jobId
      + '.';
    return job;
  }

  /**
   * Commit already-deployed package metadata from Dev into the user story
   * feature branch. Does not deploy.
   * @param recreateFeatureBranch when true, Copado deletes + recreates the feature
   *   branch from baseBranch then commits (org-verified: CommitAction / DataJson flag).
   */
  public static JobResult commitPackageFromDev(
    Id userStoryId,
    String packageJson,
    String commitMessage,
    List<String> artifactPaths,
    String environmentId,
    Id contentDocumentId
  ) {
    return commitPackageFromDev(
      userStoryId,
      packageJson,
      commitMessage,
      artifactPaths,
      environmentId,
      contentDocumentId,
      false
    );
  }

  public static JobResult commitPackageFromDev(
    Id userStoryId,
    String packageJson,
    String commitMessage,
    List<String> artifactPaths,
    String environmentId,
    Id contentDocumentId,
    Boolean recreateFeatureBranch
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for commit.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('commitOnly', userStoryId, commitMessage);
      mock.summary =
        'Mock commit from Dev for story '
        + userStoryId
        + (recreateFeatureBranch == true ? ' (recreate feature branch)' : '')
        + (String.isNotBlank(commitMessage) ? ' (' + commitMessage + ')' : '')
        + '.';
      return mock;
    }

    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException(
        'Select a Dev environment in the Status panel before committing.'
      );
    }
    if (findNonProductionOrg(environmentId) == null) {
      throw new CopadoAiApiService.ApiException(
        'Only non-production Dev environments are allowed. Production is never permitted.'
      );
    }

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.commitJobTemplate)
      ? settings.commitJobTemplate
      : 'sfdx_commit_1';

    Id packageDocId = contentDocumentId;
    if (packageDocId == null && String.isNotBlank(packageJson)) {
      packageDocId = storePackageContent(userStoryId, packageJson);
    } else if (packageDocId != null) {
      linkContentToUserStory(packageDocId, userStoryId);
    }

    assignEnvironmentToUserStory(userStoryId, environmentId);
    List<String> paths = artifactPaths;
    if (paths == null || paths.isEmpty()) {
      paths = extractArtifactPathsFromPackage(packageJson);
    }
    Integer metaCount = replaceUserStoryMetadata(userStoryId, paths, packageJson);

    Map<String, Object> dataPayload = buildDeployThenCommitData(
      userStoryId,
      environmentId,
      commitMessage,
      packageDocId,
      packageJson
    );
    dataPayload.put('action', 'commitOnly');
    // Org-verified JE DataJson key (JE-036 / US-0000049).
    dataPayload.put('recreateFeatureBranch', recreateFeatureBranch == true);
    // Prefer selections over a large inline package for commit-only.
    if (dataPayload.containsKey('packageJson')
      && String.isNotBlank(packageJson)
      && packageJson.length() >= 90000) {
      dataPayload.remove('packageJson');
    }

    List<Map<String, Object>> selections = resolveCommitSelections(userStoryId, packageJson);

    // Preferred path (Copado AI / this org): CommitAction with recreateFeatureBranch.
    JobResult viaAction = tryCommitAction(
      userStoryId,
      commitMessage,
      selections,
      recreateFeatureBranch == true
    );
    if (viaAction != null && String.isNotBlank(viaAction.jobId)) {
      if (packageDocId != null) {
        viaAction.contentDocumentId = String.valueOf(packageDocId);
      }
      viaAction.summary =
        (recreateFeatureBranch == true
          ? 'Recreate feature branch + commit started for '
          : 'Commit started via CommitAction for ')
        + blankToOrgName(environmentId)
        + ' ('
        + metaCount
        + ' component'
        + (metaCount == 1 ? '' : 's')
        + '). Job '
        + viaAction.jobId
        + '.';
      return viaAction;
    }

    Id userStoryCommitId = createUserStoryCommit(
      userStoryId,
      commitMessage,
      dataPayload.containsKey('fileWithSelectedChanges')
        ? resolveContentDocumentId(
            (Id) String.valueOf(dataPayload.get('fileWithSelectedChanges'))
          )
        : null
    );
    Id executionParentId = userStoryCommitId != null ? userStoryCommitId : userStoryId;
    if (userStoryCommitId != null) {
      dataPayload.put('userStoryCommitId', String.valueOf(userStoryCommitId));
    }

    JobResult job = usableExecutionOrNull(
      tryCreateExecutionApi(template, executionParentId, environmentId, dataPayload)
    );
    if (job == null) {
      job = tryCreateJobExecution(template, executionParentId, environmentId, commitMessage, dataPayload);
    }
    if (job == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not start Copado Commit (CommitAction and Job Template "'
        + template
        + '" both failed). Set Commit Job Template to the template API Name (e.g. sfdx_commit_1), '
        + 'and ensure your user has the Copado Job Engine permission set.'
      );
    }

    if (packageDocId != null) {
      job.contentDocumentId = String.valueOf(packageDocId);
    }
    if (String.isNotBlank(job.jobId) && !job.jobId.startsWith('create-execution')) {
      try {
        stampJobExecutionCommitContext(
          (Id) job.jobId,
          userStoryId,
          userStoryCommitId
        );
      } catch (Exception ignore) {
      }
    }
    job.summary =
      (recreateFeatureBranch == true
        ? 'Recreate feature branch + commit started for '
        : 'Commit started for ')
      + blankToOrgName(environmentId)
      + ' ('
      + metaCount
      + ' component'
      + (metaCount == 1 ? '' : 's')
      + '). Job '
      + job.jobId
      + '.';
    return job;
  }

  /**
   * Org-verified commit path: copado.CommitAction.commitChanges with
   * recreateFeatureBranch (JE-036 DataJson / Copado AI).
   */
  @TestVisible
  private static JobResult tryCommitAction(
    Id userStoryId,
    String commitMessage,
    List<Map<String, Object>> selections,
    Boolean recreateFeatureBranch
  ) {
    if (userStoryId == null || selections == null || selections.isEmpty()) {
      return null;
    }
    try {
      List<copado.CommitAction.Change> changes = new List<copado.CommitAction.Change>();
      for (Map<String, Object> sel : selections) {
        if (sel == null || sel.get('n') == null || sel.get('t') == null) {
          continue;
        }
        copado.CommitAction.Change ch = new copado.CommitAction.Change();
        ch.n = String.valueOf(sel.get('n'));
        ch.t = String.valueOf(sel.get('t'));
        ch.c = sel.get('c') != null ? String.valueOf(sel.get('c')) : 'SFDX';
        ch.a = sel.get('a') != null ? String.valueOf(sel.get('a')) : 'Add';
        // Module is empty string in this org (not force-app/main/default).
        ch.m = '';
        changes.add(ch);
      }
      if (changes.isEmpty()) {
        return null;
      }

      copado.CommitAction.Request req = new copado.CommitAction.Request();
      req.userStoryId = userStoryId;
      req.changes = changes;
      req.message = String.isNotBlank(commitMessage)
        ? commitMessage
        : ('Copado Builder commit for ' + String.valueOf(userStoryId));
      req.executeCommit = true;
      // KEY FLAG: true deletes remote feature branch, recreates from baseBranch, commits.
      req.recreateFeatureBranch = recreateFeatureBranch == true;

      List<copado.CommitAction.Response> responses =
        copado.CommitAction.commitChanges(new List<copado.CommitAction.Request>{ req });
      if (responses == null || responses.isEmpty() || responses[0] == null) {
        return null;
      }
      copado.CommitAction.Response resp = responses[0];
      Id jeId = null;
      if (resp.jobExecution != null) {
        jeId = resp.jobExecution.Id;
      }
      if (jeId == null) {
        return null;
      }
      JobResult job = new JobResult();
      job.jobId = String.valueOf(jeId);
      job.status = 'In Progress';
      job.method = 'CommitAction';
      job.summary =
        'CommitAction started (recreateFeatureBranch='
        + String.valueOf(recreateFeatureBranch == true)
        + '). Job '
        + job.jobId
        + '.';
      return job;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'tryCommitAction: ' + ex.getMessage());
      return null;
    }
  }

  /**
   * True when the Job Execution finished successfully (complete and not failed).
   * Mock mode treats blank / mock-* job ids as successful.
   */
  public static Boolean isJobExecutionSuccessful(String jobId) {
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      if (String.isBlank(jobId) || jobId.startsWith('mock')) {
        return true;
      }
      JobStatus mockStatus = getJobExecutionStatus(jobId);
      return mockStatus.isComplete == true && mockStatus.isFailed != true;
    }
    if (String.isBlank(jobId)) {
      return false;
    }
    JobStatus status = getJobExecutionStatus(jobId);
    return status.isComplete == true && status.isFailed != true;
  }

  private static String blankToOrgName(String environmentId) {
    CopadoAiApiService.OrgInfo org = findNonProductionOrg(environmentId);
    if (org != null && String.isNotBlank(org.orgName)) {
      return org.orgName;
    }
    return 'Dev';
  }

  private static Map<String, Object> buildDeployThenCommitData(
    Id userStoryId,
    String environmentId,
    String commitMessage,
    Id contentDocumentId,
    String packageJson
  ) {
    String message = String.isNotBlank(commitMessage)
      ? commitMessage
      : ('Copado Builder commit for ' + String.valueOf(userStoryId));

    Map<String, Object> payload = new Map<String, Object>{
      'userStoryId' => String.valueOf(userStoryId),
      'environmentId' => environmentId,
      // Copado Commit function reads DataJson.message (not commitMessage)
      'message' => message,
      'commitMessage' => message,
      'recreateFeatureBranch' => false,
      'source' => 'CopadoBuilder',
      'action' => 'deployThenCommit'
    };
    if (contentDocumentId != null) {
      payload.put('contentDocumentId', String.valueOf(contentDocumentId));
    }

    Id envRecordId = resolveEnvironmentRecordId(environmentId);
    if (envRecordId != null) {
      payload.put('environmentRecordId', String.valueOf(envRecordId));
    }

    Map<String, String> gitCtx = getUserStoryGitContext(userStoryId);
    if (gitCtx != null) {
      if (String.isNotBlank(gitCtx.get('featureBranch'))) {
        payload.put('featureBranchName', gitCtx.get('featureBranch'));
      }
      if (String.isNotBlank(gitCtx.get('baseBranch'))) {
        payload.put('baseBranch', gitCtx.get('baseBranch'));
      }
      if (String.isNotBlank(gitCtx.get('pipelineId'))) {
        payload.put('pipelineId', gitCtx.get('pipelineId'));
      }
    }
    // Commit function requires featureBranch — derive from US Name when Git Branch is blank
    // (common on first commit for a new Builder story).
    if (!payload.containsKey('featureBranchName')
      || String.isBlank(String.valueOf(payload.get('featureBranchName')))) {
      String derived = deriveFeatureBranchName(userStoryId);
      if (String.isNotBlank(derived)) {
        payload.put('featureBranchName', derived);
        ensureUserStoryGitBranch(userStoryId, derived);
      }
    }
    if (!payload.containsKey('baseBranch')
      || String.isBlank(String.valueOf(payload.get('baseBranch')))) {
      payload.put('baseBranch', 'main');
    }
    // recreateFeatureBranch stays JSON boolean false (set above). Do not overwrite
    // with the string "false" — Copado Skip Step Conditions (Apex Tests) reject that.

    // Commit selections: package artifacts are source of truth for Builder builds.
    // Preferring USM alone dropped layout/profile when only the field row existed.
    List<Map<String, Object>> selections = resolveCommitSelections(userStoryId, packageJson);
    if (!selections.isEmpty()) {
      payload.put('changes', selections);
      Id selectionsDocId = storeCommitSelectionsFile(userStoryId, selections);
      if (selectionsDocId != null) {
        payload.put('fileWithSelectedChanges', String.valueOf(selectionsDocId));
      }
    } else if (String.isNotBlank(packageJson)
      && !extractArtifactPathsFromPackage(packageJson).isEmpty()) {
      throw new CopadoAiApiService.ApiException(
        'Could not build Copado commit selections from User Story Metadata / package. '
          + 'Without fileWithSelectedChanges the commit step reports '
          + '"There are no changes to be committed".'
      );
    }

    // Fail early if we cannot resolve Environment Id for CreateExecution sourceId.
    // Credential Id alone is not enough — {$Source.Credential.*} needs Environment.
    if (envRecordId == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not resolve a Copado Environment from the selected Dev org credential. '
          + 'Open the Org Credential in Copado and confirm it is linked to a Dev Environment, '
          + 'then re-select it in Builder.'
      );
    }

    // Target org identity so the Function can pass --target-org (Copado authenticates
    // the credential's org but does not set a default in custom functions).
    Map<String, String> orgIdentity = getOrgCredentialIdentity(environmentId);
    if (orgIdentity != null) {
      if (String.isNotBlank(orgIdentity.get('username'))) {
        payload.put('targetUsername', orgIdentity.get('username'));
      }
      if (String.isNotBlank(orgIdentity.get('orgId'))) {
        payload.put('targetOrgId', orgIdentity.get('orgId'));
      }
    }
    // Prefer inline package for the Function (keeps Function self-contained).
    if (String.isNotBlank(packageJson) && packageJson.length() < 90000) {
      try {
        payload.put('packageJson', JSON.deserializeUntyped(packageJson));
      } catch (Exception ex) {
        payload.put('packageJson', packageJson);
      }
    }
    return payload;
  }

  /**
   * Feature branch / base branch / pipeline from the User Story — required by the
   * standard Copado Commit function DataJson expressions.
   */
  @TestVisible
  private static Map<String, String> getUserStoryGitContext(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String branchField = firstExisting(fields, new List<String>{
      'copado__Git_Branch__c', 'copado__Branch__c', 'copado__Feature_Branch__c'
    });
    String baseField = firstExisting(fields, new List<String>{
      'copado__Base_Branch__c', 'copado__Environment_Base_Branch__c'
    });
    String projectField = firstExisting(fields, new List<String>{
      'copado__Project__c'
    });
    List<String> selectFields = new List<String>{ 'Id', 'Name' };
    if (branchField != null) {
      selectFields.add(branchField);
    }
    if (baseField != null) {
      selectFields.add(baseField);
    }
    if (projectField != null) {
      selectFields.add(projectField);
    }
    Map<String, String> out = new Map<String, String>();
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
          + ' FROM ' + usType.getDescribe().getName()
          + ' WHERE Id = :userStoryId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return null;
      }
      SObject us = rows[0];
      if (branchField != null && us.get(branchField) != null
        && String.isNotBlank(String.valueOf(us.get(branchField)))) {
        out.put('featureBranch', String.valueOf(us.get(branchField)));
      } else if (us.get('Name') != null) {
        // First commit: Copado convention feature/<US Name>
        out.put('featureBranch', 'feature/' + String.valueOf(us.get('Name')).trim());
      }
      if (baseField != null && us.get(baseField) != null) {
        out.put('baseBranch', String.valueOf(us.get(baseField)));
      }
      if (projectField != null && us.get(projectField) != null) {
        Id projectId = (Id) us.get(projectField);
        Id pipelineId = resolvePipelineIdForProject(projectId);
        if (pipelineId != null) {
          out.put('pipelineId', String.valueOf(pipelineId));
        }
        if (!out.containsKey('baseBranch')) {
          String mainBranch = resolvePipelineMainBranch(pipelineId);
          if (String.isNotBlank(mainBranch)) {
            out.put('baseBranch', mainBranch);
          }
        }
      }
    } catch (Exception ignore) {
      return out.isEmpty() ? null : out;
    }
    return out.isEmpty() ? null : out;
  }

  @TestVisible
  private static String deriveFeatureBranchName(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Name FROM ' + userStoryId.getSObjectType().getDescribe().getName()
          + ' WHERE Id = :userStoryId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get('Name') != null) {
        return 'feature/' + String.valueOf(rows[0].get('Name')).trim();
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /** Stamp Git Branch on the US when blank so Copado Commit / UI stay consistent. */
  private static void ensureUserStoryGitBranch(Id userStoryId, String featureBranch) {
    if (userStoryId == null || String.isBlank(featureBranch)) {
      return;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String branchField = firstCreateable(fields, new List<String>{
      'copado__Git_Branch__c', 'copado__Branch__c', 'copado__Feature_Branch__c'
    });
    if (branchField == null) {
      return;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Id,' + branchField + ' FROM ' + usType.getDescribe().getName()
          + ' WHERE Id = :userStoryId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return;
      }
      if (rows[0].get(branchField) != null
        && String.isNotBlank(String.valueOf(rows[0].get(branchField)))) {
        return;
      }
      SObject upd = usType.newSObject(userStoryId);
      upd.put(branchField, truncate(featureBranch, 255));
      update upd;
    } catch (Exception ignore) {
    }
  }

  private static Id resolvePipelineIdForProject(Id projectId) {
    if (projectId == null) {
      return null;
    }
    Schema.SObjectType projectType = Schema.getGlobalDescribe().get('copado__Project__c');
    if (projectType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = projectType.getDescribe().fields.getMap();
    String pipelineField = firstExisting(fields, new List<String>{
      'copado__Deployment_Flow__c', 'copado__Pipeline__c'
    });
    if (pipelineField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + pipelineField + ' FROM ' + projectType.getDescribe().getName()
          + ' WHERE Id = :projectId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(pipelineField) != null) {
        return (Id) rows[0].get(pipelineField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Next pipeline environment after source (Deployment Flow Step / Pipeline Connection).
   */
  public static Id resolveNextEnvironmentId(Id sourceEnvironmentId, Id projectId) {
    if (sourceEnvironmentId == null) {
      return null;
    }
    Id pipelineId = resolvePipelineIdForProject(projectId);
    if (pipelineId == null) {
      return null;
    }
    for (String stepObject : new List<String>{
      'copado__Deployment_Flow_Step__c', 'copado__Pipeline_Connection__c'
    }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(stepObject);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> stepFields = stepType.getDescribe().fields.getMap();
      String flowOnStep = firstExisting(stepFields, new List<String>{
        'copado__Deployment_Flow__c', 'copado__Pipeline__c'
      });
      String sourceField = firstExisting(stepFields, new List<String>{
        'copado__Source_Environment__c'
      });
      String destField = firstExisting(stepFields, new List<String>{
        'copado__Destination_Environment__c'
      });
      if (flowOnStep == null || sourceField == null || destField == null) {
        continue;
      }
      try {
        String soql =
          'SELECT ' + destField
          + ' FROM ' + stepObject
          + ' WHERE ' + flowOnStep + ' = :pipelineId'
          + ' AND ' + sourceField + ' = :sourceEnvironmentId'
          + ' LIMIT 1';
        List<SObject> rows = Database.query(soql);
        if (!rows.isEmpty() && rows[0].get(destField) != null) {
          return (Id) rows[0].get(destField);
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  /**
   * Environment display name for Status panel next-env hint.
   */
  public static String getEnvironmentName(Id environmentId) {
    if (environmentId == null) {
      return null;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return 'Mock Next Env';
    }
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Name FROM copado__Environment__c WHERE Id = :environmentId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get('Name') != null) {
        return String.valueOf(rows[0].get('Name'));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Destination Environment Id on a Promotion (Validate / Deploy-next target).
   */
  public static Id getPromotionDestinationEnvironmentId(Id promotionId) {
    if (promotionId == null || isMockDevops() || CopadoAiApiService.isMockMode()) {
      return null;
    }
    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    String destField = firstExisting(fields, new List<String>{
      'copado__Destination_Environment__c',
      'copado__To_Environment__c',
      'copado__Destination_Org__c'
    });
    if (destField == null) {
      return null;
    }
    try {
      String soql =
        'SELECT ' + destField
        + ' FROM copado__Promotion__c WHERE Id = :promotionId LIMIT 1';
      List<SObject> rows = Database.query(soql);
      if (!rows.isEmpty() && rows[0].get(destField) != null) {
        return (Id) rows[0].get(destField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Org credential Id for an Environment (for session Org_Credential_Id__c).
   */
  public static String resolveCredentialIdForEnvironment(Id environmentId) {
    if (environmentId == null) {
      return null;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return String.valueOf(environmentId);
    }
    Id credId = resolveOrgCredentialFromEnvironment(environmentId, null);
    if (credId != null) {
      return String.valueOf(credId);
    }
    // Fall back to Environment Id — assignEnvironmentToUserStory accepts either.
    return String.valueOf(environmentId);
  }

  /**
   * Validate (dry-run promote + deploy) user story changes to the next pipeline env.
   * Prefers Copado's Promote invocable (same path as UI "Validate Changes"), then
   * falls back to CreateExecution on the Promotion with Job Template API names.
   */
  public static JobResult validateUserStoryToNextEnvironment(
    Id userStoryId,
    String sourceEnvironmentCredentialOrEnvId
  ) {
    return validateUserStoryToNextEnvironment(
      userStoryId,
      sourceEnvironmentCredentialOrEnvId,
      null
    );
  }

  /**
   * Prepare Promotion then enqueue CreateExecution in a fresh transaction.
   * Calling Copado CreateExecution in the Builder request (often twice) caused
   * "Too many SOQL queries: 101".
   */
  public static JobResult validateUserStoryToNextEnvironment(
    Id userStoryId,
    String sourceEnvironmentCredentialOrEnvId,
    Id sessionId
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for validate.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('validate', userStoryId, 'next environment');
      mock.promotionId = 'mock-promotion';
      mock.summary =
        'Mock validate to next environment for story '
        + userStoryId
        + '.';
      return mock;
    }

    Id sourceEnvId = resolveEnvironmentRecordId(sourceEnvironmentCredentialOrEnvId);
    if (sourceEnvId == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not resolve source Environment from the selected Dev org credential.'
      );
    }

    Id projectId = null;
    String projectIdStr = getProjectIdFromUserStory(userStoryId);
    if (String.isNotBlank(projectIdStr)) {
      try {
        projectId = (Id) projectIdStr;
      } catch (Exception ignore) {
      }
    }

    Id destEnvId = resolveNextEnvironmentId(sourceEnvId, projectId);
    if (destEnvId == null) {
      throw new CopadoAiApiService.ApiException(
        'No next environment found on the project pipeline after the selected Dev environment.'
      );
    }

    String destEnvName = getEnvironmentName(destEnvId);
    if (isProductionLabel(destEnvName)) {
      throw new CopadoAiApiService.ApiException(
        'Validate destination looks like production. Validation to production is not allowed from Builder.'
      );
    }

    stampReadyToPromote(userStoryId);

    // Fresh or healed Draft Promotion with Pipeline stamped — never enqueue without an Id.
    Id promotionId;
    Id pipelineId;
    try {
      PromotionResolve resolved = resolveValidatePromotion(
        userStoryId,
        sourceEnvId,
        destEnvId,
        projectId,
        true
      );
      promotionId = resolved.promotionId;
      pipelineId = resolved.pipelineId;
    } catch (CopadoAiApiService.ApiException ex) {
      throw ex;
    } catch (Exception ex) {
      throw new CopadoAiApiService.ApiException(
        'Could not create Copado Promotion for Validate: ' + ex.getMessage()
      );
    }
    if (promotionId == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not create a Copado Promotion for Validate (no Id returned).'
      );
    }

    DevopsSettings settings = getDevopsSettings();
    String promoteTemplate = String.isNotBlank(settings.validatePromoteJobTemplate)
      ? settings.validatePromoteJobTemplate
      : 'sfdx_promote_1';
    String deployTemplate = String.isNotBlank(settings.validateDeployJobTemplate)
      ? settings.validateDeployJobTemplate
      : 'sfdx_deploy_1';
    // Seed only — Queueable rebuilds OOTB Promotion / PromotionDeployment DataJson.
    Map<String, Object> dataPayload = new Map<String, Object>{
      'deploymentDryRun' => true,
      'action' => 'validate'
    };
    if (pipelineId != null) {
      dataPayload.put('pipelineId', String.valueOf(pipelineId));
    }
    if (promotionId != null) {
      dataPayload.put('promotionId', String.valueOf(promotionId));
    }

    JobResult result = new JobResult();
    result.method = 'CreateExecution';
    result.promotionId = String.valueOf(promotionId);

    // Stamp Promotion Id before enqueue so the queueable can recover it.
    if (sessionId != null) {
      try {
        update new AI_Builder_Session__c(
          Id = sessionId,
          Last_Promotion_Id__c = String.valueOf(promotionId),
          Last_Job_Action__c = 'Validate',
          Last_Job_Id__c = 'validate-queued',
          Current_Step__c = 'Validating',
          Summary__c =
            '[BuilderValidate/v27] Validate queued (Promotion '
            + promotionId
            + '). CreateExecution runs in a fresh transaction.'
        );
      } catch (Exception ignore) {
      }
    }

    // Never run CreateExecution inline — Copado promote/deploy burns SOQL and hits 101
    // in the Builder request. Queueable gets a fresh 100-query budget.
    if (sessionId == null) {
      return runQueuedValidateExecution(
        userStoryId,
        promotionId,
        sourceEnvId,
        destEnvId,
        pipelineId,
        sourceEnvironmentCredentialOrEnvId,
        destEnvName,
        promoteTemplate,
        deployTemplate,
        JSON.serialize(dataPayload)
      );
    }

    System.enqueueJob(
      new CopadoValidateQueueable(
        sessionId,
        userStoryId,
        promotionId,
        sourceEnvId,
        destEnvId,
        pipelineId,
        sourceEnvironmentCredentialOrEnvId,
        destEnvName,
        promoteTemplate,
        deployTemplate,
        JSON.serialize(dataPayload)
      )
    );

    String destLabel = String.isNotBlank(destEnvName) ? destEnvName : String.valueOf(destEnvId);
    result.jobId = 'validate-queued';
    result.status = 'In Progress';
    result.summary =
      '[BuilderValidate/v27] Validate queued toward '
      + destLabel
      + ' (Promotion '
      + promotionId
      + '). Job starts in a moment — use the refresh icon next to In progress if Status does not update.';
    return result;
  }

  /**
   * Real deploy to next pipeline env after Validate. Queues CreateExecution with
   * dry-run flags off (fresh SOQL budget via CopadoValidateQueueable).
   */
  public static JobResult deployUserStoryToNextEnvironment(
    Id userStoryId,
    String sourceEnvironmentCredentialOrEnvId,
    Id sessionId,
    Id existingPromotionId
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for deploy to next.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('deployNext', userStoryId, 'next environment');
      mock.promotionId = existingPromotionId != null
        ? String.valueOf(existingPromotionId)
        : 'mock-promotion';
      mock.summary =
        'Mock deploy to next environment for story '
        + userStoryId
        + '.';
      return mock;
    }

    Id sourceEnvId = resolveEnvironmentRecordId(sourceEnvironmentCredentialOrEnvId);
    if (sourceEnvId == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not resolve source Environment from the selected Dev org credential.'
      );
    }

    Id projectId = null;
    String projectIdStr = getProjectIdFromUserStory(userStoryId);
    if (String.isNotBlank(projectIdStr)) {
      try {
        projectId = (Id) projectIdStr;
      } catch (Exception ignore) {
      }
    }

    Id destEnvId = resolveNextEnvironmentId(sourceEnvId, projectId);
    if (destEnvId == null) {
      throw new CopadoAiApiService.ApiException(
        'No next environment found on the project pipeline after the selected Dev environment.'
      );
    }

    String destEnvName = getEnvironmentName(destEnvId);
    if (isProductionLabel(destEnvName)) {
      throw new CopadoAiApiService.ApiException(
        'Deploy destination looks like production. Deploy to production is not allowed from Builder.'
      );
    }

    stampReadyToPromote(userStoryId);

    Id promotionId = existingPromotionId;
    if (promotionId == null) {
      try {
        promotionId = createPromotionRecord(userStoryId, sourceEnvId, destEnvId, projectId);
      } catch (CopadoAiApiService.ApiException ex) {
        throw ex;
      } catch (Exception ex) {
        throw new CopadoAiApiService.ApiException(
          'Could not create Copado Promotion for deploy to next: ' + ex.getMessage()
        );
      }
    }

    DevopsSettings settings = getDevopsSettings();
    String promoteTemplate = String.isNotBlank(settings.validatePromoteJobTemplate)
      ? settings.validatePromoteJobTemplate
      : 'sfdx_promote_1';
    String deployTemplate = String.isNotBlank(settings.validateDeployJobTemplate)
      ? settings.validateDeployJobTemplate
      : 'sfdx_deploy_1';

    Id pipelineId = resolvePipelineIdForProject(projectId);
    // Seed only — Queueable rebuilds OOTB Promotion / PromotionDeployment DataJson.
    Map<String, Object> dataPayload = new Map<String, Object>{
      'deploymentDryRun' => false,
      'action' => 'deployNext'
    };
    if (pipelineId != null) {
      dataPayload.put('pipelineId', String.valueOf(pipelineId));
    }
    if (promotionId != null) {
      dataPayload.put('promotionId', String.valueOf(promotionId));
    }

    JobResult result = new JobResult();
    result.method = 'CreateExecution';
    if (promotionId != null) {
      result.promotionId = String.valueOf(promotionId);
    }

    if (sessionId == null) {
      JobResult inline = runQueuedValidateExecution(
        userStoryId,
        promotionId,
        sourceEnvId,
        destEnvId,
        pipelineId,
        sourceEnvironmentCredentialOrEnvId,
        destEnvName,
        promoteTemplate,
        deployTemplate,
        JSON.serialize(dataPayload)
      );
      if (inline != null && String.isNotBlank(inline.summary)
        && inline.summary.startsWith('Validate ')) {
        inline.summary = inline.summary.replaceFirst('Validate ', 'Deploy ');
      }
      return inline;
    }

    System.enqueueJob(
      new CopadoValidateQueueable(
        sessionId,
        userStoryId,
        promotionId,
        sourceEnvId,
        destEnvId,
        pipelineId,
        sourceEnvironmentCredentialOrEnvId,
        destEnvName,
        promoteTemplate,
        deployTemplate,
        JSON.serialize(dataPayload),
        'DeployNext'
      )
    );

    String destLabel = String.isNotBlank(destEnvName) ? destEnvName : String.valueOf(destEnvId);
    result.jobId = 'deploy-next-queued';
    result.status = 'In Progress';
    result.summary =
      'Deploy queued toward '
      + destLabel
      + (promotionId != null ? (' (Promotion ' + promotionId + ')') : '')
      + '. Job starts in a moment — use the refresh icon next to In progress if Status does not update.';
    return result;
  }

  /**
   * Fresh-transaction Promotion start.
   * Preferred path: Copado Promotion Deployment action (creates Deployment, selections
   * file, OOTB payload, runs Pipeline Action job template, callback). Fallback: hand-built
   * OOTB Promotion / PromotionDeployment DataJson via CreateExecution.
   */
  public static JobResult runQueuedValidateExecution(
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
    Map<String, Object> seed = new Map<String, Object>();
    if (String.isNotBlank(dataJson)) {
      try {
        seed = (Map<String, Object>) JSON.deserializeUntyped(dataJson);
      } catch (Exception ignore) {
        seed = new Map<String, Object>();
      }
    }
    if (seed == null) {
      seed = new Map<String, Object>();
    }

    List<String> diagnostics = new List<String>();

    String deployApi = String.isNotBlank(deployTemplate) ? deployTemplate.trim() : 'sfdx_deploy_1';
    String promoteApi = String.isNotBlank(promoteTemplate) ? promoteTemplate.trim() : 'sfdx_promote_1';

    Boolean realDeploy =
      seed.get('action') != null
      && String.valueOf(seed.get('action')).equalsIgnoreCase('deployNext');
    Boolean dryRun = !realDeploy;
    if (seed.containsKey('deploymentDryRun')) {
      dryRun = seed.get('deploymentDryRun') == true
        || 'true'.equalsIgnoreCase(String.valueOf(seed.get('deploymentDryRun')));
    }
    String verb = realDeploy ? 'Deploy' : 'Validate';

    JobResult result = new JobResult();
    result.method = 'CreateExecution';

    // Prefer promotionId from seed DataJson when the queueable constructor lost it.
    if (promotionId == null && seed.get('promotionId') != null) {
      try {
        promotionId = (Id) String.valueOf(seed.get('promotionId'));
      } catch (Exception ignore) {
      }
    }
    if (pipelineId == null && seed.get('pipelineId') != null) {
      try {
        pipelineId = (Id) String.valueOf(seed.get('pipelineId'));
      } catch (Exception ignore) {
      }
    }
    if (pipelineId == null && promotionId != null) {
      pipelineId = readPromotionPipelineId(promotionId);
    }
    // Recover Promotion only when the Id is missing — blank Pipeline on the record is
    // expected for Source Format promotions that use Project (do not re-resolve/heal).
    if (promotionId == null
      && userStoryId != null
      && sourceEnvId != null
      && destEnvId != null) {
      try {
        Id projectId = null;
        String projectIdStr = getProjectIdFromUserStory(userStoryId);
        if (String.isNotBlank(projectIdStr)) {
          projectId = (Id) projectIdStr;
        }
        PromotionResolve resolved = resolveValidatePromotion(
          userStoryId,
          sourceEnvId,
          destEnvId,
          projectId,
          true
        );
        if (resolved.promotionId != null) {
          promotionId = resolved.promotionId;
        }
        if (resolved.pipelineId != null) {
          pipelineId = resolved.pipelineId;
        }
        diagnostics.add(
          resolved.createdNew
            ? ('Created Promotion ' + promotionId)
            : ('Using Promotion ' + promotionId)
        );
      } catch (Exception ex) {
        diagnostics.add('Promotion resolve in queueable: ' + ex.getMessage());
      }
    }
    if (promotionId != null) {
      if (pipelineId == null) {
        pipelineId = resolvePipelineIdForEnvironment(sourceEnvId);
      }
      // No-ops when Project is set (Source Format rule).
      ensurePromotionPipeline(promotionId, pipelineId);
      result.promotionId = String.valueOf(promotionId);
    }
    if (promotionId == null) {
      result.status = 'Failed';
      result.jobId = null;
      result.errorDetail = String.join(diagnostics, ' | ');
      result.summary =
        '[BuilderValidate/v27] Could not create a Copado Promotion for Validate. '
        + (String.isNotBlank(result.errorDetail) ? result.errorDetail + ' ' : '')
        + 'Confirm the User Story has a Project, the Dev environment is on the pipeline, '
        + 'and you can create Promotions in Copado.';
      return result;
    }

    String destLabelEarly =
      String.isNotBlank(destEnvName) ? destEnvName : String.valueOf(destEnvId);

    // In Queueable we have a fresh SOQL budget — prefer Copado’s official action
    // (creates Deployment, selections file, payload, starts Pipeline Action JE).
    JobResult official = tryOfficialPromotionDeploymentAction(
      promotionId,
      true,
      true,
      dryRun,
      diagnostics
    );
    if (official != null && isJobStarted(official)) {
      result.method = official.method;
      result.jobId = official.jobId;
      result.status = 'In Progress';
      result.promotionId = String.valueOf(promotionId);
      result.summary =
        '[BuilderValidate/v27] '
        + verb
        + ' started via '
        + official.method
        + ' toward '
        + destLabelEarly
        + ' (Promotion '
        + promotionId
        + '). Job '
        + result.jobId
        + '.';
      return result;
    }
    if (official != null
      && String.isNotBlank(official.jobId)
      && !official.jobId.startsWith('create-execution-pending')
      && 'Failed'.equalsIgnoreCase(official.status)) {
      result.method = official.method;
      result.jobId = official.jobId;
      result.status = 'Failed';
      result.errorDetail = String.isNotBlank(official.errorDetail)
        ? official.errorDetail
        : official.summary;
      result.summary =
        '[BuilderValidate/v27] '
        + verb
        + ' failed via '
        + official.method
        + ' (Promotion '
        + promotionId
        + '): '
        + result.errorDetail;
      return result;
    }
    diagnostics.add(
      'Official Promotion Deployment Invocable did not start a Job Execution; '
      + 'trying CreateExecution OOTB payloads.'
    );

    String sourceCredId = resolveOrgCredentialId(
      String.isNotBlank(sourceCredentialOrEnvId)
        ? sourceCredentialOrEnvId
        : (sourceEnvId != null ? String.valueOf(sourceEnvId) : null)
    );
    String destCredId = destEnvId != null
      ? resolveOrgCredentialId(String.valueOf(destEnvId))
      : null;
    if (String.isBlank(sourceCredId)) {
      diagnostics.add('Could not resolve sourceCredentialId for promote.');
    }
    if (String.isBlank(destCredId)) {
      diagnostics.add('Could not resolve destinationCredentialId for promote.');
    }
    if (String.isNotBlank(sourceCredId)
      && String.isNotBlank(destCredId)
      && sourceCredId.equals(destCredId)) {
      result.status = 'Failed';
      result.jobId = null;
      result.errorDetail =
        'sourceCredentialId equals destinationCredentialId (' + sourceCredId + ')';
      result.summary =
        'Validate requires distinct Dev → next Org Credentials. Both resolved to the same '
        + 'credential. Check the selected Dev org and that the next pipeline environment '
        + '(int) has its own Org Credential.';
      return result;
    }

    String featureBranch = null;
    Map<String, String> gitCtx = getUserStoryGitContext(userStoryId);
    if (gitCtx != null && String.isNotBlank(gitCtx.get('featureBranch'))) {
      featureBranch = gitCtx.get('featureBranch');
    }
    if (String.isBlank(featureBranch)) {
      featureBranch = deriveFeatureBranchName(userStoryId);
      if (String.isNotBlank(featureBranch)) {
        ensureUserStoryGitBranch(userStoryId, featureBranch);
      }
    }

    String promotionBranchName = resolvePromotionBranchName(promotionId);
    String destinationBranchName = resolveEnvironmentGitBranch(destEnvId);
    if (String.isBlank(destinationBranchName) && String.isNotBlank(destEnvName)) {
      destinationBranchName = destEnvName.trim().toLowerCase().replace(' ', '-');
    }

    Id selectionsFileId = resolvePromoteSelectionsContentVersionId(userStoryId);

    Id promotedUserStoryId = findPromotedUserStoryId(promotionId, userStoryId);
    // Prefer Promotion, then Promoted User Story. User Story last — Copado promote
    // templates expect Promotion context for Merge.
    List<Id> parentCandidates = new List<Id>();
    if (promotionId != null) {
      parentCandidates.add(promotionId);
    }
    if (promotedUserStoryId != null && !parentCandidates.contains(promotedUserStoryId)) {
      parentCandidates.add(promotedUserStoryId);
    }
    diagnostics.add(
      'CreateExecution parents: promo='
      + promotionId
      + ', pus='
      + promotedUserStoryId
      + ', creds src='
      + sourceCredId
      + ' dest='
      + destCredId
      + ', templates promote='
      + promoteApi
      + ' deploy='
      + deployApi
      + ', branch='
      + featureBranch
      + ', file='
      + selectionsFileId
    );
    if (parentCandidates.isEmpty()) {
      result.status = 'Failed';
      result.jobId = null;
      result.promotionId = promotionId != null ? String.valueOf(promotionId) : null;
      result.errorDetail = String.join(diagnostics, ' | ');
      result.summary =
        '[BuilderValidate/v27] '
        + verb
        + ' could not start: Promotion Id missing for CreateExecution.';
      return result;
    }

    // 1) OOTB Promote (action: Promotion) — leaves Draft when this starts
    Map<String, Object> promotePayload = buildOotbPromotionPayload(
      userStoryId,
      promotionId,
      sourceCredId,
      destCredId,
      featureBranch,
      promotionBranchName,
      destinationBranchName,
      selectionsFileId,
      dryRun,
      pipelineId,
      sourceEnvId,
      destEnvId
    );
    JobResult promoteJob = tryCreateExecutionWithParentFallback(
      promoteApi,
      parentCandidates,
      sourceEnvId != null ? String.valueOf(sourceEnvId) : sourceCredentialOrEnvId,
      promotePayload,
      diagnostics,
      'Promote/Merge'
    );
    promoteJob = ensureJobExecutionRunning(promoteJob, promoteApi, promotePayload);

    // 2) OOTB Deploy (action: PromotionDeployment) — only after promote started
    JobResult deployJob = null;
    Boolean promoteOk = isJobStarted(promoteJob);
    Boolean soqlExhausted =
      Limits.getQueries() >= 75
      || (promoteJob != null
        && String.isNotBlank(promoteJob.errorDetail)
        && promoteJob.errorDetail.contains('Too many SOQL'));
    if (!promoteOk && promoteJob != null && 'Failed'.equalsIgnoreCase(promoteJob.status)) {
      diagnostics.add(
        'Skipped PromotionDeployment — promote/merge did not start '
        + '(Promotion stays Draft until merge runs).'
      );
    } else if (!soqlExhausted && promoteOk) {
      Id deploymentId = findOrCreatePromotionDeployment(
        promotionId,
        destEnvId,
        destCredId,
        dryRun
      );
      if (deploymentId == null) {
        diagnostics.add(
          'Could not find/create Deployment for Promotion — PromotionDeployment skipped.'
        );
      } else {
        Map<String, Object> deployPayload = buildOotbPromotionDeploymentPayload(
          userStoryId,
          promotionId,
          deploymentId,
          sourceCredId,
          destCredId,
          featureBranch,
          promotionBranchName,
          destinationBranchName,
          selectionsFileId,
          dryRun,
          pipelineId,
          sourceEnvId,
          destEnvId
        );
        List<Id> deployParents = new List<Id>();
        if (promoteJob != null && String.isNotBlank(promoteJob.parentIdUsed)) {
          try {
            deployParents.add((Id) promoteJob.parentIdUsed);
          } catch (Exception ignore) {
          }
        }
        for (Id candidate : parentCandidates) {
          if (!deployParents.contains(candidate)) {
            deployParents.add(candidate);
          }
        }
        // Prefer Deployment as parent when Copado links JE to Deployment.
        if (deploymentId != null) {
          deployParents.add(0, deploymentId);
        }
        deployJob = tryCreateExecutionWithParentFallback(
          deployApi,
          deployParents,
          destEnvId != null ? String.valueOf(destEnvId) : sourceCredentialOrEnvId,
          deployPayload,
          diagnostics,
          'Deploy'
        );
        deployJob = ensureJobExecutionRunning(deployJob, deployApi, deployPayload);
      }
    } else if (soqlExhausted) {
      diagnostics.add('Skipped deploy CreateExecution — SOQL budget after promote/merge.');
    }

    String destLabel = String.isNotBlank(destEnvName) ? destEnvName : String.valueOf(destEnvId);

    if (isJobStarted(deployJob)) {
      result.jobId = deployJob.jobId;
      result.status = 'In Progress';
      result.summary =
        verb
        + ' started toward '
        + destLabel
        + (promotionId != null ? (' (Promotion ' + promotionId + ')') : '')
        + '. Job '
        + result.jobId
        + (realDeploy
          ? '. Status updates when the deploy finishes.'
          : '. Status updates when the dry-run finishes.');
      return result;
    }
    if (isJobStarted(promoteJob)) {
      result.jobId = promoteJob.jobId;
      result.status = 'In Progress';
      result.summary =
        verb
        + ' merge started toward '
        + destLabel
        + (promotionId != null ? (' (Promotion ' + promotionId + ')') : '')
        + '. Job '
        + result.jobId
        + '. Promotion should leave Draft; deploy step may still be running or pending.';
      return result;
    }

    JobResult failedJob = null;
    if (deployJob != null
      && String.isNotBlank(deployJob.jobId)
      && !deployJob.jobId.startsWith('create-execution-pending')
      && 'Failed'.equalsIgnoreCase(deployJob.status)) {
      failedJob = deployJob;
    } else if (
      promoteJob != null
      && String.isNotBlank(promoteJob.jobId)
      && !promoteJob.jobId.startsWith('create-execution-pending')
      && 'Failed'.equalsIgnoreCase(promoteJob.status)
    ) {
      failedJob = promoteJob;
    }
    if (failedJob != null) {
      result.jobId = failedJob.jobId;
      result.status = 'Failed';
      result.errorDetail = String.isNotBlank(failedJob.errorDetail)
        ? failedJob.errorDetail
        : failedJob.summary;
      result.summary =
        verb
        + ' job failed'
        + (promotionId != null ? (' (Promotion ' + promotionId + ')') : '')
        + ': '
        + (String.isNotBlank(result.errorDetail) ? result.errorDetail : 'see Job Execution');
      return result;
    }

    result.method = promotionId != null ? 'Promotion' : 'manual';
    result.status = 'Prepared';
    result.jobId = null;
    result.promotionId = promotionId != null ? String.valueOf(promotionId) : result.promotionId;
    result.errorDetail = String.join(diagnostics, ' | ');
    result.summary =
      '[BuilderValidate/v27] '
      + verb
      + ' did not start a Job Execution for Promotion '
      + (promotionId != null ? String.valueOf(promotionId) : '(null)')
      + '. '
      + (String.isNotBlank(result.errorDetail) ? result.errorDetail + ' ' : '')
      + 'Open the Promotion → Job Executions, and confirm Validate Promote/Deploy templates '
      + '(sfdx_promote_1 / sfdx_deploy_1) and distinct Dev/int Org Credentials.';
    return result;
  }

  /**
   * Copado official Promotion action for this org:
   *   copado.Actions.PromotionService.execute(PromotionRequest)
   * (PromotionDeployAction.promote(List) does not exist here; Invocable/REST are fallbacks.)
   */
  @TestVisible
  private static JobResult tryOfficialPromotionDeploymentAction(
    Id promotionId,
    Boolean executePromotion,
    Boolean executeDeployment,
    Boolean deploymentDryRun,
    List<String> diagnostics
  ) {
    if (promotionId == null) {
      return null;
    }
    if (diagnostics == null) {
      diagnostics = new List<String>();
    }

    Datetime startedAt = Datetime.now().addSeconds(-5);
    String promoIdStr = String.valueOf(promotionId);
    Boolean dryRun = deploymentDryRun == true;
    Boolean doPromote = executePromotion != false;
    Boolean doDeploy = executeDeployment != false;

    JobResult viaService = tryActionsPromotionService(
      promoIdStr,
      doPromote,
      doDeploy,
      dryRun,
      startedAt,
      diagnostics
    );
    if (viaService != null
      && (isJobStarted(viaService) || isOfficialFailedWithJob(viaService))) {
      return viaService;
    }

    JobResult viaInvocable = tryPromotionDeploymentInvocable(
      promoIdStr,
      doPromote,
      doDeploy,
      dryRun,
      startedAt,
      diagnostics
    );
    if (viaInvocable != null
      && (isJobStarted(viaInvocable) || isOfficialFailedWithJob(viaInvocable))) {
      return viaInvocable;
    }

    JobResult viaRest = tryPromotionDeploymentRest(
      promoIdStr,
      dryRun,
      startedAt,
      diagnostics
    );
    if (viaRest != null
      && (isJobStarted(viaRest) || isOfficialFailedWithJob(viaRest))) {
      return viaRest;
    }

    return null;
  }

  private static Boolean isOfficialFailedWithJob(JobResult job) {
    return job != null
      && String.isNotBlank(job.jobId)
      && !job.jobId.startsWith('create-execution-pending')
      && 'Failed'.equalsIgnoreCase(job.status);
  }

  /**
   * Confirmed working in this org (Copado AI / Anonymous Apex):
   * copado.Actions.PromotionService.execute(PromotionRequest) with
   * executePromotion / executeDeployment / deploymentDryRun.
   */
  private static JobResult tryActionsPromotionService(
    String promotionId,
    Boolean executePromotion,
    Boolean executeDeployment,
    Boolean deploymentDryRun,
    Datetime startedAt,
    List<String> diagnostics
  ) {
    try {
      copado.Actions.PromotionRequest request = new copado.Actions.PromotionRequest();
      request.promotionId = promotionId;
      request.executePromotion = executePromotion != false;
      request.executeDeployment = executeDeployment != false;
      request.deploymentDryRun = deploymentDryRun == true;

      copado.Actions.PromotionResult response =
        copado.Actions.PromotionService.execute(request);

      Id jobId = null;
      if (response != null && response.jobExecution != null) {
        jobId = response.jobExecution.Id;
      }
      if (jobId == null) {
        jobId = findLatestJobExecutionForParent((Id) promotionId, startedAt);
      }
      if (jobId != null) {
        return jobResultForFoundExecution(
          jobId,
          'Actions.PromotionService',
          promotionId
        );
      }
      diagnostics.add(
        'Actions.PromotionService.execute returned no Job Execution Id.'
      );
    } catch (Exception ex) {
      diagnostics.add('Actions.PromotionService: ' + ex.getMessage());
    }
    return null;
  }

  private static JobResult tryPromotionDeploymentInvocable(
    String promotionId,
    Boolean executePromotion,
    Boolean executeDeployment,
    Boolean deploymentDryRun,
    Datetime startedAt,
    List<String> diagnostics
  ) {
    // Managed-package invocables need namespace (createCustomAction type, ns, name).
    List<String> actionNames = new List<String>{
      'PromotionDeployAction',
      'PromotionDeploymentAction'
    };
    for (String actionName : actionNames) {
      try {
        Invocable.Action action =
          Invocable.Action.createCustomAction('apex', 'copado', actionName);
        action.setInvocationParameter('promotionId', promotionId);
        action.setInvocationParameter('deploymentDryRun', deploymentDryRun);
        try {
          action.setInvocationParameter('transactionId', promotionId);
        } catch (Exception ignore) {
        }
        try {
          action.setInvocationParameter('executePromotion', executePromotion);
        } catch (Exception ignore) {
        }
        try {
          action.setInvocationParameter('executeDeployment', executeDeployment);
        } catch (Exception ignore) {
        }
        try {
          action.setInvocationParameter(
            'otherInformation',
            '{"doNotRunJob":false,"deploymentSteps":[]}'
          );
        } catch (Exception ignore) {
        }
        List<Invocable.Action.Result> results = action.invoke();
        if (results == null || results.isEmpty()) {
          diagnostics.add(actionName + ' (ns): empty Invocable result.');
          continue;
        }
        Invocable.Action.Result first = results[0];
        if (!first.isSuccess()) {
          String errText = 'Invocable failed';
          List<Invocable.Action.Error> errs = first.getErrors();
          if (errs != null && !errs.isEmpty()) {
            List<String> parts = new List<String>();
            for (Invocable.Action.Error e : errs) {
              parts.add(String.valueOf(e.getMessage()));
            }
            errText = String.join(parts, '; ');
          }
          diagnostics.add(actionName + ' (ns): ' + errText);
          continue;
        }
        Map<String, Object> outputs = first.getOutputParameters();
        JobResult jr = jobResultFromOutputMap(
          outputs,
          actionName,
          promotionId,
          startedAt
        );
        if (jr != null && (isJobStarted(jr) || isOfficialFailedWithJob(jr))) {
          return jr;
        }
        Id found = findLatestJobExecutionForParent((Id) promotionId, startedAt);
        if (found != null) {
          return jobResultForFoundExecution(found, actionName, promotionId);
        }
        diagnostics.add(actionName + ' (ns): Invocable OK but no Job Execution found.');
      } catch (Exception ex) {
        diagnostics.add(actionName + ' (ns): ' + ex.getMessage());
      }
    }
    return null;
  }

  /**
   * Same-org REST for PromotionDeployAction (docs prefer webhook; session works for Builder).
   */
  private static JobResult tryPromotionDeploymentRest(
    String promotionId,
    Boolean deploymentDryRun,
    Datetime startedAt,
    List<String> diagnostics
  ) {
    List<String> paths = new List<String>{
      '/services/apexrest/copado/PromotionDeployAction',
      '/services/apexrest/copado/mcwebhook'
    };
    for (String path : paths) {
      try {
        Map<String, Object> body;
        if (path.endsWith('mcwebhook')) {
          body = new Map<String, Object>{
            'action' => 'PromotionDeployment',
            'payload' => new Map<String, Object>{
              'promotionId' => promotionId,
              'deploymentDryRun' => deploymentDryRun == true,
              'otherInformation' => '{"doNotRunJob":false,"deploymentSteps":[]}'
            }
          };
        } else {
          body = new Map<String, Object>{
            'promotionId' => promotionId,
            'deploymentDryRun' => deploymentDryRun == true,
            'transactionId' => promotionId,
            'otherInformation' => '{"doNotRunJob":false,"deploymentSteps":[]}'
          };
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setTimeout(120000);
        req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        Integer code = res.getStatusCode();
        if (code < 200 || code >= 300) {
          diagnostics.add(
            path + ': HTTP ' + code + ' ' + truncate(res.getBody(), 180)
          );
          continue;
        }
        Id found = null;
        try {
          found = extractJobExecutionId(JSON.deserializeUntyped(res.getBody()));
        } catch (Exception ignore) {
        }
        if (found == null) {
          found = findLatestJobExecutionForParent((Id) promotionId, startedAt);
        }
        if (found != null) {
          return jobResultForFoundExecution(found, 'REST ' + path, promotionId);
        }
        diagnostics.add(path + ': HTTP OK but no Job Execution found.');
      } catch (Exception ex) {
        diagnostics.add(path + ': ' + ex.getMessage());
      }
    }
    return null;
  }

  private static JobResult jobResultForFoundExecution(
    Id jobId,
    String method,
    String promotionId
  ) {
    JobResult jr = new JobResult();
    jr.method = method;
    jr.promotionId = promotionId;
    jr.jobId = String.valueOf(jobId);
    JobStatus immediate = getJobExecutionStatus(String.valueOf(jobId), false);
    if (immediate != null && immediate.isFailed == true) {
      jr.status = 'Failed';
      jr.errorDetail = String.isNotBlank(immediate.errorMessage)
        ? immediate.errorMessage
        : immediate.summary;
      jr.summary = method + ' failed: ' + jr.errorDetail;
      return jr;
    }
    jr.status = 'In Progress';
    jr.summary = 'Started ' + method + '. Job ' + jr.jobId;
    return jr;
  }

  private static JobResult jobResultFromOutputMap(
    Map<String, Object> outputs,
    String method,
    String promotionId,
    Datetime startedAt
  ) {
    if (outputs == null || outputs.isEmpty()) {
      return null;
    }
    Id jobId = extractJobExecutionId(outputs.get('jobExecution'));
    if (jobId == null) {
      jobId = extractJobExecutionId(outputs.get('jobExecutionId'));
    }
    if (jobId == null) {
      jobId = extractJobExecutionId(outputs.get('Id'));
    }
    if (jobId == null && String.isNotBlank(promotionId)) {
      try {
        jobId = findLatestJobExecutionForParent((Id) promotionId, startedAt);
      } catch (Exception ignore) {
      }
    }
    if (jobId == null) {
      return null;
    }
    return jobResultForFoundExecution(jobId, method, promotionId);
  }

  private static Id extractJobExecutionId(Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof Id) {
      return (Id) value;
    }
    if (value instanceof SObject) {
      return ((SObject) value).Id;
    }
    if (value instanceof Map<String, Object>) {
      Map<String, Object> m = (Map<String, Object>) value;
      if (m.get('Id') != null) {
        try {
          return (Id) String.valueOf(m.get('Id'));
        } catch (Exception ignore) {
        }
      }
    }
    String asStr = String.valueOf(value);
    if (String.isNotBlank(asStr) && looksLikeSalesforceId(asStr)) {
      try {
        return (Id) asStr;
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  /**
   * OOTB SFDX Promote DataJson (action: Promotion).
   * Matches Copado UI Validate Changes — not Builder’s old validate/environmentRecordId shape.
   */
  @TestVisible
  private static Map<String, Object> buildOotbPromotionPayload(
    Id userStoryId,
    Id promotionId,
    String sourceCredentialId,
    String destinationCredentialId,
    String featureBranch,
    String promotionBranchName,
    String destinationBranchName,
    Id fileWithSelectedChanges,
    Boolean deploymentDryRun,
    Id pipelineId,
    Id sourceEnvId,
    Id destEnvId
  ) {
    Map<String, Object> payload = new Map<String, Object>{
      'action' => 'Promotion',
      'executePromotion' => true,
      'executeDeployment' => true,
      'deploymentDryRun' => deploymentDryRun == true,
      'isBackPromotion' => false,
      'poolQueueStrategy' => 'target',
      'poolEnvironmentFound' => false,
      'blockQueueForTransaction' => true,
      'otherInformation' => '{"doNotRunJob":false,"deploymentSteps":[]}'
    };
    if (userStoryId != null) {
      payload.put('userStoryIds', new List<String>{ String.valueOf(userStoryId) });
    }
    // OOTB uses a string array of feature branches (not a map keyed by US Id).
    if (String.isNotBlank(featureBranch)) {
      payload.put('userStoryBranches', new List<String>{ featureBranch });
    }
    if (String.isNotBlank(sourceCredentialId)) {
      payload.put('sourceCredentialId', sourceCredentialId);
    }
    if (String.isNotBlank(destinationCredentialId)) {
      payload.put('destinationCredentialId', destinationCredentialId);
    }
    if (promotionId != null) {
      payload.put('promotionId', String.valueOf(promotionId));
    }
    if (String.isNotBlank(promotionBranchName)) {
      payload.put('promotionBranchName', promotionBranchName);
    }
    if (String.isNotBlank(destinationBranchName)) {
      payload.put('destinationBranchName', destinationBranchName);
    }
    if (fileWithSelectedChanges != null) {
      payload.put('fileWithSelectedChanges', String.valueOf(fileWithSelectedChanges));
    }
    // Internal — stripped from DataJson; used for CreateExecution sourceId/destinationId.
    if (pipelineId != null) {
      payload.put('_builderPipelineId', String.valueOf(pipelineId));
    }
    if (sourceEnvId != null) {
      payload.put('_builderSourceEnvironmentId', String.valueOf(sourceEnvId));
    }
    if (destEnvId != null) {
      payload.put('_builderDestinationEnvironmentId', String.valueOf(destEnvId));
    }
    return payload;
  }

  /**
   * OOTB SFDX Deploy DataJson (action: PromotionDeployment).
   */
  @TestVisible
  private static Map<String, Object> buildOotbPromotionDeploymentPayload(
    Id userStoryId,
    Id promotionId,
    Id deploymentId,
    String sourceCredentialId,
    String destinationCredentialId,
    String featureBranch,
    String promotionBranchName,
    String destinationBranchName,
    Id fileWithSelectedChanges,
    Boolean deploymentDryRun,
    Id pipelineId,
    Id sourceEnvId,
    Id destEnvId
  ) {
    Map<String, Object> payload = new Map<String, Object>{
      'action' => 'PromotionDeployment',
      'deploymentDryRun' => deploymentDryRun == true,
      'poolQueueStrategy' => 'target',
      'poolEnvironmentFound' => false,
      'otherInformation' => '{"doNotRunJob":false,"deploymentSteps":[]}'
    };
    if (deploymentId != null) {
      payload.put('deploymentId', String.valueOf(deploymentId));
    }
    if (promotionId != null) {
      String promo = String.valueOf(promotionId);
      payload.put('promotionId', promo);
      payload.put('transactionId', promo);
    }
    if (userStoryId != null) {
      payload.put('userStoryIds', new List<String>{ String.valueOf(userStoryId) });
    }
    if (String.isNotBlank(featureBranch)) {
      payload.put('userStoryBranches', new List<String>{ featureBranch });
    }
    if (String.isNotBlank(promotionBranchName)) {
      payload.put('promotionBranchName', promotionBranchName);
    }
    if (String.isNotBlank(destinationBranchName)) {
      payload.put('destinationBranchName', destinationBranchName);
    }
    if (fileWithSelectedChanges != null) {
      payload.put('fileWithSelectedChanges', String.valueOf(fileWithSelectedChanges));
    }
    if (pipelineId != null) {
      payload.put('_builderPipelineId', String.valueOf(pipelineId));
    }
    if (sourceEnvId != null) {
      payload.put('_builderSourceEnvironmentId', String.valueOf(sourceEnvId));
    }
    if (destEnvId != null) {
      payload.put('_builderDestinationEnvironmentId', String.valueOf(destEnvId));
    }
    return payload;
  }

  private static String resolvePromotionBranchName(Id promotionId) {
    if (promotionId == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Name FROM copado__Promotion__c WHERE Id = :promotionId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get('Name') != null) {
        String name = String.valueOf(rows[0].get('Name')).trim();
        if (String.isNotBlank(name)) {
          return name.startsWith('promotion/') ? name : ('promotion/' + name);
        }
      }
    } catch (Exception ignore) {
    }
    return 'promotion/' + String.valueOf(promotionId);
  }

  private static String resolveEnvironmentGitBranch(Id environmentId) {
    if (environmentId == null) {
      return null;
    }
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = envType.getDescribe().fields.getMap();
    String branchField = firstExisting(fields, new List<String>{
      'copado__Current_Branch__c',
      'copado__Branch__c',
      'copado__Git_Branch__c',
      'copado__Org_Branch__c'
    });
    if (branchField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + branchField
        + ' FROM copado__Environment__c WHERE Id = :environmentId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(branchField) != null) {
        return String.valueOf(rows[0].get(branchField));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static Id resolvePromoteSelectionsContentVersionId(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    try {
      List<Map<String, Object>> selections = resolveCommitSelections(userStoryId, null);
      if (selections != null && !selections.isEmpty()) {
        return storeCommitSelectionsFile(userStoryId, selections);
      }
    } catch (Exception ignore) {
    }
    // Fall back to latest Commit changes file on the story.
    try {
      Id docId = findLatestCommitChangesDocument(userStoryId);
      if (docId == null) {
        return null;
      }
      List<ContentVersion> versions = [
        SELECT Id
        FROM ContentVersion
        WHERE ContentDocumentId = :docId AND IsLatest = true
        LIMIT 1
      ];
      return versions.isEmpty() ? null : versions[0].Id;
    } catch (Exception ignore) {
      return null;
    }
  }

  /**
   * Find latest Deployment for the Promotion, or create a Draft validation Deployment.
   */
  @TestVisible
  private static Id findOrCreatePromotionDeployment(
    Id promotionId,
    Id destEnvId,
    String destCredentialId,
    Boolean validationOnly
  ) {
    if (promotionId == null) {
      return null;
    }
    Schema.SObjectType depType = Schema.getGlobalDescribe().get('copado__Deployment__c');
    if (depType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = depType.getDescribe().fields.getMap();
    String promoField = firstExisting(fields, new List<String>{
      'copado__Promotion__c'
    });
    if (promoField != null) {
      try {
        List<SObject> existing = Database.query(
          'SELECT Id FROM copado__Deployment__c WHERE '
          + promoField + ' = :promotionId ORDER BY CreatedDate DESC LIMIT 1'
        );
        if (!existing.isEmpty()) {
          return (Id) existing[0].get('Id');
        }
      } catch (Exception ignore) {
      }
    }

    SObject dep = depType.newSObject();
    String promoCreate = firstCreateable(fields, new List<String>{ 'copado__Promotion__c' });
    if (promoCreate != null) {
      dep.put(promoCreate, promotionId);
    }
    String destEnvField = firstCreateable(fields, new List<String>{
      'copado__Destination_Environment__c', 'copado__To_Environment__c'
    });
    if (destEnvField != null && destEnvId != null) {
      dep.put(destEnvField, destEnvId);
    }
    String destCredField = firstCreateable(fields, new List<String>{
      'copado__Destination_Org_Credential__c',
      'copado__DestinationOrgCredential__c',
      'copado__Org__c'
    });
    if (destCredField != null && String.isNotBlank(destCredentialId)) {
      try {
        dep.put(destCredField, (Id) destCredentialId);
      } catch (Exception ignore) {
      }
    }
    String checkOnlyField = firstCreateable(fields, new List<String>{
      'copado__CheckOnly__c', 'copado__Validation_Only__c', 'copado__Is_Validation__c'
    });
    if (checkOnlyField != null && validationOnly == true) {
      Schema.DisplayType dt = fields.get(checkOnlyField).getDescribe().getType();
      if (dt == Schema.DisplayType.BOOLEAN) {
        dep.put(checkOnlyField, true);
      }
    }
    String nameField = firstCreateable(fields, new List<String>{ 'Name' });
    if (nameField != null && nameField != 'Name') {
      // Name is usually autonumber on Deployment
    }
    try {
      Database.SaveResult sr = Database.insert(dep, false);
      if (sr.isSuccess()) {
        return sr.getId();
      }
      System.debug(LoggingLevel.WARN, 'Deployment insert failed: ' + sr.getErrors());
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'findOrCreatePromotionDeployment: ' + ex.getMessage());
    }
    return null;
  }

  /** Read Pipeline Id from an existing Promotion. */
  private static Id readPromotionPipelineId(Id promotionId) {
    if (promotionId == null) {
      return null;
    }
    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    String pipelineField = firstExisting(fields, new List<String>{
      'copado__Pipeline__c', 'copado__Deployment_Flow__c'
    });
    if (pipelineField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + pipelineField
        + ' FROM copado__Promotion__c WHERE Id = :promotionId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(pipelineField) != null) {
        return (Id) rows[0].get(pipelineField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  public class PromotionResolve {
    public Id promotionId;
    public Id pipelineId;
    public Boolean createdNew;
  }

  /**
   * Ensure Validate has a Promotion Id. Pipeline Id is resolved from Project for
   * job DataJson — do NOT stamp Pipeline on the Promotion when Project is set
   * (Copado Source Format validation rule).
   */
  @TestVisible
  private static PromotionResolve resolveValidatePromotion(
    Id userStoryId,
    Id sourceEnvId,
    Id destEnvId,
    Id projectId,
    Boolean preferCreateNew
  ) {
    PromotionResolve resolved = new PromotionResolve();
    resolved.createdNew = false;

    Id pipelineId = resolvePipelineIdForProject(projectId);
    if (pipelineId == null) {
      pipelineId = resolvePipelineIdForEnvironment(sourceEnvId);
    }
    if (pipelineId == null) {
      throw new CopadoAiApiService.ApiException(
        'No Pipeline found on the Project or Dev environment. '
        + 'Set Deployment Flow / Pipeline on project Main - Testing, then retry Validate.'
      );
    }
    resolved.pipelineId = pipelineId;

    if (preferCreateNew == true) {
      detachUserStoryFromDraftPromotions(userStoryId);
      try {
        Id created = createPromotionRecord(userStoryId, sourceEnvId, destEnvId, projectId);
        // Standard promotions use Project (not Pipeline) on the record.
        resolved.promotionId = created;
        resolved.createdNew = true;
        return resolved;
      } catch (Exception createEx) {
        System.debug(
          LoggingLevel.WARN,
          'New Promotion create failed, healing Draft: ' + createEx.getMessage()
        );
        // Re-throw Copado validation messages so the UI shows the real rule text.
        String msg = createEx.getMessage() != null ? createEx.getMessage() : '';
        if (msg.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION')
          || msg.contains('Pipeline field can only be used')) {
          throw createEx;
        }
      }
    }

    Id existing = findDraftPromotionForUserStory(userStoryId, sourceEnvId, destEnvId);
    if (existing != null) {
      findOrCreatePromotedUserStory(existing, userStoryId);
      // Only stamp Pipeline when Project is blank (cross-project Source Format case).
      if (readPromotionProjectId(existing) == null) {
        ensurePromotionPipeline(existing, pipelineId);
      }
      resolved.promotionId = existing;
      resolved.createdNew = false;
      return resolved;
    }

    Id created = createPromotionRecord(userStoryId, sourceEnvId, destEnvId, projectId);
    resolved.promotionId = created;
    resolved.createdNew = true;
    return resolved;
  }

  /** Project Id on a Promotion, if any. */
  private static Id readPromotionProjectId(Id promotionId) {
    if (promotionId == null) {
      return null;
    }
    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    String projectField = firstExisting(fields, new List<String>{ 'copado__Project__c' });
    if (projectField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + projectField
        + ' FROM copado__Promotion__c WHERE Id = :promotionId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(projectField) != null) {
        return (Id) rows[0].get(projectField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /** Draft Promotion for this US on the same source → dest path (if any). */
  @TestVisible
  private static Id findDraftPromotionForUserStory(
    Id userStoryId,
    Id sourceEnvId,
    Id destEnvId
  ) {
    if (userStoryId == null) {
      return null;
    }
    for (String objectName : new List<String>{
      'copado__Promoted_User_Story__c',
      'copado__PromotedUserStory__c'
    }) {
      Schema.SObjectType linkType = Schema.getGlobalDescribe().get(objectName);
      if (linkType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = linkType.getDescribe().fields.getMap();
      String promoField = firstExisting(fields, new List<String>{ 'copado__Promotion__c' });
      String usField = firstExisting(fields, new List<String>{
        'copado__User_Story__c', 'copado__UserStory__c'
      });
      if (promoField == null || usField == null) {
        continue;
      }
      String promoRel = fields.get(promoField).getDescribe().getRelationshipName();
      if (String.isBlank(promoRel)) {
        continue;
      }
      Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
      if (promoType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> promoFields = promoType.getDescribe().fields.getMap();
      String statusField = firstExisting(promoFields, new List<String>{
        'copado__Status__c', 'Status'
      });
      String sourceField = firstExisting(promoFields, new List<String>{
        'copado__Source_Environment__c', 'copado__From_Environment__c'
      });
      String destField = firstExisting(promoFields, new List<String>{
        'copado__Destination_Environment__c', 'copado__To_Environment__c'
      });
      try {
        String soql =
          'SELECT ' + promoField
          + ' FROM ' + objectName
          + ' WHERE ' + usField + ' = :userStoryId';
        if (statusField != null) {
          soql +=
            ' AND ' + promoRel + '.' + statusField
            + ' IN (\'Draft\', \'Not Started\', \'Promotion not Started\')';
        }
        if (sourceField != null && sourceEnvId != null) {
          soql += ' AND ' + promoRel + '.' + sourceField + ' = :sourceEnvId';
        }
        if (destField != null && destEnvId != null) {
          soql += ' AND ' + promoRel + '.' + destField + ' = :destEnvId';
        }
        soql += ' ORDER BY CreatedDate DESC LIMIT 1';
        List<SObject> rows = Database.query(soql);
        if (!rows.isEmpty() && rows[0].get(promoField) != null) {
          return (Id) rows[0].get(promoField);
        }
      } catch (Exception ex) {
        System.debug(LoggingLevel.WARN, 'findDraftPromotionForUserStory: ' + ex.getMessage());
      }
    }
    return null;
  }

  /** Backfill Pipeline only for Project-less (cross-project) promotions. */
  private static void ensurePromotionPipeline(Id promotionId, Id pipelineId) {
    if (promotionId == null || pipelineId == null) {
      return;
    }
    // Source Format rule: leave Pipeline empty when Project is set.
    if (readPromotionProjectId(promotionId) != null) {
      return;
    }
    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    // Prefer updateable; fall back to existing API name (without sharing still may write).
    String pipelineField = firstCreateable(fields, new List<String>{
      'copado__Pipeline__c', 'copado__Deployment_Flow__c'
    });
    if (pipelineField == null) {
      pipelineField = firstExisting(fields, new List<String>{
        'copado__Pipeline__c', 'copado__Deployment_Flow__c'
      });
    }
    if (pipelineField == null) {
      return;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Id, ' + pipelineField
        + ' FROM copado__Promotion__c WHERE Id = :promotionId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return;
      }
      if (rows[0].get(pipelineField) != null
        && String.valueOf(rows[0].get(pipelineField)) == String.valueOf(pipelineId)) {
        return;
      }
      SObject upd = promoType.newSObject(promotionId);
      upd.put(pipelineField, pipelineId);
      Database.update(upd, false);
    } catch (Exception ignore) {
    }
  }

  /**
   * Remove the User Story from Draft promotions so Validate creates a clean new
   * Promotion instead of re-attaching to a stuck Draft (e.g. missing Pipeline).
   */
  @TestVisible
  private static void detachUserStoryFromDraftPromotions(Id userStoryId) {
    if (userStoryId == null) {
      return;
    }
    for (String objectName : new List<String>{
      'copado__Promoted_User_Story__c',
      'copado__PromotedUserStory__c'
    }) {
      Schema.SObjectType linkType = Schema.getGlobalDescribe().get(objectName);
      if (linkType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = linkType.getDescribe().fields.getMap();
      String promoField = firstExisting(fields, new List<String>{ 'copado__Promotion__c' });
      String usField = firstExisting(fields, new List<String>{
        'copado__User_Story__c', 'copado__UserStory__c'
      });
      if (promoField == null || usField == null) {
        continue;
      }
      Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
      if (promoType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> promoFields = promoType.getDescribe().fields.getMap();
      String statusField = firstExisting(promoFields, new List<String>{
        'copado__Status__c', 'Status'
      });
      String promoRel = fields.get(promoField).getDescribe().getRelationshipName();
      try {
        String soql =
          'SELECT Id FROM ' + objectName
          + ' WHERE ' + usField + ' = :userStoryId';
        if (statusField != null && String.isNotBlank(promoRel)) {
          soql +=
            ' AND ' + promoRel + '.' + statusField
            + ' IN (\'Draft\', \'Not Started\', \'Promotion not Started\')';
        }
        List<SObject> links = Database.query(soql);
        if (!links.isEmpty()) {
          Database.delete(links, false);
        }
      } catch (Exception ex) {
        System.debug(
          LoggingLevel.WARN,
          'detachUserStoryFromDraftPromotions: ' + ex.getMessage()
        );
      }
    }
  }

  @TestVisible
  private static Boolean isJobStarted(JobResult job) {
    if (job == null || String.isBlank(job.jobId)) {
      return false;
    }
    if ('Failed'.equalsIgnoreCase(job.status) || 'Prepared'.equalsIgnoreCase(job.status)) {
      return false;
    }
    // Placeholder ids are not real Job Executions
    String idVal = job.jobId;
    if (idVal.startsWith('validate-manual')
      || idVal.startsWith('create-execution-pending')
      || idVal.startsWith('validate-queued')
      || idVal.startsWith('deploy-next-queued')
      || idVal.startsWith('mock-')) {
      return idVal.startsWith('mock-');
    }
    return true;
  }

  @TestVisible
  private static Boolean looksLikeSalesforceId(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    String trimmed = value.trim();
    if (trimmed.length() != 15 && trimmed.length() != 18) {
      return false;
    }
    return Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$').matcher(trimmed).matches();
  }

  /** For Deploy/Commit: accept CreateExecution result unless explicitly Failed. */
  private static JobResult usableExecutionOrNull(JobResult job) {
    if (job == null || 'Failed'.equalsIgnoreCase(job.status) || String.isBlank(job.jobId)) {
      return null;
    }
    return job;
  }

  @TestVisible
  private static Id createPromotionRecord(
    Id userStoryId,
    Id sourceEnvId,
    Id destEnvId,
    Id projectId
  ) {
    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      throw new CopadoAiApiService.ApiException(
        'copado__Promotion__c is not available in this org.'
      );
    }
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required to create a Promotion.');
    }
    if (sourceEnvId == null || destEnvId == null) {
      throw new CopadoAiApiService.ApiException(
        'Source and destination Environments are required to create a Promotion.'
      );
    }

    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    SObject promo = promoType.newSObject();

    // Prefer createable; fall back to existing API names so required lookups still stamp
    // (FLS can report !isCreateable while without-sharing insert still succeeds).
    String sourceField = firstCreateable(fields, new List<String>{
      'copado__Source_Environment__c', 'copado__From_Environment__c'
    });
    if (sourceField == null) {
      sourceField = firstExisting(fields, new List<String>{
        'copado__Source_Environment__c', 'copado__From_Environment__c'
      });
    }
    String destField = firstCreateable(fields, new List<String>{
      'copado__Destination_Environment__c', 'copado__To_Environment__c'
    });
    if (destField == null) {
      destField = firstExisting(fields, new List<String>{
        'copado__Destination_Environment__c', 'copado__To_Environment__c'
      });
    }
    String projectField = firstCreateable(fields, new List<String>{
      'copado__Project__c'
    });
    if (projectField == null) {
      projectField = firstExisting(fields, new List<String>{ 'copado__Project__c' });
    }
    String pipelineField = firstCreateable(fields, new List<String>{
      'copado__Pipeline__c', 'copado__Deployment_Flow__c'
    });
    if (pipelineField == null) {
      pipelineField = firstExisting(fields, new List<String>{
        'copado__Pipeline__c', 'copado__Deployment_Flow__c'
      });
    }
    // Only set Platform when createable — FLS "not editable" fails the whole insert,
    // and putting null on retry still counts as writing the field.
    String platformField = firstCreateable(fields, new List<String>{
      'copado__Platform__c', 'Platform__c'
    });
    String statusField = firstCreateable(fields, new List<String>{
      'copado__Status__c', 'Status'
    });

    if (sourceField == null || destField == null) {
      throw new CopadoAiApiService.ApiException(
        'Could not find Source/Destination Environment fields on copado__Promotion__c.'
      );
    }

    promo.put(sourceField, sourceEnvId);
    promo.put(destField, destEnvId);
    if (projectField != null && projectId != null) {
      promo.put(projectField, projectId);
    }
    Id pipelineId = resolvePipelineIdForProject(projectId);
    if (pipelineId == null) {
      pipelineId = resolvePipelineIdForEnvironment(sourceEnvId);
    }
    // Copado Source Format rule: Pipeline on the Promotion only when Project (and
    // Release) are empty. Standard promotions use Project; Pipeline stays blank.
    Boolean stampPipelineOnRecord = projectId == null && pipelineField != null && pipelineId != null;
    if (stampPipelineOnRecord) {
      promo.put(pipelineField, pipelineId);
    }
    if (platformField != null) {
      promo.put(platformField, 'SFDX');
    }
    if (statusField != null) {
      try {
        promo.put(statusField, 'Draft');
      } catch (Exception ignore) {
      }
    }

    Database.SaveResult sr = Database.insert(promo, false);
    if (!sr.isSuccess()) {
      // Retry on a fresh SObject: Project + envs only (no Platform / Pipeline / Status).
      SObject retry = promoType.newSObject();
      retry.put(sourceField, sourceEnvId);
      retry.put(destField, destEnvId);
      if (projectField != null && projectId != null) {
        retry.put(projectField, projectId);
      }
      sr = Database.insert(retry, false);
      if (sr.isSuccess()) {
        promo = retry;
      }
    }
    if (!sr.isSuccess()) {
      throw new CopadoAiApiService.ApiException(
        'Could not create Copado Promotion: ' + formatSaveErrors(sr)
      );
    }
    Id promotionId = sr.getId();
    // Do not backfill Pipeline when Project is set — Copado validation forbids it.
    if (stampPipelineOnRecord && pipelineId != null) {
      ensurePromotionPipeline(promotionId, pipelineId);
    }
    Id pusId = findOrCreatePromotedUserStory(promotionId, userStoryId);
    if (pusId == null) {
      System.debug(
        LoggingLevel.WARN,
        'Promotion ' + promotionId + ' created but Promoted User Story link failed.'
      );
    }
    return promotionId;
  }

  /** Resolve Pipeline Id from an Environment via deployment-flow connections. */
  private static Id resolvePipelineIdForEnvironment(Id environmentId) {
    if (environmentId == null) {
      return null;
    }
    for (String stepObject : new List<String>{
      'copado__Deployment_Flow_Step__c',
      'copado__Pipeline_Connection__c',
      'copado__DeploymentFlowStep__c'
    }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(stepObject);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> stepFields = stepType.getDescribe().fields.getMap();
      String flowOnStep = firstExisting(stepFields, new List<String>{
        'copado__Deployment_Flow__c', 'copado__Pipeline__c'
      });
      String sourceField = firstExisting(stepFields, new List<String>{
        'copado__Source_Environment__c'
      });
      String destField = firstExisting(stepFields, new List<String>{
        'copado__Destination_Environment__c'
      });
      if (flowOnStep == null || (sourceField == null && destField == null)) {
        continue;
      }
      try {
        String whereClause = sourceField != null && destField != null
          ? '(' + sourceField + ' = :environmentId OR ' + destField + ' = :environmentId)'
          : (sourceField != null
            ? sourceField + ' = :environmentId'
            : destField + ' = :environmentId');
        List<SObject> rows = Database.query(
          'SELECT ' + flowOnStep
          + ' FROM ' + stepObject
          + ' WHERE ' + whereClause
          + ' LIMIT 1'
        );
        if (!rows.isEmpty() && rows[0].get(flowOnStep) != null) {
          return (Id) rows[0].get(flowOnStep);
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  /** Promoted User Story junction — has Promotion__r for Copado job expressions. */
  @TestVisible
  private static Id findPromotedUserStoryId(Id promotionId, Id userStoryId) {
    return findOrCreatePromotedUserStory(promotionId, userStoryId);
  }

  private static Id findOrCreatePromotedUserStory(Id promotionId, Id userStoryId) {
    if (promotionId == null || userStoryId == null) {
      return null;
    }
    for (String objectName : new List<String>{
      'copado__Promoted_User_Story__c',
      'copado__PromotedUserStory__c'
    }) {
      Schema.SObjectType linkType = Schema.getGlobalDescribe().get(objectName);
      if (linkType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = linkType.getDescribe().fields.getMap();
      String promoField = firstExisting(fields, new List<String>{
        'copado__Promotion__c'
      });
      String usField = firstExisting(fields, new List<String>{
        'copado__User_Story__c', 'copado__UserStory__c'
      });
      if (promoField == null || usField == null) {
        continue;
      }
      try {
        List<SObject> existing = Database.query(
          'SELECT Id FROM ' + objectName
          + ' WHERE ' + promoField + ' = :promotionId'
          + ' AND ' + usField + ' = :userStoryId'
          + ' LIMIT 1'
        );
        if (!existing.isEmpty()) {
          return (Id) existing[0].get('Id');
        }
      } catch (Exception ignore) {
      }
      String promoCreate = firstCreateable(fields, new List<String>{
        'copado__Promotion__c'
      });
      String usCreate = firstCreateable(fields, new List<String>{
        'copado__User_Story__c', 'copado__UserStory__c'
      });
      if (promoCreate == null || usCreate == null) {
        continue;
      }
      try {
        SObject link = linkType.newSObject();
        link.put(promoCreate, promotionId);
        link.put(usCreate, userStoryId);
        Database.SaveResult sr = Database.insert(link, false);
        if (sr.isSuccess()) {
          return sr.getId();
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  /**
   * CreateExecution sometimes leaves JE at Not Started. Nudge Copado to execute
   * so the Promotion leaves Draft.
   */
  private static JobResult ensureJobExecutionRunning(
    JobResult job,
    String templateApi,
    Map<String, Object> payload
  ) {
    if (job == null || String.isBlank(job.jobId) || 'Failed'.equalsIgnoreCase(job.status)) {
      return job;
    }
    if (job.jobId.startsWith('create-execution-pending')
      || job.jobId.startsWith('validate-queued')
      || job.jobId.startsWith('deploy-next-queued')
      || job.jobId.startsWith('mock-')
      || job.jobId.startsWith('webhook-')) {
      return job;
    }
    try {
      Id jobId = (Id) job.jobId;
      JobStatus st = getJobExecutionStatus(String.valueOf(jobId), false);
      if (st != null && st.isFailed == true) {
        job.status = 'Failed';
        job.errorDetail = String.isNotBlank(st.errorMessage) ? st.errorMessage : st.summary;
        job.summary = st.summary;
        return job;
      }
      String statusLower = st != null && String.isNotBlank(st.status)
        ? st.status.toLowerCase()
        : '';
      Boolean needsStart =
        String.isBlank(statusLower)
        || statusLower.contains('not started')
        || statusLower == 'n/a'
        || statusLower == 'na'
        || statusLower.contains('draft')
        || statusLower.contains('queued');
      if (!needsStart) {
        return job;
      }
      Id parentId = null;
      if (String.isNotBlank(job.parentIdUsed)) {
        try {
          parentId = (Id) job.parentIdUsed;
        } catch (Exception ignore) {
        }
      }
      Id templateId = null;
      if (String.isNotBlank(templateApi) && looksLikeSalesforceId(templateApi)) {
        templateId = (Id) templateApi;
      } else if (String.isNotBlank(templateApi)) {
        templateId = resolveJobTemplateId(templateApi);
      }
      Boolean started = tryStartJobExecution(
        jobId,
        templateApi,
        templateId,
        parentId,
        payload != null ? JSON.serialize(payload) : null
      );
      if (started) {
        job.status = 'In Progress';
        if (String.isBlank(job.summary) || job.summary.contains('Not Started')) {
          job.summary = 'Started job template ' + templateApi + ' (Job ' + job.jobId + ').';
        }
      }
    } catch (Exception ignore) {
    }
    return job;
  }

  /**
   * Try CreateExecution with each parent candidate. Prefer a started (or
   * in-progress) job; skip parents that immediately fail with Promotion__r.
   */
  @TestVisible
  private static JobResult tryCreateExecutionWithParentFallback(
    String templateApi,
    List<Id> parentCandidates,
    String environmentId,
    Map<String, Object> payload,
    List<String> diagnostics,
    String label
  ) {
    JobResult last = null;
    if (parentCandidates == null || parentCandidates.isEmpty()) {
      JobResult bad = new JobResult();
      bad.method = 'CreateExecution';
      bad.status = 'Failed';
      bad.errorDetail = label + ' CreateExecution: no parent Id (Promotion / Promoted US).';
      if (diagnostics != null) {
        diagnostics.add(bad.errorDetail);
      }
      return bad;
    }
    for (Id parentId : parentCandidates) {
      if (parentId == null) {
        continue;
      }
      JobResult job = tryCreateExecutionApi(templateApi, parentId, environmentId, payload);
      if (job != null) {
        job.parentIdUsed = String.valueOf(parentId);
      }
      last = job;
      if (isJobStarted(job)) {
        return job;
      }
      String detail = job != null
        ? (String.isNotBlank(job.errorDetail) ? job.errorDetail : job.summary)
        : 'null result';
      if (diagnostics != null && String.isNotBlank(detail)) {
        diagnostics.add(
          label + ' CreateExecution (' + templateApi + ', parent ' + parentId + '): ' + detail
        );
      }
      // Try next parent when this one hits the classic wrong-context relationship error.
      if (detail != null && detail.contains('Promotion__r')) {
        continue;
      }
      // Non-Promotion__r failure — still try next parent once if we have more.
    }
    return last;
  }

  private static void stampReadyToPromote(Id userStoryId) {
    if (userStoryId == null) {
      return;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String readyField = firstExisting(fields, new List<String>{
      'copado__Promote_Change__c',
      'copado__Ready_to_Promote__c',
      'copado__Promote_as_Single_Package__c'
    });
    if (readyField == null || !fields.get(readyField).getDescribe().isUpdateable()) {
      return;
    }
    try {
      SObject upd = usType.newSObject(userStoryId);
      upd.put(readyField, true);
      update upd;
    } catch (Exception ignore) {
    }
  }

  private static String resolvePipelineMainBranch(Id pipelineId) {
    if (pipelineId == null) {
      return null;
    }
    Schema.SObjectType pipeType = pipelineId.getSObjectType();
    Map<String, Schema.SObjectField> fields = pipeType.getDescribe().fields.getMap();
    String mainField = firstExisting(fields, new List<String>{
      'copado__Main_Branch__c', 'copado__Git_Main_Branch__c', 'copado__Base_Branch__c'
    });
    if (mainField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + mainField + ' FROM ' + pipeType.getDescribe().getName()
          + ' WHERE Id = :pipelineId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(mainField) != null) {
        return String.valueOf(rows[0].get(mainField));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Schedule a delayed USC link after deploy-then-commit starts.
   * Job Templates often finish Git without creating User Story Commit rows.
   */
  public static void scheduleUserStoryCommitLink(
    Id jobExecutionId,
    Id userStoryId,
    Id sessionId
  ) {
    scheduleUserStoryCommitLinkAttempt(jobExecutionId, userStoryId, sessionId, 150, 0);
  }

  public static void scheduleUserStoryCommitLinkAttempt(
    Id jobExecutionId,
    Id userStoryId,
    Id sessionId,
    Integer delaySeconds,
    Integer attempt
  ) {
    if (jobExecutionId == null || isMockDevops() || CopadoAiApiService.isMockMode()) {
      return;
    }
    Integer delay = delaySeconds != null && delaySeconds > 0 ? delaySeconds : 150;
    Datetime runAt = Datetime.now().addSeconds(delay);
    String cron =
      String.valueOf(runAt.second())
      + ' '
      + String.valueOf(runAt.minute())
      + ' '
      + String.valueOf(runAt.hour())
      + ' '
      + String.valueOf(runAt.day())
      + ' '
      + String.valueOf(runAt.month())
      + ' ? '
      + String.valueOf(runAt.year());
    String jobName =
      'CB_USC_'
      + String.valueOf(jobExecutionId).left(12)
      + '_'
      + String.valueOf(Datetime.now().getTime());
    try {
      System.schedule(
        jobName.left(80),
        cron,
        new CopadoCommitLinkSchedulable(
          jobExecutionId,
          userStoryId,
          sessionId,
          attempt == null ? 0 : attempt
        )
      );
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'scheduleUserStoryCommitLink: ' + ex.getMessage());
    }
  }

  /**
   * Manually link a known Git SHA to the User Story (for when Early Finish skips USC).
   */
  public static String linkCommitShaToUserStory(
    Id userStoryId,
    String commitSha,
    String featureBranch,
    String message
  ) {
    if (userStoryId == null) {
      return 'USC link failed: User Story Id required.';
    }
    Id linked = findUserStoryCommitWithSnapshot(userStoryId);
    if (linked != null) {
      return 'User Story Commit already linked: ' + String.valueOf(linked) + '.';
    }
    Id existingUscId = findLatestUserStoryCommitWithoutSnapshot(userStoryId);
    Id snapshotId = findOrCreateSnapshotCommit(
      userStoryId,
      featureBranch,
      commitSha,
      message,
      null
    );
    if (snapshotId == null) {
      return 'USC link failed: could not create Snapshot Commit.';
    }
    snapshotId = ensureSnapshotTypeForUsc(
      snapshotId,
      userStoryId,
      featureBranch,
      commitSha,
      message
    );
    UscLinkResult linkResult = linkSnapshotToUserStoryCommitDetailed(
      userStoryId,
      existingUscId,
      snapshotId,
      message
    );
    if (linkResult == null || linkResult.uscId == null) {
      String detail = linkResult != null && String.isNotBlank(linkResult.error)
        ? linkResult.error
        : 'User Story Commit DML failed.';
      return 'USC link failed: ' + detail;
    }
    Id uscId = linkResult.uscId;
    stampUserStoryLatestCommit(userStoryId);
    stampUserStoryCommitComplete(uscId);
    return 'Linked User Story Commit '
      + String.valueOf(uscId)
      + (String.isNotBlank(commitSha) ? ' (SHA ' + commitSha.left(7) + ')' : '')
      + '.';
  }

  /**
   * Create a Copado User Story Commit so the Job Execution is linked the same way
   * as Commit Changes in the Copado UI (JE → UserStoryCommit → User Story).
   */
  @TestVisible
  private static Id createUserStoryCommit(
    Id userStoryId,
    String commitMessage,
    Id selectionsContentDocumentId
  ) {
    if (userStoryId == null) {
      return null;
    }
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstCreateable(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    if (usField == null) {
      return null;
    }
    SObject row = commitType.newSObject();
    row.put(usField, userStoryId);

    String msgField = firstCreateable(fields, new List<String>{
      'copado__Commit_Message__c',
      'copado__Message__c',
      'copado__CommitMessage__c',
      'Name'
    });
    if (msgField != null && String.isNotBlank(commitMessage)) {
      Integer maxLen = fields.get(msgField).getDescribe().getLength();
      String msg = commitMessage;
      if (maxLen > 0 && msg.length() > maxLen) {
        msg = msg.substring(0, maxLen);
      }
      row.put(msgField, msg);
    }

    try {
      Database.SaveResult sr = Database.insert(row, false);
      if (!sr.isSuccess()) {
        System.debug(LoggingLevel.WARN, 'User Story Commit insert failed: ' + sr.getErrors());
        return null;
      }
      Id commitId = sr.getId();
      if (selectionsContentDocumentId != null) {
        linkContentToUserStory(selectionsContentDocumentId, commitId);
      }
      return commitId;
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'createUserStoryCommit: ' + ex.getMessage());
      return null;
    }
  }

  /**
   * CreateExecution sets parentId, but Copado Early Finish / related lists need the
   * JE User Story + User Story Commit lookups stamped explicitly.
   */
  @TestVisible
  private static void stampJobExecutionCommitContext(
    Id jobExecutionId,
    Id userStoryId,
    Id userStoryCommitId
  ) {
    if (jobExecutionId == null) {
      return;
    }
    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    SObject job = jobType.newSObject();
    job.put('Id', jobExecutionId);
    Boolean dirty = false;

    if (userStoryId != null) {
      String usField = firstUpdateable(fields, new List<String>{
        'copado__UserStory__c', 'copado__User_Story__c'
      });
      if (usField != null) {
        job.put(usField, userStoryId);
        dirty = true;
      }
    }
    if (userStoryCommitId != null) {
      String uscField = firstUpdateable(fields, new List<String>{
        'copado__UserStoryCommit__c', 'copado__User_Story_Commit__c'
      });
      if (uscField != null) {
        job.put(uscField, userStoryCommitId);
        dirty = true;
      }
      for (String parentField : new List<String>{
        'copado__ParentRecord_Id__c',
        'copado__ParentRecordId__c',
        'copado__ParentId__c',
        'copado__Parent_Id__c'
      }) {
        if (!fields.containsKey(parentField) || !fields.get(parentField).getDescribe().isUpdateable()) {
          continue;
        }
        Schema.DisplayType dt = fields.get(parentField).getDescribe().getType();
        if (dt == Schema.DisplayType.STRING || dt == Schema.DisplayType.TEXTAREA
          || dt == Schema.DisplayType.ID) {
          job.put(parentField, String.valueOf(userStoryCommitId));
        } else {
          job.put(parentField, userStoryCommitId);
        }
        dirty = true;
      }
    }
    if (dirty) {
      Database.update(job, false);
    }
  }

  /**
   * After a successful deploy-then-commit JE, ensure a User Story Commit appears on
   * the story (Snapshot Commit / Git Backup + USC junction). Custom Job Templates
   * often complete Git + Early Finish without creating that related-list row.
   *
   * Re-commits must create a NEW related-list row for the new SHA. Do not treat an
   * older USC (with snapshot) as "already linked" — that only stamps Latest Commit
   * Date and hides the new commit from the User Story Commits list.
   */
  @TestVisible
  public static String ensureUserStoryCommitFromJob(Id jobExecutionId) {
    if (jobExecutionId == null) {
      return 'Skip USC link: no Job Execution Id.';
    }
    Map<String, Object> data = readJobExecutionDataJson(jobExecutionId);
    if (data == null || data.isEmpty()) {
      return 'Skip USC link: Job Execution has no DataJson (cannot resolve User Story).';
    }
    Id userStoryId = null;
    if (data.get('userStoryId') != null) {
      try {
        userStoryId = (Id) String.valueOf(data.get('userStoryId'));
      } catch (Exception ignore) {
      }
    }
    if (userStoryId == null) {
      return 'Skip USC link: DataJson.userStoryId missing.';
    }

    String featureBranch = data.get('featureBranchName') != null
      ? String.valueOf(data.get('featureBranchName'))
      : null;
    String message = data.get('message') != null
      ? String.valueOf(data.get('message'))
      : (data.get('commitMessage') != null ? String.valueOf(data.get('commitMessage')) : null);

    String commitSha = findCommitShaForJob(jobExecutionId, featureBranch);
    if (String.isBlank(commitSha) && data.get('commitSha') != null) {
      commitSha = String.valueOf(data.get('commitSha'));
    }

    // Only skip when THIS SHA is already on a USC for the story (idempotent refresh).
    if (String.isNotBlank(commitSha)) {
      Id uscForSha = findUserStoryCommitForCommitSha(userStoryId, commitSha);
      if (uscForSha != null) {
        stampUserStoryLatestCommit(userStoryId);
        stampUserStoryCommitComplete(uscForSha);
        return 'User Story Commit already linked for SHA '
          + commitSha.left(7)
          + ': '
          + String.valueOf(uscForSha)
          + '.';
      }
    }

    // Prefer the USC created for THIS job (DataJson.userStoryCommitId), not an older row.
    Id existingUscId = null;
    if (data.get('userStoryCommitId') != null) {
      try {
        existingUscId = (Id) String.valueOf(data.get('userStoryCommitId'));
      } catch (Exception ignore) {
      }
    }
    // Incomplete USC without snapshot only if it belongs to this job — never grab an
    // older complete commit row (that blocked re-commit related-list updates).
    if (existingUscId == null) {
      existingUscId = findLatestUserStoryCommitWithoutSnapshot(userStoryId);
    }

    SnapshotCreateResult snapResult = findOrCreateSnapshotCommitDetailed(
      userStoryId,
      featureBranch,
      commitSha,
      message,
      jobExecutionId
    );
    if (snapResult == null || snapResult.snapshotId == null) {
      String detail = snapResult != null && String.isNotBlank(snapResult.error)
        ? snapResult.error
        : 'unknown error';
      return 'USC link failed: could not create/find Snapshot Commit. '
        + detail
        + (String.isBlank(commitSha)
          ? ' No SHA found yet — open the commit Job Step files or pass the git SHA.'
          : ' (SHA ' + commitSha.left(12) + ')');
    }
    if (String.isNotBlank(commitSha)) {
      persistCommitShaOnJob(jobExecutionId, commitSha);
    }

    Id snapshotForUsc = ensureSnapshotTypeForUsc(
      snapResult.snapshotId,
      userStoryId,
      featureBranch,
      commitSha,
      message
    );

    // If existingUscId already has a different snapshot (older commit), force a new USC.
    if (existingUscId != null && userStoryCommitHasSnapshot(existingUscId)) {
      existingUscId = null;
    }

    UscLinkResult linkResult = linkSnapshotToUserStoryCommitDetailed(
      userStoryId,
      existingUscId,
      snapshotForUsc,
      message
    );
    if (linkResult == null || linkResult.uscId == null) {
      String detail = linkResult != null && String.isNotBlank(linkResult.error)
        ? linkResult.error
        : 'Check FLS on copado__User_Story_Commit__c.';
      return 'USC link failed: Snapshot '
        + String.valueOf(snapResult.snapshotId)
        + ' exists but User Story Commit insert/update failed. '
        + detail;
    }
    Id uscId = linkResult.uscId;
    stampJobExecutionCommitContext(jobExecutionId, userStoryId, uscId);
    stampUserStoryLatestCommit(userStoryId);
    stampUserStoryCommitComplete(uscId);
    return 'Linked User Story Commit '
      + String.valueOf(uscId)
      + (String.isNotBlank(commitSha) ? ' (SHA ' + commitSha.left(7) + ')' : '')
      + '.';
  }

  public static Boolean userStoryHasCommits(Id userStoryId) {
    return countUserStoryCommits(userStoryId) > 0;
  }

  private static Integer countUserStoryCommits(Id userStoryId) {
    if (userStoryId == null) {
      return 0;
    }
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      return 0;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    if (usField == null) {
      return 0;
    }
    try {
      return Database.countQuery(
        'SELECT COUNT() FROM ' + commitType.getDescribe().getName()
          + ' WHERE ' + usField + ' = :userStoryId'
      );
    } catch (Exception ignore) {
      return 0;
    }
  }

  private static Id findUserStoryCommitWithSnapshot(Id userStoryId) {
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null || userStoryId == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    List<String> snapFields = uscSnapshotLookupFields(fields, null);
    if (usField == null || snapFields.isEmpty()) {
      return null;
    }
    try {
      List<String> clauses = new List<String>();
      for (String snapField : snapFields) {
        clauses.add(snapField + ' != null');
      }
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + commitType.getDescribe().getName()
          + ' WHERE ' + usField + ' = :userStoryId AND ('
          + String.join(clauses, ' OR ')
          + ') ORDER BY CreatedDate DESC LIMIT 1'
      );
      return rows.isEmpty() ? null : (Id) rows[0].get('Id');
    } catch (Exception ignore) {
      return null;
    }
  }

  /** True when this USC already points at a Snapshot / Git Backup. */
  private static Boolean userStoryCommitHasSnapshot(Id uscId) {
    if (uscId == null) {
      return false;
    }
    try {
      Schema.SObjectType commitType = uscId.getSObjectType();
      Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
      List<String> snapFields = uscSnapshotLookupFields(fields, null);
      if (snapFields.isEmpty()) {
        return false;
      }
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(snapFields, ',')
          + ' FROM ' + commitType.getDescribe().getName()
          + ' WHERE Id = :uscId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return false;
      }
      for (String snapField : snapFields) {
        if (rows[0].get(snapField) != null) {
          return true;
        }
      }
    } catch (Exception ignore) {
    }
    return false;
  }

  /**
   * Find a USC on this story whose Snapshot Commit Id matches the git SHA
   * (full or short). Used so re-commits create a new row unless this SHA is done.
   */
  @TestVisible
  private static Id findUserStoryCommitForCommitSha(Id userStoryId, String commitSha) {
    if (userStoryId == null || String.isBlank(commitSha)) {
      return null;
    }
    Id snapshotId = findSnapshotByCommitId(commitSha);
    if (snapshotId == null && commitSha.length() > 7) {
      snapshotId = findSnapshotByCommitId(commitSha.left(7));
    }
    if (snapshotId == null) {
      return null;
    }
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    List<String> snapFields = uscSnapshotLookupFields(fields, null);
    if (usField == null || snapFields.isEmpty()) {
      return null;
    }
    try {
      List<String> snapMatches = new List<String>();
      for (String snapField : snapFields) {
        snapMatches.add(snapField + ' = :snapshotId');
      }
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + commitType.getDescribe().getName()
          + ' WHERE ' + usField + ' = :userStoryId AND ('
          + String.join(snapMatches, ' OR ')
          + ') ORDER BY CreatedDate DESC LIMIT 1'
      );
      return rows.isEmpty() ? null : (Id) rows[0].get('Id');
    } catch (Exception ignore) {
      return null;
    }
  }

  private static Id findLatestUserStoryCommitWithoutSnapshot(Id userStoryId) {
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null || userStoryId == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    List<String> snapFields = uscSnapshotLookupFields(fields, null);
    if (usField == null) {
      return null;
    }
    try {
      String soql = 'SELECT Id FROM ' + commitType.getDescribe().getName()
        + ' WHERE ' + usField + ' = :userStoryId';
      if (!snapFields.isEmpty()) {
        List<String> nullClauses = new List<String>();
        for (String snapField : snapFields) {
          nullClauses.add(snapField + ' = null');
        }
        soql += ' AND (' + String.join(nullClauses, ' AND ') + ')';
      }
      soql += ' ORDER BY CreatedDate DESC LIMIT 1';
      List<SObject> rows = Database.query(soql);
      return rows.isEmpty() ? null : (Id) rows[0].get('Id');
    } catch (Exception ignore) {
      return null;
    }
  }

  @TestVisible
  public static Map<String, Object> readJobExecutionDataJson(Id jobExecutionId) {
    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    String dataField = firstExisting(fields, new List<String>{
      'copado__DataJson__c', 'copado__DataJSON__c', 'copado__VolumeOptions__c'
    });
    if (dataField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + dataField + ' FROM ' + jobType.getDescribe().getName()
          + ' WHERE Id = :jobExecutionId LIMIT 1'
      );
      if (rows.isEmpty() || rows[0].get(dataField) == null) {
        return null;
      }
      Object raw = JSON.deserializeUntyped(String.valueOf(rows[0].get(dataField)));
      return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : null;
    } catch (Exception ignore) {
      return null;
    }
  }

  private static String findCommitShaForJob(Id jobExecutionId, String featureBranch) {
    Set<Id> entityIds = new Set<Id>{ jobExecutionId };
    entityIds.addAll(findJobStepIds(jobExecutionId));

    // 1) Files on JE / Job Steps (ResultViewer, EnrichedChanges, etc.)
    try {
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :entityIds
        ORDER BY SystemModstamp DESC
        LIMIT 100
      ];
      Set<Id> docIds = new Set<Id>();
      for (ContentDocumentLink link : links) {
        docIds.add(link.ContentDocumentId);
      }
      if (!docIds.isEmpty()) {
        for (ContentVersion cv : [
          SELECT Title, PathOnClient, VersionData
          FROM ContentVersion
          WHERE ContentDocumentId IN :docIds AND IsLatest = true
          ORDER BY CreatedDate DESC
          LIMIT 100
        ]) {
          String body = cv.VersionData != null ? cv.VersionData.toString() : null;
          String sha = extractCommitSha(body);
          if (String.isNotBlank(sha)) {
            return sha;
          }
        }
      }
    } catch (Exception ignore) {
    }

    // 2) Job Step result / volume JSON fields may embed the SHA.
    String fromSteps = findCommitShaInJobStepFields(jobExecutionId);
    if (String.isNotBlank(fromSteps)) {
      return fromSteps;
    }

    // 3) Newest Snapshot Commit on this feature branch.
    if (String.isNotBlank(featureBranch)) {
      Id snap = findLatestSnapshotByBranch(featureBranch);
      if (snap != null) {
        String sha = readSnapshotCommitId(snap);
        if (String.isNotBlank(sha)) {
          return sha;
        }
      }
    }
    return null;
  }

  private static String findCommitShaInJobStepFields(Id jobExecutionId) {
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c', 'copado__Job__c'
      });
      if (jeField == null) {
        continue;
      }
      List<String> jsonFields = new List<String>();
      for (String candidate : new List<String>{
        'copado__ResultDataJson__c',
        'copado__Result_Data_JSON__c',
        'copado__VolumeOptions__c',
        'copado__ConfigJson__c',
        'copado__Result__c'
      }) {
        if (fields.containsKey(candidate)) {
          jsonFields.add(candidate);
        }
      }
      if (jsonFields.isEmpty()) {
        continue;
      }
      try {
        String soql =
          'SELECT ' + String.join(jsonFields, ',')
          + ' FROM ' + objectName
          + ' WHERE ' + jeField + ' = :jobExecutionId'
          + ' ORDER BY CreatedDate DESC LIMIT 20';
        for (SObject row : Database.query(soql)) {
          for (String jf : jsonFields) {
            if (row.get(jf) == null) {
              continue;
            }
            String sha = extractCommitSha(String.valueOf(row.get(jf)));
            if (String.isNotBlank(sha)) {
              return sha;
            }
          }
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  private static Set<Id> findJobStepIds(Id jobExecutionId) {
    Set<Id> stepIds = new Set<Id>();
    if (jobExecutionId == null) {
      return stepIds;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c', 'copado__Job__c'
      });
      if (jeField == null) {
        continue;
      }
      try {
        List<SObject> rows = Database.query(
          'SELECT Id FROM ' + objectName
            + ' WHERE ' + jeField + ' = :jobExecutionId'
            + ' ORDER BY CreatedDate DESC LIMIT 20'
        );
        for (SObject row : rows) {
          stepIds.add((Id) row.get('Id'));
        }
      } catch (Exception ignore) {
      }
    }
    return stepIds;
  }

  private static String extractCommitSha(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    // Common JSON keys
    Matcher m = Pattern.compile(
      '(?i)"(?:commitId|commit_id|gitCommitId|git_commit_id|sha|hash|commit|CommitId)"\\s*:\\s*"([0-9a-f]{7,40})"'
    ).matcher(body);
    if (m.find()) {
      return m.group(1);
    }
    // git rev-parse style
    m = Pattern.compile('(?i)(?:HEAD|rev-parse)[^0-9a-f\\n]*([0-9a-f]{40})').matcher(body);
    if (m.find()) {
      return m.group(1);
    }
    // Bare 40-char sha
    m = Pattern.compile('\\b([0-9a-f]{40})\\b').matcher(body);
    if (m.find()) {
      return m.group(1);
    }
    // Short sha (last resort)
    m = Pattern.compile('\\b([0-9a-f]{7,12})\\b').matcher(body);
    if (m.find()) {
      return m.group(1);
    }
    return null;
  }

  @TestVisible
  public static void persistCommitShaOnJob(Id jobExecutionId, String commitSha) {
    if (jobExecutionId == null || String.isBlank(commitSha)) {
      return;
    }
    Map<String, Object> data = readJobExecutionDataJson(jobExecutionId);
    if (data == null) {
      data = new Map<String, Object>();
    }
    data.put('commitSha', commitSha);
    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    String dataField = firstUpdateable(fields, new List<String>{
      'copado__DataJson__c', 'copado__DataJSON__c', 'copado__VolumeOptions__c'
    });
    if (dataField == null) {
      return;
    }
    try {
      SObject job = jobType.newSObject();
      job.put('Id', jobExecutionId);
      job.put(dataField, JSON.serialize(data));
      Database.update(job, false);
    } catch (Exception ignore) {
    }
  }

  private static Id findOrCreateSnapshotCommit(
    Id userStoryId,
    String featureBranch,
    String commitSha,
    String message,
    Id jobExecutionId
  ) {
    SnapshotCreateResult r = findOrCreateSnapshotCommitDetailed(
      userStoryId, featureBranch, commitSha, message, jobExecutionId
    );
    return r != null ? r.snapshotId : null;
  }

  private static SnapshotCreateResult findOrCreateSnapshotCommitDetailed(
    Id userStoryId,
    String featureBranch,
    String commitSha,
    String message,
    Id jobExecutionId
  ) {
    SnapshotCreateResult result = new SnapshotCreateResult();

    // Never create empty Snapshot Commits (Status/Commit Id blank) — that is what
    // leaves Builder rows looking incomplete vs Copado UI commits.
    if (String.isBlank(commitSha)) {
      result.error =
        'No git commit SHA found on the Job Execution yet. '
        + 'Open the Commit Job Step / git log, or use Link commit with the SHA.';
      return result;
    }

    Id bySha = findSnapshotByCommitId(commitSha);
    if (bySha != null) {
      stampSnapshotCommitComplete(bySha, commitSha, userStoryId, featureBranch, message);
      result.snapshotId = bySha;
      return result;
    }
    if (String.isNotBlank(featureBranch)) {
      Id existing = findLatestSnapshotByBranch(featureBranch);
      if (existing != null) {
        stampSnapshotCommitComplete(existing, commitSha, userStoryId, featureBranch, message);
        result.snapshotId = existing;
        return result;
      }
    }

    Schema.SObjectType snapType = preferredUscSnapshotObjectType();
    if (snapType == null) {
      snapType = Schema.getGlobalDescribe().get('copado__Snapshot_Commit__c');
    }
    if (snapType == null) {
      snapType = Schema.getGlobalDescribe().get('copado__Git_Backup__c');
    }
    if (snapType == null) {
      result.error = 'Neither copado__Snapshot_Commit__c nor copado__Git_Backup__c exists in this org.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = snapType.getDescribe().fields.getMap();

    Id repoId = resolveGitRepositoryId(userStoryId);
    Id orgCredId = resolveUserStoryOrgCredentialId(userStoryId);

    // Attempt 1: full row
    Database.SaveResult sr = tryInsertSnapshot(
      snapType, fields, commitSha, featureBranch, message, repoId, orgCredId
    );
    if (sr != null && sr.isSuccess()) {
      stampSnapshotCommitComplete(sr.getId(), commitSha, userStoryId, featureBranch, message);
      result.snapshotId = sr.getId();
      return result;
    }
    String err1 = formatSaveErrors(sr);

    // Attempt 2: without org credential
    sr = tryInsertSnapshot(snapType, fields, commitSha, featureBranch, message, repoId, null);
    if (sr != null && sr.isSuccess()) {
      stampSnapshotCommitComplete(sr.getId(), commitSha, userStoryId, featureBranch, message);
      result.snapshotId = sr.getId();
      return result;
    }
    String err2 = formatSaveErrors(sr);

    // Attempt 3: name + commit id only
    sr = tryInsertSnapshot(snapType, fields, commitSha, null, message, null, null);
    if (sr != null && sr.isSuccess()) {
      stampSnapshotCommitComplete(sr.getId(), commitSha, userStoryId, featureBranch, message);
      result.snapshotId = sr.getId();
      return result;
    }
    String err3 = formatSaveErrors(sr);

    result.error =
      'Insert failed on ' + snapType.getDescribe().getName() + '. '
      + 'repo=' + (repoId != null ? String.valueOf(repoId) : 'null')
      + ', orgCred=' + (orgCredId != null ? String.valueOf(orgCredId) : 'null')
      + '. Errors: '
      + (String.isNotBlank(err1) ? err1 : '')
      + (String.isNotBlank(err2) ? ' | ' + err2 : '')
      + (String.isNotBlank(err3) ? ' | ' + err3 : '');
    return result;
  }

  private static Database.SaveResult tryInsertSnapshot(
    Schema.SObjectType snapType,
    Map<String, Schema.SObjectField> fields,
    String commitSha,
    String featureBranch,
    String message,
    Id repoId,
    Id orgCredId
  ) {
    try {
      SObject row = snapType.newSObject();
      String commitIdField = firstCreateable(fields, new List<String>{
        'copado__Commit_Id__c', 'copado__CommitId__c', 'copado__Git_Commit_Id__c'
      });
      if (commitIdField != null && String.isNotBlank(commitSha)) {
        row.put(commitIdField, truncate(commitSha, 255));
      }
      String branchField = firstCreateable(fields, new List<String>{
        'copado__Branch__c', 'copado__Git_Branch__c'
      });
      if (branchField != null && String.isNotBlank(featureBranch)) {
        row.put(branchField, truncate(featureBranch, 255));
      }
      String msgField = firstCreateable(fields, new List<String>{
        'copado__Commit_Message__c', 'copado__Message__c', 'Name'
      });
      if (msgField != null) {
        String msg = String.isNotBlank(message)
          ? message
          : (String.isNotBlank(commitSha) ? 'Commit ' + commitSha : 'Copado Builder commit');
        Integer maxLen = fields.get(msgField).getDescribe().getLength();
        if (maxLen > 0 && msg.length() > maxLen) {
          msg = msg.substring(0, maxLen);
        }
        row.put(msgField, msg);
      }
      String repoField = firstCreateable(fields, new List<String>{
        'copado__Git_Repository__c', 'copado__Repository__c'
      });
      if (repoField != null && repoId != null) {
        row.put(repoField, repoId);
      }
      String orgField = firstCreateable(fields, new List<String>{
        'copado__Org__c', 'copado__Org_Credential__c', 'copado__Snapshot_Org__c',
        'copado__Credential__c'
      });
      if (orgField != null && orgCredId != null) {
        row.put(orgField, orgCredId);
      }
      // Match Copado UI Snapshot Commit: Status Complete + Git Operation Commit Files.
      applySnapshotCompleteFields(row, fields, true);
      return Database.insert(row, false);
    } catch (Exception ex) {
      return null;
    }
  }

  private static String formatSaveErrors(Database.SaveResult sr) {
    if (sr == null || sr.isSuccess() || sr.getErrors() == null || sr.getErrors().isEmpty()) {
      return '';
    }
    List<String> parts = new List<String>();
    for (Database.Error err : sr.getErrors()) {
      parts.add(err.getStatusCode() + ': ' + err.getMessage());
    }
    return String.join(parts, '; ');
  }

  private static Id resolveUserStoryOrgCredentialId(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    try {
      Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
      if (usType == null) {
        return null;
      }
      Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
      String credField = firstExisting(fields, new List<String>{
        'copado__Org_Credential__c', 'copado__Org__c', 'copado__Credential__c'
      });
      if (credField == null) {
        return null;
      }
      List<SObject> rows = Database.query(
        'SELECT ' + credField + ' FROM ' + usType.getDescribe().getName()
          + ' WHERE Id = :userStoryId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(credField) != null) {
        return (Id) rows[0].get(credField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static Id findSnapshotByCommitId(String commitSha) {
    if (String.isBlank(commitSha)) {
      return null;
    }
    for (String objectName : SNAPSHOT_OBJECT_TYPES) {
      Id found = findSnapshotByCommitIdOnObject(objectName, commitSha);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  private static Id findSnapshotByCommitIdOnObject(String objectName, String commitSha) {
    if (String.isBlank(objectName) || String.isBlank(commitSha)) {
      return null;
    }
    Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
    if (t == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
    String commitIdField = firstExisting(fields, new List<String>{
      'copado__Commit_Id__c', 'copado__CommitId__c', 'copado__Git_Commit_Id__c'
    });
    if (commitIdField == null) {
      return null;
    }
    try {
      String shortSha = commitSha.length() > 7 ? commitSha.left(7) : commitSha;
      String likePat = shortSha + '%';
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + objectName
          + ' WHERE ' + commitIdField + ' = :commitSha'
          + ' OR ' + commitIdField + ' LIKE :likePat'
          + ' ORDER BY CreatedDate DESC LIMIT 1'
      );
      return rows.isEmpty() ? null : (Id) rows[0].get('Id');
    } catch (Exception ignore) {
      return null;
    }
  }

  private static void stampSnapshotCommitId(Id snapshotId, String commitSha) {
    stampSnapshotCommitComplete(snapshotId, commitSha, null, null, null);
  }

  /**
   * Fill Snapshot Commit the same way Copado UI Commit Changes does:
   * Commit Id, Status=Complete, Git Operation=Commit Files, Credential.
   * Related-list Status / View in Git come from these fields.
   */
  @TestVisible
  private static void stampSnapshotCommitComplete(
    Id snapshotId,
    String commitSha,
    Id userStoryId,
    String featureBranch,
    String message
  ) {
    if (snapshotId == null) {
      return;
    }
    Schema.SObjectType t = snapshotId.getSObjectType();
    Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
    SObject row = t.newSObject();
    row.put('Id', snapshotId);
    Boolean dirty = false;

    if (String.isNotBlank(commitSha)) {
      String commitIdField = firstUpdateable(fields, new List<String>{
        'copado__Commit_Id__c', 'copado__CommitId__c', 'copado__Git_Commit_Id__c'
      });
      if (commitIdField != null) {
        String existing = readSnapshotCommitId(snapshotId);
        if (String.isBlank(existing)) {
          row.put(commitIdField, truncate(commitSha, 255));
          dirty = true;
        }
      }
    }

    if (String.isNotBlank(featureBranch)) {
      String branchField = firstUpdateable(fields, new List<String>{
        'copado__Branch__c', 'copado__Git_Branch__c'
      });
      if (branchField != null) {
        row.put(branchField, truncate(featureBranch, 255));
        dirty = true;
      }
    }

    if (String.isNotBlank(message)) {
      String msgField = firstUpdateable(fields, new List<String>{
        'copado__Commit_Message__c', 'copado__Message__c'
      });
      if (msgField != null) {
        Integer maxLen = fields.get(msgField).getDescribe().getLength();
        String msg = message;
        if (maxLen > 0 && msg.length() > maxLen) {
          msg = msg.substring(0, maxLen);
        }
        row.put(msgField, msg);
        dirty = true;
      }
    }

    Id orgCredId = resolveUserStoryOrgCredentialId(userStoryId);
    if (orgCredId != null) {
      String orgField = firstUpdateable(fields, new List<String>{
        'copado__Org__c', 'copado__Org_Credential__c', 'copado__Snapshot_Org__c',
        'copado__Credential__c'
      });
      if (orgField != null) {
        row.put(orgField, orgCredId);
        dirty = true;
      }
    }

    if (applySnapshotCompleteFields(row, fields, false)) {
      dirty = true;
    }

    if (!dirty) {
      return;
    }
    try {
      Database.update(row, false);
    } catch (Exception ignore) {
    }
  }

  /**
   * Status Complete + Git Operation Commit Files (create or update path).
   * @return true if any field was written onto row
   */
  private static Boolean applySnapshotCompleteFields(
    SObject row,
    Map<String, Schema.SObjectField> fields,
    Boolean forInsert
  ) {
    Boolean wrote = false;
    String statusField = forInsert
      ? firstCreateable(fields, new List<String>{ 'copado__Status__c', 'Status__c' })
      : firstUpdateable(fields, new List<String>{ 'copado__Status__c', 'Status__c' });
    if (statusField != null) {
      for (String value : new List<String>{ 'Complete', 'Completed', 'Success', 'Successful' }) {
        try {
          row.put(statusField, value);
          wrote = true;
          break;
        } catch (Exception ignore) {
        }
      }
    }
    String gitOpField = forInsert
      ? firstCreateable(fields, new List<String>{
          'copado__Git_Operation__c', 'copado__GitOperation__c'
        })
      : firstUpdateable(fields, new List<String>{
          'copado__Git_Operation__c', 'copado__GitOperation__c'
        });
    if (gitOpField != null) {
      for (String value : new List<String>{ 'Commit Files', 'Commit', 'Commit Changes' }) {
        try {
          row.put(gitOpField, value);
          wrote = true;
          break;
        } catch (Exception ignore) {
        }
      }
    }
    return wrote;
  }

  /** Stamp USC Status Complete so related lists match UI commits. */
  private static void stampUserStoryCommitComplete(Id uscId) {
    if (uscId == null) {
      return;
    }
    try {
      Schema.SObjectType commitType = uscId.getSObjectType();
      Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
      SObject row = commitType.newSObject();
      row.put('Id', uscId);
      Boolean dirty = false;
      String statusField = firstUpdateable(fields, new List<String>{
        'copado__Status__c', 'Status__c'
      });
      if (statusField != null) {
        for (String value : new List<String>{ 'Complete', 'Completed', 'Success' }) {
          try {
            row.put(statusField, value);
            dirty = true;
            break;
          } catch (Exception ignore) {
          }
        }
      }
      stampDefaultUserStoryCommitFields(row, fields);
      // stampDefault only for insert createable — also try updateable git op
      String gitOpField = firstUpdateable(fields, new List<String>{
        'copado__Git_Operation__c', 'copado__GitOperation__c'
      });
      if (gitOpField != null) {
        for (String value : new List<String>{ 'Commit Files', 'Commit', 'Commit Changes' }) {
          try {
            row.put(gitOpField, value);
            dirty = true;
            break;
          } catch (Exception ignore) {
          }
        }
      }
      if (dirty) {
        Database.update(row, false);
      }
    } catch (Exception ignore) {
    }
  }

  private static Id findLatestSnapshotByBranch(String featureBranch) {
    if (String.isBlank(featureBranch)) {
      return null;
    }
    for (String objectName : SNAPSHOT_OBJECT_TYPES) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      String branchField = firstExisting(fields, new List<String>{
        'copado__Branch__c', 'copado__Git_Branch__c'
      });
      if (branchField == null) {
        continue;
      }
      try {
        List<SObject> rows = Database.query(
          'SELECT Id FROM ' + objectName
            + ' WHERE ' + branchField + ' = :featureBranch'
            + ' ORDER BY CreatedDate DESC LIMIT 1'
        );
        if (!rows.isEmpty()) {
          return (Id) rows[0].get('Id');
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  private static String readSnapshotCommitId(Id snapshotId) {
    if (snapshotId == null) {
      return null;
    }
    Schema.SObjectType t = snapshotId.getSObjectType();
    Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
    String commitIdField = firstExisting(fields, new List<String>{
      'copado__Commit_Id__c', 'copado__CommitId__c', 'copado__Git_Commit_Id__c'
    });
    if (commitIdField == null) {
      return null;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + commitIdField + ' FROM ' + t.getDescribe().getName()
          + ' WHERE Id = :snapshotId LIMIT 1'
      );
      if (!rows.isEmpty() && rows[0].get(commitIdField) != null) {
        return String.valueOf(rows[0].get(commitIdField));
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /** Object type the User Story Commit snapshot lookup expects (Snapshot Commit in most orgs). */
  private static Schema.SObjectType preferredUscSnapshotObjectType() {
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    for (String candidate : USC_SNAPSHOT_LOOKUP_CANDIDATES) {
      String resolved = resolveFieldName(fields, candidate);
      if (resolved == null) {
        continue;
      }
      Schema.DescribeFieldResult d = fields.get(resolved).getDescribe();
      if (!d.isCreateable() && !d.isUpdateable()) {
        continue;
      }
      List<Schema.SObjectType> refs = d.getReferenceTo();
      if (!refs.isEmpty()) {
        return refs[0];
      }
    }
    return null;
  }

  private static Boolean uscFieldReferencesType(
    Map<String, Schema.SObjectField> uscFields,
    String fieldApiName,
    String objectApiName
  ) {
    String resolved = resolveFieldName(uscFields, fieldApiName);
    if (resolved == null || String.isBlank(objectApiName)) {
      return false;
    }
    for (Schema.SObjectType refType : uscFields.get(resolved).getDescribe().getReferenceTo()) {
      if (String.valueOf(refType) == objectApiName) {
        return true;
      }
    }
    return false;
  }

  /**
   * USC may require copado__Snapshot_Commit__c while an older linker row is Git_Backup__c.
   * Find or create the correct object type before DML on User Story Commit.
   */
  private static Id ensureSnapshotTypeForUsc(
    Id snapshotId,
    Id userStoryId,
    String featureBranch,
    String commitSha,
    String message
  ) {
    Schema.SObjectType preferred = preferredUscSnapshotObjectType();
    if (preferred == null || snapshotId == null) {
      return snapshotId;
    }
    if (String.valueOf(snapshotId.getSObjectType()) == String.valueOf(preferred)) {
      return snapshotId;
    }
    String preferredName = String.valueOf(preferred);
    if (String.isNotBlank(commitSha)) {
      Id bySha = findSnapshotByCommitIdOnObject(preferredName, commitSha);
      if (bySha != null) {
        return bySha;
      }
    }
    SnapshotCreateResult created = createSnapshotOnType(
      preferred,
      userStoryId,
      featureBranch,
      commitSha,
      message
    );
    if (created != null && created.snapshotId != null) {
      return created.snapshotId;
    }
    return snapshotId;
  }

  private static SnapshotCreateResult createSnapshotOnType(
    Schema.SObjectType snapType,
    Id userStoryId,
    String featureBranch,
    String commitSha,
    String message
  ) {
    SnapshotCreateResult result = new SnapshotCreateResult();
    if (snapType == null) {
      result.error = 'Snapshot object type not provided.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = snapType.getDescribe().fields.getMap();
    Id repoId = resolveGitRepositoryId(userStoryId);
    Id orgCredId = resolveUserStoryOrgCredentialId(userStoryId);

    Database.SaveResult sr = tryInsertSnapshot(
      snapType, fields, commitSha, featureBranch, message, repoId, orgCredId
    );
    if (sr != null && sr.isSuccess()) {
      result.snapshotId = sr.getId();
      return result;
    }
    sr = tryInsertSnapshot(snapType, fields, commitSha, featureBranch, message, repoId, null);
    if (sr != null && sr.isSuccess()) {
      result.snapshotId = sr.getId();
      return result;
    }
    sr = tryInsertSnapshot(snapType, fields, commitSha, null, message, null, null);
    if (sr != null && sr.isSuccess()) {
      result.snapshotId = sr.getId();
      return result;
    }
    result.error = 'Insert failed on ' + snapType.getDescribe().getName() + ': ' + formatSaveErrors(sr);
    return result;
  }

  private static List<String> uscSnapshotLookupFields(
    Map<String, Schema.SObjectField> uscFields,
    Id snapshotId
  ) {
    List<String> ordered = new List<String>();
    Set<String> seen = new Set<String>();
    String snapshotObjectName = snapshotId != null
      ? String.valueOf(snapshotId.getSObjectType())
      : null;

    if (snapshotObjectName != null) {
      for (String fieldName : uscFields.keySet()) {
        Schema.DescribeFieldResult d = uscFields.get(fieldName).getDescribe();
        if (d.getType() != Schema.DisplayType.REFERENCE || (!d.isCreateable() && !d.isUpdateable())) {
          continue;
        }
        for (Schema.SObjectType refType : d.getReferenceTo()) {
          if (String.valueOf(refType) == snapshotObjectName && !seen.contains(fieldName)) {
            ordered.add(fieldName);
            seen.add(fieldName);
          }
        }
      }
    }

    for (String candidate : USC_SNAPSHOT_LOOKUP_CANDIDATES) {
      String resolved = firstUpdateable(uscFields, new List<String>{ candidate });
      if (resolved == null) {
        resolved = firstCreateable(uscFields, new List<String>{ candidate });
      }
      if (resolved == null || seen.contains(resolved)) {
        continue;
      }
      if (snapshotObjectName != null && !uscFieldReferencesType(uscFields, resolved, snapshotObjectName)) {
        continue;
      }
      ordered.add(resolved);
      seen.add(resolved);
    }

    if (snapshotObjectName == null) {
      Set<String> snapshotObjects = new Set<String>(SNAPSHOT_OBJECT_TYPES);
      for (String fieldName : uscFields.keySet()) {
        Schema.DescribeFieldResult d = uscFields.get(fieldName).getDescribe();
        if (d.getType() != Schema.DisplayType.REFERENCE || (!d.isCreateable() && !d.isUpdateable())) {
          continue;
        }
        for (Schema.SObjectType refType : d.getReferenceTo()) {
          if (snapshotObjects.contains(String.valueOf(refType)) && !seen.contains(fieldName)) {
            ordered.add(fieldName);
            seen.add(fieldName);
          }
        }
      }
    }
    return ordered;
  }

  private static void stampDefaultUserStoryCommitFields(
    SObject row,
    Map<String, Schema.SObjectField> fields
  ) {
    String gitOpField = firstCreateable(fields, new List<String>{
      'copado__Git_Operation__c', 'copado__GitOperation__c'
    });
    if (gitOpField != null) {
      for (String value : new List<String>{ 'Commit Files', 'Commit', 'Commit Changes' }) {
        try {
          row.put(gitOpField, value);
          return;
        } catch (Exception ignore) {
        }
      }
    }
  }

  private static Id linkSnapshotToUserStoryCommit(
    Id userStoryId,
    Id existingUscId,
    Id snapshotId,
    String message
  ) {
    UscLinkResult result = linkSnapshotToUserStoryCommitDetailed(
      userStoryId, existingUscId, snapshotId, message
    );
    return result != null ? result.uscId : null;
  }

  private static UscLinkResult linkSnapshotToUserStoryCommitDetailed(
    Id userStoryId,
    Id existingUscId,
    Id snapshotId,
    String message
  ) {
    UscLinkResult result = new UscLinkResult();
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      result.error = 'copado__User_Story_Commit__c object not found.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    List<String> snapFields = uscSnapshotLookupFields(fields, snapshotId);
    if (snapFields.isEmpty()) {
      result.error = 'No snapshot lookup on User Story Commit matching '
        + (snapshotId != null ? String.valueOf(snapshotId.getSObjectType()) : 'snapshot Id')
        + ' (expected copado__Snapshot_Commit__c).';
      return result;
    }

    if (existingUscId != null) {
      for (String snapField : snapFields) {
        SObject row = commitType.newSObject();
        row.put('Id', existingUscId);
        row.put(snapField, snapshotId);
        Database.SaveResult sr = Database.update(row, false);
        if (sr.isSuccess()) {
          stampUserStoryCommitComplete(existingUscId);
          result.uscId = existingUscId;
          return result;
        }
        result.error = appendUscLinkError(result.error, snapField, formatSaveErrors(sr));
      }
    }

    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    if (usField != null) {
      for (String snapField : snapFields) {
        try {
          List<SObject> existing = Database.query(
            'SELECT Id FROM ' + commitType.getDescribe().getName()
              + ' WHERE ' + usField + ' = :userStoryId AND ' + snapField + ' = :snapshotId LIMIT 1'
          );
          if (!existing.isEmpty()) {
            result.uscId = (Id) existing[0].get('Id');
            return result;
          }
        } catch (Exception ignore) {
        }
      }
    }

    UscLinkResult insertResult = createUserStoryCommitWithSnapshotDetailed(
      userStoryId, message, snapshotId, snapFields
    );
    if (insertResult.uscId != null) {
      return insertResult;
    }
    result.error = String.isNotBlank(insertResult.error) ? insertResult.error : result.error;
    return result;
  }

  private static String appendUscLinkError(String existing, String fieldName, String detail) {
    String part = fieldName + ': ' + (String.isNotBlank(detail) ? detail : 'DML failed');
    return String.isBlank(existing) ? part : existing + ' | ' + part;
  }

  private static Id createUserStoryCommitWithSnapshot(
    Id userStoryId,
    String commitMessage,
    Id snapshotId
  ) {
    UscLinkResult result = createUserStoryCommitWithSnapshotDetailed(
      userStoryId, commitMessage, snapshotId, null
    );
    return result != null ? result.uscId : null;
  }

  private static UscLinkResult createUserStoryCommitWithSnapshotDetailed(
    Id userStoryId,
    String commitMessage,
    Id snapshotId,
    List<String> snapFieldCandidates
  ) {
    UscLinkResult result = new UscLinkResult();
    Schema.SObjectType commitType = Schema.getGlobalDescribe().get('copado__User_Story_Commit__c');
    if (commitType == null) {
      commitType = Schema.getGlobalDescribe().get('copado__UserStoryCommit__c');
    }
    if (commitType == null) {
      result.error = 'copado__User_Story_Commit__c object not found.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = commitType.getDescribe().fields.getMap();
    String usField = firstCreateable(fields, new List<String>{
      'copado__User_Story__c', 'copado__UserStory__c'
    });
    if (usField == null) {
      result.error = 'User Story lookup not createable on User Story Commit.';
      return result;
    }
    List<String> snapFields = snapFieldCandidates != null && !snapFieldCandidates.isEmpty()
      ? snapFieldCandidates
      : uscSnapshotLookupFields(fields, snapshotId);
    if (snapFields.isEmpty()) {
      result.error = 'No Snapshot/Git Backup lookup on User Story Commit.';
      return result;
    }

    String msgField = firstCreateable(fields, new List<String>{
      'copado__Commit_Message__c', 'copado__Message__c', 'copado__CommitMessage__c', 'Name'
    });
    String commitMsg = null;
    if (msgField != null && String.isNotBlank(commitMessage)) {
      Integer maxLen = fields.get(msgField).getDescribe().getLength();
      commitMsg = commitMessage;
      if (maxLen > 0 && commitMsg.length() > maxLen) {
        commitMsg = commitMsg.substring(0, maxLen);
      }
    }

    for (String snapField : snapFields) {
      SObject row = commitType.newSObject();
      row.put(usField, userStoryId);
      row.put(snapField, snapshotId);
      if (msgField != null && commitMsg != null) {
        row.put(msgField, commitMsg);
      }
      stampDefaultUserStoryCommitFields(row, fields);
      Database.SaveResult sr = Database.insert(row, false);
      if (sr.isSuccess()) {
        stampUserStoryCommitComplete(sr.getId());
        result.uscId = sr.getId();
        return result;
      }
      result.error = appendUscLinkError(result.error, snapField, formatSaveErrors(sr));
    }

    // Last resort: insert without snapshot, then update each lookup field.
    SObject bare = commitType.newSObject();
    bare.put(usField, userStoryId);
    if (msgField != null && commitMsg != null) {
      bare.put(msgField, commitMsg);
    }
    stampDefaultUserStoryCommitFields(bare, fields);
    Database.SaveResult bareSr = Database.insert(bare, false);
    if (!bareSr.isSuccess()) {
      result.error = appendUscLinkError(
        result.error,
        'insert-without-snapshot',
        formatSaveErrors(bareSr)
      );
      return result;
    }
    Id uscId = bareSr.getId();
    for (String snapField : snapFields) {
      SObject upd = commitType.newSObject();
      upd.put('Id', uscId);
      upd.put(snapField, snapshotId);
      Database.SaveResult updSr = Database.update(upd, false);
      if (updSr.isSuccess()) {
        stampUserStoryCommitComplete(uscId);
        result.uscId = uscId;
        result.error = null;
        return result;
      }
      result.error = appendUscLinkError(result.error, snapField + '(update)', formatSaveErrors(updSr));
    }
    stampUserStoryCommitComplete(uscId);
    result.uscId = uscId;
    return result;
  }

  private static void stampUserStoryLatestCommit(Id userStoryId) {
    if (userStoryId == null) {
      return;
    }
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String dateField = firstUpdateable(fields, new List<String>{
      'copado__Latest_Commit_Date__c', 'copado__Last_Commit_Date__c'
    });
    if (dateField == null) {
      return;
    }
    try {
      SObject us = usType.newSObject();
      us.put('Id', userStoryId);
      Schema.DisplayType dt = fields.get(dateField).getDescribe().getType();
      if (dt == Schema.DisplayType.DATETIME) {
        us.put(dateField, Datetime.now());
      } else {
        us.put(dateField, Date.today());
      }
      Database.update(us, false);
    } catch (Exception ignore) {
    }
  }

  private static Id resolveGitRepositoryId(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    try {
      Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
      if (usType == null) {
        return null;
      }
      Map<String, Schema.SObjectField> usFields = usType.getDescribe().fields.getMap();
      // Direct repo on User Story (some Copado versions)
      String usRepoField = firstExisting(usFields, new List<String>{
        'copado__Git_Repository__c', 'copado__Repository__c'
      });
      String projectField = firstExisting(usFields, new List<String>{ 'copado__Project__c' });
      List<String> selectFields = new List<String>{ 'Id' };
      if (usRepoField != null) {
        selectFields.add(usRepoField);
      }
      if (projectField != null) {
        selectFields.add(projectField);
      }
      List<SObject> usRows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
          + ' FROM ' + usType.getDescribe().getName()
          + ' WHERE Id = :userStoryId LIMIT 1'
      );
      if (usRows.isEmpty()) {
        return null;
      }
      if (usRepoField != null && usRows[0].get(usRepoField) != null) {
        return (Id) usRows[0].get(usRepoField);
      }
      if (projectField == null || usRows[0].get(projectField) == null) {
        return null;
      }
      Id projectId = (Id) usRows[0].get(projectField);
      Id pipelineId = resolvePipelineIdForProject(projectId);
      if (pipelineId == null) {
        return null;
      }
      Schema.SObjectType pipeType = pipelineId.getSObjectType();
      Map<String, Schema.SObjectField> pipeFields = pipeType.getDescribe().fields.getMap();
      String repoField = firstExisting(pipeFields, new List<String>{
        'copado__Git_Repository__c', 'copado__Repository__c'
      });
      if (repoField == null) {
        return null;
      }
      List<SObject> pipes = Database.query(
        'SELECT ' + repoField + ' FROM ' + pipeType.getDescribe().getName()
          + ' WHERE Id = :pipelineId LIMIT 1'
      );
      if (!pipes.isEmpty() && pipes[0].get(repoField) != null) {
        return (Id) pipes[0].get(repoField);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static String firstUpdateable(
    Map<String, Schema.SObjectField> fields,
    List<String> candidates
  ) {
    for (String name : candidates) {
      if (fields.containsKey(name) && fields.get(name).getDescribe().isUpdateable()) {
        return name;
      }
    }
    return null;
  }

  /**
   * Union User Story Metadata + package artifact selections.
   * Builder packages often include field + layout + profile/permset; USM insert can
   * partially fail and leave only the field — never let that shrink the commit set.
   * Invented English default layouts (Account-Account Layout) are remapped when a
   * live fullName is known (deploy job remaps / package context); otherwise dropped.
   */
  @TestVisible
  private static List<Map<String, Object>> resolveCommitSelections(
    Id userStoryId,
    String packageJson
  ) {
    return resolveCommitSelections(userStoryId, packageJson, null);
  }

  @TestVisible
  private static List<Map<String, Object>> resolveCommitSelections(
    Id userStoryId,
    String packageJson,
    Map<String, String> layoutRemaps
  ) {
    List<Map<String, Object>> fromPkg = buildCommitSelections(packageJson);
    List<Map<String, Object>> fromUs = buildCommitSelectionsFromUserStory(userStoryId);
    Map<String, Map<String, Object>> byKey = new Map<String, Map<String, Object>>();
    for (Map<String, Object> row : fromUs) {
      Map<String, Object> normalized = normalizeCommitSelection(row);
      String key = selectionKey(normalized);
      if (String.isNotBlank(key)) {
        byKey.put(key, normalized);
      }
    }
    for (Map<String, Object> row : fromPkg) {
      Map<String, Object> normalized = normalizeCommitSelection(row);
      String key = selectionKey(normalized);
      if (String.isNotBlank(key)) {
        byKey.put(key, normalized);
      }
    }
    return normalizeLayoutCommitSelections(byKey.values(), layoutRemaps, packageJson);
  }

  /**
   * After a successful Dev deploy: scrape BUILDER_LAYOUT_REMAP lines from the job,
   * rewrite package layout paths to live fullNames, and restamp User Story Metadata.
   * Returns the updated package JSON (or the original when nothing remapped).
   */
  public static String syncPackageLayoutsAfterDeploy(
    Id userStoryId,
    String packageJson,
    String deployJobId
  ) {
    if (String.isBlank(packageJson)) {
      return packageJson;
    }
    Map<String, String> remaps = new Map<String, String>();
    if (String.isNotBlank(deployJobId)) {
      remaps.putAll(parseLayoutRemapsFromText(collectJobOutputText(deployJobId)));
    }
    remaps.putAll(inferLayoutRemapsFromPackage(packageJson));
    if (remaps.isEmpty()) {
      return packageJson;
    }
    String updated = applyLayoutRemapsToPackageJson(packageJson, remaps);
    if (updated == packageJson || (updated != null && updated.equals(packageJson))) {
      // Still restamp when remaps only affect USM invented rows.
      if (userStoryId != null) {
        try {
          stampUserStoryBuildArtifacts(
            userStoryId,
            packageJson,
            extractArtifactPathsFromPackage(packageJson)
          );
        } catch (Exception ignore) {
        }
      }
      return packageJson;
    }
    if (userStoryId != null) {
      try {
        stampUserStoryBuildArtifacts(
          userStoryId,
          updated,
          extractArtifactPathsFromPackage(updated)
        );
      } catch (Exception ignore) {
      }
    }
    return updated;
  }

  /**
   * True when the Layout member is the invented English default "{Object}-{Object} Layout"
   * (e.g. Account-Account Layout) that Builder often guesses — usually missing in
   * localized orgs (e.g. Account-Formato de cuentas).
   */
  @TestVisible
  private static Boolean isInventedDefaultLayoutName(String member) {
    if (String.isBlank(member) || !member.contains('-')) {
      return false;
    }
    Integer dash = member.indexOf('-');
    if (dash <= 0 || dash >= member.length() - 1) {
      return false;
    }
    String objectApi = member.substring(0, dash);
    String layoutLabel = member.substring(dash + 1);
    // Exact invented pattern: Account-Account Layout
    if ((objectApi + ' Layout').equals(layoutLabel)) {
      return true;
    }
    return false;
  }

  /**
   * Format AUTHORITATIVE LIVE METADATA (+ legacy LAYOUTS) for Build / chat context.
   */
  @TestVisible
  public static String formatAuthoritativeLiveMetadataBlock(
    Map<String, List<String>> byType
  ) {
    if (byType == null || byType.isEmpty()) {
      return '';
    }
    List<String> lines = new List<String>();
    lines.add('AUTHORITATIVE LIVE METADATA (use these exact fullNames — never invent):');
    List<String> typeOrder = new List<String>{
      'Layout', 'CustomObject', 'CustomField', 'RecordType', 'ValidationRule',
      'Flow', 'FlexiPage', 'Profile', 'PermissionSet', 'ApexClass', 'ApexTrigger',
      'LightningComponentBundle', 'EmailTemplate', 'Report', 'Dashboard', 'Document'
    };
    Set<String> written = new Set<String>();
    for (String t : typeOrder) {
      if (!byType.containsKey(t) || byType.get(t) == null || byType.get(t).isEmpty()) {
        continue;
      }
      written.add(t);
      lines.add(t + ':');
      for (String name : byType.get(t)) {
        if (String.isNotBlank(name)) {
          lines.add('- ' + name.trim());
        }
      }
    }
    for (String t : byType.keySet()) {
      if (written.contains(t) || byType.get(t) == null || byType.get(t).isEmpty()) {
        continue;
      }
      lines.add(t + ':');
      for (String name : byType.get(t)) {
        if (String.isNotBlank(name)) {
          lines.add('- ' + name.trim());
        }
      }
    }
    // Backward-compatible Layout-only block for older scrapers / prompts.
    if (byType.containsKey('Layout') && byType.get('Layout') != null
      && !byType.get('Layout').isEmpty()) {
      lines.add('');
      lines.add('AUTHORITATIVE LIVE LAYOUTS (use these exact fullNames — never invent):');
      for (String name : byType.get('Layout')) {
        if (String.isNotBlank(name)) {
          lines.add('- ' + name.trim());
        }
      }
    }
    return String.join(lines, '\n');
  }

  /**
   * Parse AUTHORITATIVE LIVE METADATA / LAYOUTS blocks into type → fullNames.
   */
  @TestVisible
  public static Map<String, List<String>> extractAuthoritativeLiveMetadata(String text) {
    Map<String, List<String>> out = new Map<String, List<String>>();
    if (String.isBlank(text)) {
      return out;
    }
    // Typed sections: Layout:\n- name
    Pattern sectionPat = Pattern.compile(
      '(?mi)^\\s*([A-Za-z][A-Za-z0-9_]{1,60})\\s*:\\s*$'
    );
    Pattern bulletPat = Pattern.compile('(?m)^\\s*[-*]\\s*(.+?)\\s*$');
    String currentType = null;
    Boolean inAuthBlock = false;
    for (String rawLine : text.split('\\r?\\n')) {
      String line = rawLine != null ? rawLine : '';
      String trimmed = line.trim();
      if (trimmed.toUpperCase().startsWith('AUTHORITATIVE LIVE METADATA')) {
        inAuthBlock = true;
        currentType = null;
        continue;
      }
      if (trimmed.toUpperCase().startsWith('AUTHORITATIVE LIVE LAYOUTS')) {
        inAuthBlock = true;
        currentType = 'Layout';
        continue;
      }
      if (inAuthBlock && String.isBlank(trimmed)) {
        // blank line ends a typed section but not necessarily the whole block
        continue;
      }
      if (inAuthBlock && trimmed.toUpperCase().startsWith('AUTHORITATIVE ')) {
        continue;
      }
      // Leaving auth block when we hit a non-bullet, non-type heading that looks like prose
      Matcher secM = sectionPat.matcher(line);
      if (inAuthBlock && secM.matches()) {
        String maybeType = secM.group(1);
        if (isKnownMetadataTypeName(maybeType)) {
          currentType = maybeType;
          if (!out.containsKey(currentType)) {
            out.put(currentType, new List<String>());
          }
          continue;
        }
      }
      Matcher bulletM = bulletPat.matcher(line);
      if (inAuthBlock && bulletM.matches() && String.isNotBlank(currentType)) {
        String name = bulletM.group(1).trim();
        addAuthoritativeFullName(out, currentType, name);
        continue;
      }
      if (inAuthBlock && !bulletM.matches() && !secM.matches()
        && trimmed.length() > 0
        && !trimmed.startsWith('-')
        && !trimmed.startsWith('*')) {
        // End of block on unrelated prose
        if (!trimmed.contains(':') && trimmed.length() > 40) {
          inAuthBlock = false;
          currentType = null;
        }
      }
    }

    // Always merge Layout scrapers for legacy blocks / paths
    for (String layoutName : extractLiveLayoutFullNames(text)) {
      addAuthoritativeFullName(out, 'Layout', layoutName);
    }
    return out;
  }

  private static Boolean isKnownMetadataTypeName(String name) {
    if (String.isBlank(name)) {
      return false;
    }
    return new Set<String>{
      'Layout', 'CustomObject', 'CustomField', 'RecordType', 'ValidationRule',
      'Flow', 'FlexiPage', 'Profile', 'PermissionSet', 'ApexClass', 'ApexTrigger',
      'LightningComponentBundle', 'EmailTemplate', 'Report', 'Dashboard', 'Document',
      'CompactLayout', 'FieldSet', 'ListView', 'WebLink', 'CustomApplication',
      'CustomTab', 'StaticResource', 'RemoteSiteSetting', 'CustomMetadata', 'CustomLabels'
    }.contains(name);
  }

  private static void addAuthoritativeFullName(
    Map<String, List<String>> out,
    String typeName,
    String rawName
  ) {
    if (String.isBlank(typeName) || String.isBlank(rawName)) {
      return;
    }
    String name = rawName.trim()
      .replace('&amp;', '&')
      .replaceAll('\\s+', ' ');
    while (name.length() > 0 && '.,;:)]}'.contains(name.substring(name.length() - 1))) {
      name = name.substring(0, name.length() - 1).trim();
    }
    if (String.isBlank(name)) {
      return;
    }
    if ('Layout'.equals(typeName) && isInventedDefaultLayoutName(name)) {
      return;
    }
    if (!out.containsKey(typeName)) {
      out.put(typeName, new List<String>());
    }
    if (!out.get(typeName).contains(name)) {
      out.get(typeName).add(name);
    }
  }

  /**
   * Extract live Layout fullNames from chat / story / deploy logs.
   * Matches layouts/*.layout paths and "Layout: Name" / "Layout Name" mentions.
   */
  @TestVisible
  public static List<String> extractLiveLayoutFullNames(String text) {
    List<String> out = new List<String>();
    if (String.isBlank(text)) {
      return out;
    }
    Set<String> seen = new Set<String>();
    // force-app/.../layouts/<fullName>.layout(-meta).xml
    Pattern pathPat = Pattern.compile(
      '(?i)layouts/([^/\\n\\r\"\']+?)\\.layout(?:-meta)?\\.xml'
    );
    Matcher pathM = pathPat.matcher(text);
    while (pathM.find()) {
      addLiveLayoutName(out, seen, pathM.group(1));
    }
    // Layout: Account-Formato de cuentas  OR  Layout Account-Formato...
    Pattern labelPat = Pattern.compile(
      '(?i)\\bLayout\\b\\s*[:/]?\\s*([A-Za-z][A-Za-z0-9_]{1,40}-[^\\n\\r,\"\'<>|]{1,80})'
    );
    Matcher labelM = labelPat.matcher(text);
    while (labelM.find()) {
      addLiveLayoutName(out, seen, labelM.group(1));
    }
    // AUTHORITATIVE LIVE LAYOUTS block lines: - Account-Formato...
    Pattern bulletPat = Pattern.compile(
      '(?m)^\\s*[-*]\\s*([A-Za-z][A-Za-z0-9_]{1,40}-[^\\n\\r]{1,80})\\s*$'
    );
    Matcher bulletM = bulletPat.matcher(text);
    while (bulletM.find()) {
      addLiveLayoutName(out, seen, bulletM.group(1));
    }
    // AUTHORITATIVE LIVE METADATA → Layout: section bullets
    Pattern layoutSectionPat = Pattern.compile(
      '(?ism)AUTHORITATIVE LIVE METADATA.*?^\\s*Layout\\s*:\\s*$(.*?)(?=^\\s*[A-Za-z][A-Za-z0-9_]+\\s*:\\s*$|\\z)'
    );
    Matcher layoutSecM = layoutSectionPat.matcher(text);
    while (layoutSecM.find()) {
      Matcher secBullet = bulletPat.matcher(layoutSecM.group(1));
      while (secBullet.find()) {
        addLiveLayoutName(out, seen, secBullet.group(1));
      }
    }
    return out;
  }

  private static void addLiveLayoutName(List<String> out, Set<String> seen, String raw) {
    if (String.isBlank(raw)) {
      return;
    }
    String name = raw.trim()
      .replace('&amp;', '&')
      .replaceAll('\\s+', ' ');
    // Strip trailing punctuation
    while (name.length() > 0 && '.,;:)]}'.contains(name.substring(name.length() - 1))) {
      name = name.substring(0, name.length() - 1).trim();
    }
    if (String.isBlank(name) || !name.contains('-') || isInventedDefaultLayoutName(name)) {
      return;
    }
    if (!seen.contains(name)) {
      seen.add(name);
      out.add(name);
    }
  }

  /**
   * Parse BUILDER_LAYOUT_REMAP|from|to lines and BUILDER_LAYOUT_REMAP_JSON=[...] blobs.
   */
  @TestVisible
  public static Map<String, String> parseLayoutRemapsFromText(String text) {
    Map<String, String> remaps = new Map<String, String>();
    if (String.isBlank(text)) {
      return remaps;
    }
    Pattern linePat = Pattern.compile(
      'BUILDER_LAYOUT_REMAP\\|([^|\\n\\r]+)\\|([^|\\n\\r]+)'
    );
    Matcher lineM = linePat.matcher(text);
    while (lineM.find()) {
      String fromName = lineM.group(1) != null ? lineM.group(1).trim() : null;
      String toName = lineM.group(2) != null ? lineM.group(2).trim() : null;
      if (String.isNotBlank(fromName) && String.isNotBlank(toName)) {
        remaps.put(fromName, toName);
      }
    }
    Pattern jsonPat = Pattern.compile('BUILDER_LAYOUT_REMAP_JSON=(\\[[^\\n\\r]*\\])');
    Matcher jsonM = jsonPat.matcher(text);
    while (jsonM.find()) {
      try {
        Object parsed = JSON.deserializeUntyped(jsonM.group(1));
        if (parsed instanceof List<Object>) {
          for (Object row : (List<Object>) parsed) {
            if (!(row instanceof Map<String, Object>)) {
              continue;
            }
            Map<String, Object> m = (Map<String, Object>) row;
            String fromName = m.get('from') != null ? String.valueOf(m.get('from')).trim() : null;
            String toName = m.get('to') != null ? String.valueOf(m.get('to')).trim() : null;
            if (String.isNotBlank(fromName) && String.isNotBlank(toName)) {
              remaps.put(fromName, toName);
            }
          }
        }
      } catch (Exception ignore) {
      }
    }
    // Fallback: "OK: merged into live layout X" + invented names in same blob
    Pattern okPat = Pattern.compile('OK: merged into live layout\\s+([^\\n\\r]+)');
    Matcher okM = okPat.matcher(text);
    List<String> mergedTo = new List<String>();
    while (okM.find()) {
      String toName = okM.group(1) != null ? okM.group(1).trim() : null;
      if (String.isNotBlank(toName)) {
        mergedTo.add(toName);
      }
    }
    for (String toName : mergedTo) {
      Integer dash = toName.indexOf('-');
      if (dash <= 0) {
        continue;
      }
      String objectApi = toName.substring(0, dash);
      String invented = objectApi + '-' + objectApi + ' Layout';
      if (!remaps.containsKey(invented) && !invented.equals(toName)) {
        remaps.put(invented, toName);
      }
    }
    return remaps;
  }

  /**
   * Collect Job Execution / Result / attached log text for remap scraping.
   */
  @TestVisible
  public static String collectJobOutputText(String jobId) {
    if (String.isBlank(jobId) || isMockDevops() || CopadoAiApiService.isMockMode()) {
      return '';
    }
    List<String> chunks = new List<String>();
    try {
      JobStatus st = getJobExecutionStatus(jobId, false);
      if (st != null) {
        if (String.isNotBlank(st.summary)) {
          chunks.add(st.summary);
        }
        if (String.isNotBlank(st.errorMessage)) {
          chunks.add(st.errorMessage);
        }
      }
    } catch (Exception ignore) {
    }
    try {
      Id jid = (Id) jobId;
      Set<Id> entityIds = new Set<Id>{ jid };
      // Job Steps → Results
      for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
        if (t == null) {
          continue;
        }
        Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
        String jeField = firstExisting(fields, new List<String>{
          'copado__JobExecution__c', 'copado__Job_Execution__c', 'copado__Job__c'
        });
        String resultField = firstExisting(fields, new List<String>{
          'copado__Result__c', 'copado__ResultId__c'
        });
        String resultDataField = firstExisting(fields, new List<String>{
          'copado__Result_Data_JSON__c',
          'copado__ResultData__c',
          'copado__Result_Data__c',
          'copado__Error_Message__c',
          'copado__ErrorMessage__c',
          'copado__Message__c'
        });
        if (jeField == null) {
          continue;
        }
        List<String> selectFields = new List<String>{ 'Id' };
        if (resultField != null) {
          selectFields.add(resultField);
        }
        if (resultDataField != null) {
          selectFields.add(resultDataField);
        }
        for (SObject step : Database.query(
          'SELECT ' + String.join(selectFields, ',')
            + ' FROM ' + objectName
            + ' WHERE ' + jeField + ' = :jid'
            + ' ORDER BY CreatedDate DESC LIMIT 40'
        )) {
          entityIds.add((Id) step.get('Id'));
          if (resultField != null && step.get(resultField) != null) {
            entityIds.add((Id) step.get(resultField));
          }
          if (resultDataField != null && step.get(resultDataField) != null) {
            chunks.add(String.valueOf(step.get(resultDataField)));
          }
        }
        break;
      }
      // Result records linked to the job
      Schema.SObjectType resultType = Schema.getGlobalDescribe().get('copado__Result__c');
      if (resultType != null) {
        Map<String, Schema.SObjectField> rFields = resultType.getDescribe().fields.getMap();
        String parentField = firstExisting(rFields, new List<String>{
          'copado__JobExecution__c',
          'copado__Job_Execution__c',
          'copado__ParentId__c',
          'copado__JobStep__c'
        });
        String bodyField = firstExisting(rFields, new List<String>{
          'copado__Result_Data_JSON__c',
          'copado__Result_Data__c',
          'copado__ResultData__c',
          'copado__Error_Message__c',
          'copado__Message__c'
        });
        if (parentField != null && bodyField != null) {
          try {
            for (SObject row : Database.query(
              'SELECT ' + bodyField
                + ' FROM copado__Result__c'
                + ' WHERE ' + parentField + ' = :jid'
                + ' ORDER BY CreatedDate DESC LIMIT 20'
            )) {
              if (row.get(bodyField) != null) {
                chunks.add(String.valueOf(row.get(bodyField)));
              }
            }
          } catch (Exception ignore) {
          }
        }
      }
      // Attached log/result files
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :entityIds
        ORDER BY SystemModstamp DESC
        LIMIT 30
      ];
      if (!links.isEmpty()) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
          docIds.add(link.ContentDocumentId);
        }
        for (ContentVersion cv : [
          SELECT Title, PathOnClient, VersionData
          FROM ContentVersion
          WHERE ContentDocumentId IN :docIds AND IsLatest = true
          ORDER BY CreatedDate DESC
          LIMIT 25
        ]) {
          String title = ((cv.Title != null ? cv.Title : '')
            + ' '
            + (cv.PathOnClient != null ? cv.PathOnClient : '')).toLowerCase();
          if (!(title.contains('log')
            || title.contains('output')
            || title.contains('result')
            || title.contains('deploy')
            || title.contains('viewer')
            || title.contains('function'))) {
            continue;
          }
          if (cv.VersionData != null) {
            String body = cv.VersionData.toString();
            if (String.isNotBlank(body)) {
              chunks.add(body.length() > 200000 ? body.substring(0, 200000) : body);
            }
          }
        }
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'collectJobOutputText: ' + ex.getMessage());
    }
    return String.join(chunks, '\n');
  }

  /**
   * When package still has invented layout names, map them to live names found in
   * the same package summary / sibling layout paths (or AUTHORITATIVE block text).
   */
  @TestVisible
  private static Map<String, String> inferLayoutRemapsFromPackage(String packageJson) {
    Map<String, String> remaps = new Map<String, String>();
    if (String.isBlank(packageJson)) {
      return remaps;
    }
    List<String> live = extractLiveLayoutFullNames(packageJson);
    if (live.isEmpty()) {
      return remaps;
    }
    Map<String, String> preferredByObject = preferredLiveLayoutByObject(live);
    for (String path : extractArtifactPathsFromPackage(packageJson)) {
      if (String.isBlank(path) || !path.contains('/layouts/')) {
        continue;
      }
      Map<String, String> parsed = parseMetadataFromPath(path);
      String member = parsed != null ? parsed.get('member') : null;
      if (!isInventedDefaultLayoutName(member)) {
        continue;
      }
      Integer dash = member.indexOf('-');
      String objectApi = member.substring(0, dash);
      if (preferredByObject.containsKey(objectApi)) {
        remaps.put(member, preferredByObject.get(objectApi));
      }
    }
    return remaps;
  }

  private static Map<String, String> preferredLiveLayoutByObject(List<String> liveNames) {
    Map<String, String> byObject = new Map<String, String>();
    if (liveNames == null) {
      return byObject;
    }
    for (String name : liveNames) {
      if (String.isBlank(name) || isInventedDefaultLayoutName(name)) {
        continue;
      }
      Integer dash = name.indexOf('-');
      if (dash <= 0) {
        continue;
      }
      String objectApi = name.substring(0, dash);
      if (!byObject.containsKey(objectApi)) {
        byObject.put(objectApi, name);
      }
    }
    return byObject;
  }

  /**
   * Rewrite layout file paths in package JSON according to from→to remaps.
   */
  @TestVisible
  public static String applyLayoutRemapsToPackageJson(
    String packageJson,
    Map<String, String> remaps
  ) {
    if (String.isBlank(packageJson) || remaps == null || remaps.isEmpty()) {
      return packageJson;
    }
    Map<String, Object> root;
    try {
      root = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
    } catch (Exception ex) {
      return packageJson;
    }
    if (root == null || !(root.get('files') instanceof List<Object>)) {
      return packageJson;
    }
    List<Object> rawFiles = (List<Object>) root.get('files');
    List<Map<String, Object>> files = new List<Map<String, Object>>();
    Boolean changed = false;
    Set<String> usedPaths = new Set<String>();
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = new Map<String, Object>((Map<String, Object>) item);
      String path = fileMap.get('path') != null ? String.valueOf(fileMap.get('path')).trim() : '';
      if (String.isBlank(path) || !path.contains('/layouts/')) {
        files.add(fileMap);
        usedPaths.add(path);
        continue;
      }
      Map<String, String> parsed = parseMetadataFromPath(path);
      String member = parsed != null ? parsed.get('member') : null;
      String toName = String.isNotBlank(member) ? remaps.get(member) : null;
      if (String.isBlank(toName) || toName.equals(member)) {
        files.add(fileMap);
        usedPaths.add(path);
        continue;
      }
      String newPath = 'force-app/main/default/layouts/' + toName + '.layout-meta.xml';
      if (usedPaths.contains(newPath)) {
        changed = true;
        continue;
      }
      fileMap.put('path', newPath);
      files.add(fileMap);
      usedPaths.add(newPath);
      changed = true;
    }
    if (!changed) {
      return packageJson;
    }
    root.put('files', files);
    Object summaryObj = root.get('summary');
    String summary = summaryObj != null ? String.valueOf(summaryObj) : '';
    if (!summary.contains('layout remapped')) {
      root.put(
        'summary',
        (String.isNotBlank(summary) ? summary + ' ' : '')
          + 'Live layout remapped for Commit.'
      );
    }
    return JSON.serialize(root);
  }

  /**
   * Deterministic Build post-process: remap invented layout paths using live names
   * found in story/chat context; drop invented layouts when no live name is known.
   */
  @TestVisible
  public static String normalizePackageLayoutsWithContext(
    String packageJson,
    String contextText
  ) {
    if (String.isBlank(packageJson)) {
      return packageJson;
    }
    Map<String, String> remaps = new Map<String, String>();
    remaps.putAll(inferLayoutRemapsFromPackage(packageJson));
    List<String> live = extractLiveLayoutFullNames(
      (String.isNotBlank(contextText) ? contextText : '') + '\n' + packageJson
    );
    Map<String, String> preferred = preferredLiveLayoutByObject(live);
    for (String path : extractArtifactPathsFromPackage(packageJson)) {
      if (String.isBlank(path) || !path.contains('/layouts/')) {
        continue;
      }
      Map<String, String> parsed = parseMetadataFromPath(path);
      String member = parsed != null ? parsed.get('member') : null;
      if (!isInventedDefaultLayoutName(member)) {
        continue;
      }
      Integer dash = member.indexOf('-');
      String objectApi = member.substring(0, dash);
      if (preferred.containsKey(objectApi)) {
        remaps.put(member, preferred.get(objectApi));
      } else {
        // Sentinel: drop this invented layout (map to blank handled below)
        remaps.put(member, '');
      }
    }
    if (remaps.isEmpty()) {
      return packageJson;
    }
    // Drop invented layouts with no live target
    Map<String, String> pathRemaps = new Map<String, String>();
    Set<String> dropMembers = new Set<String>();
    for (String fromName : remaps.keySet()) {
      String toName = remaps.get(fromName);
      if (String.isBlank(toName)) {
        dropMembers.add(fromName);
      } else {
        pathRemaps.put(fromName, toName);
      }
    }
    String updated = applyLayoutRemapsToPackageJson(packageJson, pathRemaps);
    if (dropMembers.isEmpty()) {
      return updated;
    }
    return dropLayoutMembersFromPackage(updated, dropMembers);
  }

  /**
   * Layout remap/drop plus conservative gates for existing-org types listed in
   * AUTHORITATIVE LIVE METADATA (e.g. Profile). Does not drop creatable types
   * (CustomField, Flow, ApexClass, …) that Build is introducing.
   */
  @TestVisible
  public static String normalizePackageMetadataWithContext(
    String packageJson,
    String contextText
  ) {
    String updated = normalizePackageLayoutsWithContext(packageJson, contextText);
    if (String.isBlank(updated)) {
      return updated;
    }
    Map<String, List<String>> auth = extractAuthoritativeLiveMetadata(
      String.isNotBlank(contextText) ? contextText : ''
    );
    if (auth == null || auth.isEmpty()) {
      return updated;
    }
    // Only gate types that are almost always pre-existing in the org.
    Set<String> gatedTypes = new Set<String>{ 'Profile' };
    Map<String, Set<String>> allowedByType = new Map<String, Set<String>>();
    for (String t : gatedTypes) {
      if (!auth.containsKey(t) || auth.get(t) == null || auth.get(t).isEmpty()) {
        continue;
      }
      allowedByType.put(t, new Set<String>(auth.get(t)));
    }
    if (allowedByType.isEmpty()) {
      return updated;
    }
    return dropMembersNotInAuthoritativeLists(updated, allowedByType);
  }

  @TestVisible
  private static String dropMembersNotInAuthoritativeLists(
    String packageJson,
    Map<String, Set<String>> allowedByType
  ) {
    if (String.isBlank(packageJson) || allowedByType == null || allowedByType.isEmpty()) {
      return packageJson;
    }
    Map<String, Object> root;
    try {
      root = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
    } catch (Exception ex) {
      return packageJson;
    }
    if (root == null || !(root.get('files') instanceof List<Object>)) {
      return packageJson;
    }
    List<Object> rawFiles = (List<Object>) root.get('files');
    List<Map<String, Object>> files = new List<Map<String, Object>>();
    Boolean changed = false;
    Set<String> droppedTypes = new Set<String>();
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = (Map<String, Object>) item;
      String path = fileMap.get('path') != null
        ? String.valueOf(fileMap.get('path')).trim()
        : '';
      Map<String, String> parsed = parseMetadataFromPath(path);
      String metaType = parsed != null ? toSfdxMetadataType(parsed.get('type')) : null;
      String member = parsed != null ? parsed.get('member') : null;
      if (String.isNotBlank(metaType)
        && allowedByType.containsKey(metaType)
        && String.isNotBlank(member)
        && !allowedByType.get(metaType).contains(member)) {
        changed = true;
        droppedTypes.add(metaType);
        continue;
      }
      files.add(fileMap);
    }
    if (!changed) {
      return packageJson;
    }
    root.put('files', files);
    Object summaryObj = root.get('summary');
    String summary = summaryObj != null ? String.valueOf(summaryObj) : '';
    String note =
      'Omitted '
      + String.join(new List<String>(droppedTypes), ', ')
      + ' member(s) not present in AUTHORITATIVE LIVE METADATA.';
    if (!summary.contains('AUTHORITATIVE LIVE METADATA')) {
      root.put(
        'summary',
        (String.isNotBlank(summary) ? summary + ' ' : '') + note
      );
    }
    return JSON.serialize(root);
  }

  @TestVisible
  private static String dropLayoutMembersFromPackage(
    String packageJson,
    Set<String> dropMembers
  ) {
    if (String.isBlank(packageJson) || dropMembers == null || dropMembers.isEmpty()) {
      return packageJson;
    }
    Map<String, Object> root;
    try {
      root = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
    } catch (Exception ex) {
      return packageJson;
    }
    if (root == null || !(root.get('files') instanceof List<Object>)) {
      return packageJson;
    }
    List<Object> rawFiles = (List<Object>) root.get('files');
    List<Map<String, Object>> files = new List<Map<String, Object>>();
    Boolean changed = false;
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = (Map<String, Object>) item;
      String path = fileMap.get('path') != null ? String.valueOf(fileMap.get('path')).trim() : '';
      Map<String, String> parsed = parseMetadataFromPath(path);
      String member = parsed != null ? parsed.get('member') : null;
      if (path.contains('/layouts/') && dropMembers.contains(member)) {
        changed = true;
        continue;
      }
      files.add(fileMap);
    }
    if (!changed) {
      return packageJson;
    }
    root.put('files', files);
    Object summaryObj = root.get('summary');
    String summary = summaryObj != null ? String.valueOf(summaryObj) : '';
    if (!summary.toLowerCase().contains('omitted invented layout')) {
      root.put(
        'summary',
        (String.isNotBlank(summary) ? summary + ' ' : '')
          + 'Omitted invented layout name (no live fullName known yet).'
      );
    }
    return JSON.serialize(root);
  }

  @TestVisible
  private static List<Map<String, Object>> normalizeLayoutCommitSelections(
    List<Map<String, Object>> selections,
    Map<String, String> layoutRemaps,
    String packageJson
  ) {
    Map<String, String> remaps = new Map<String, String>();
    if (layoutRemaps != null) {
      remaps.putAll(layoutRemaps);
    }
    remaps.putAll(inferLayoutRemapsFromPackage(packageJson));
    if (selections == null || selections.isEmpty()) {
      return selections;
    }
    List<Map<String, Object>> out = new List<Map<String, Object>>();
    Set<String> seen = new Set<String>();
    for (Map<String, Object> row : selections) {
      if (row == null) {
        continue;
      }
      String t = row.get('t') != null ? String.valueOf(row.get('t')) : null;
      String n = row.get('n') != null ? String.valueOf(row.get('n')) : null;
      if ('Layout'.equals(toSfdxMetadataType(t))) {
        if (String.isNotBlank(n) && remaps.containsKey(n) && String.isNotBlank(remaps.get(n))) {
          n = remaps.get(n);
          row = new Map<String, Object>(row);
          row.put('n', n);
        }
        if (isInventedDefaultLayoutName(n)) {
          System.debug(
            LoggingLevel.WARN,
            'Skipping invented layout from commit selections: ' + n
          );
          continue;
        }
      }
      String key = toSfdxMetadataType(t) + ':' + n;
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      out.add(row);
    }
    return out;
  }

  @TestVisible
  private static List<Map<String, Object>> dropInventedDefaultLayouts(
    List<Map<String, Object>> selections
  ) {
    return normalizeLayoutCommitSelections(selections, null, null);
  }

  /**
   * SFDX / sf CLI registry ids only — never Copado UI labels like "Page Layout".
   * See: https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_types_list.htm
   */
  @TestVisible
  private static String toSfdxMetadataType(String rawType) {
    if (String.isBlank(rawType)) {
      return rawType;
    }
    String t = rawType.trim();
    Map<String, String> aliases = new Map<String, String>{
      'Page Layout' => 'Layout',
      'PageLayout' => 'Layout',
      'page layout' => 'Layout',
      'Permission Set' => 'PermissionSet',
      'PermissionSet' => 'PermissionSet',
      'Custom Field' => 'CustomField',
      'Custom Object' => 'CustomObject',
      'Validation Rule' => 'ValidationRule',
      'Record Type' => 'RecordType',
      'Apex Class' => 'ApexClass',
      'Apex Trigger' => 'ApexTrigger',
      'Lightning Component Bundle' => 'LightningComponentBundle',
      'Lightning Web Component' => 'LightningComponentBundle',
      'Flexi Page' => 'FlexiPage',
      'Lightning Page' => 'FlexiPage',
      'Custom Application' => 'CustomApplication',
      'Custom Tab' => 'CustomTab',
      'Remote Site Setting' => 'RemoteSiteSetting',
      'Custom Metadata' => 'CustomMetadata',
      'Custom Labels' => 'CustomLabels',
      'Static Resource' => 'StaticResource',
      'Compact Layout' => 'CompactLayout',
      'Field Set' => 'FieldSet',
      'Web Link' => 'WebLink',
      'List View' => 'ListView'
    };
    if (aliases.containsKey(t)) {
      return aliases.get(t);
    }
    // Case-insensitive alias pass
    for (String key : aliases.keySet()) {
      if (key.equalsIgnoreCase(t)) {
        return aliases.get(key);
      }
    }
    return t;
  }

  @TestVisible
  private static Map<String, Object> normalizeCommitSelection(Map<String, Object> row) {
    if (row == null) {
      return null;
    }
    Map<String, Object> out = new Map<String, Object>(row);
    if (out.get('t') != null) {
      out.put('t', toSfdxMetadataType(String.valueOf(out.get('t'))));
    }
    return out;
  }

  private static String selectionKey(Map<String, Object> row) {
    if (row == null || row.get('t') == null || row.get('n') == null) {
      return null;
    }
    return String.valueOf(row.get('t')) + ':' + String.valueOf(row.get('n'));
  }

  /**
   * Build Copado Commit changes.json from User Story Metadata already on the story.
   * Matches Copado UI: selections live on the US; the commit file mirrors them:
   *   [{"t":"CustomField","n":"Account.Field__c","m":"","j":"","c":"SFDX","a":"Add"}]
   */
  @TestVisible
  private static List<Map<String, Object>> buildCommitSelectionsFromUserStory(Id userStoryId) {
    List<Map<String, Object>> selections = new List<Map<String, Object>>();
    if (userStoryId == null) {
      return selections;
    }
    Schema.SObjectType metaType = Schema.getGlobalDescribe().get('copado__User_Story_Metadata__c');
    if (metaType == null) {
      return selections;
    }
    Map<String, Schema.SObjectField> fields = metaType.getDescribe().fields.getMap();
    String usField = firstExisting(fields, new List<String>{
      'copado__User_Story__c', 'User_Story__c'
    });
    String apiNameField = firstExisting(fields, new List<String>{
      'copado__Metadata_API_Name__c', 'copado__Api_Name__c'
    });
    String typeField = firstExisting(fields, new List<String>{
      'copado__Type__c', 'copado__Metadata_Type__c'
    });
    String actionField = firstExisting(fields, new List<String>{
      'copado__Action__c'
    });
    if (usField == null || apiNameField == null || typeField == null) {
      return selections;
    }
    try {
      String soql =
        'SELECT ' + apiNameField + ',' + typeField
        + (actionField != null ? ',' + actionField : '')
        + ' FROM ' + metaType.getDescribe().getName()
        + ' WHERE ' + usField + ' = :userStoryId'
        + ' ORDER BY CreatedDate ASC LIMIT 200';
      for (SObject row : Database.query(soql)) {
        String member = row.get(apiNameField) != null
          ? String.valueOf(row.get(apiNameField))
          : null;
        String metaTypeName = row.get(typeField) != null
          ? String.valueOf(row.get(typeField))
          : null;
        if (String.isBlank(member) || String.isBlank(metaTypeName)
          || member.startsWith('force-app/')) {
          continue;
        }
        metaTypeName = toSfdxMetadataType(metaTypeName);
        String action = 'Add';
        if (actionField != null && row.get(actionField) != null
          && String.isNotBlank(String.valueOf(row.get(actionField)))) {
          String rawAction = String.valueOf(row.get(actionField));
          // US Metadata Action is typically Add/Delete; map through for the JSON.
          if (rawAction.equalsIgnoreCase('Delete') || rawAction.equalsIgnoreCase('Deleted')) {
            action = 'Delete';
          } else {
            action = 'Add';
          }
        }
        selections.add(normalizeCommitSelection(new Map<String, Object>{
          't' => metaTypeName,
          'n' => member,
          'm' => '',
          'j' => '',
          'c' => 'SFDX',
          'a' => action
        }));
      }
    } catch (Exception ignore) {
    }
    return selections;
  }

  /**
   * Fallback: derive Commit changes.json from package artifact paths when
   * User Story Metadata rows are unavailable.
   *
   * Exact shape from a successful Copado UI commit (SFDX pipeline):
   *   [{"t":"CustomField","n":"Account.Field__c","m":"","j":"","c":"SFDX","a":"Add"}]
   */
  @TestVisible
  private static List<Map<String, Object>> buildCommitSelections(String packageJson) {
    List<Map<String, Object>> selections = new List<Map<String, Object>>();
    Map<String, Map<String, Object>> byKey = new Map<String, Map<String, Object>>();
    Map<String, String> pathToContent = indexPackageFileContents(packageJson);

    for (String path : extractArtifactPathsFromPackage(packageJson)) {
      // MDAPI .object files often embed CustomFields — expand those instead of
      // (or in addition to) committing the whole CustomObject.
      if (isMdapiObjectFile(path)) {
        String objectName = objectApiNameFromObjectPath(path);
        String content = pathToContent.get(normalizePathKey(path));
        for (String fieldApi : extractCustomFieldFullNamesFromObjectXml(content)) {
          if (String.isBlank(objectName) || String.isBlank(fieldApi)) {
            continue;
          }
          putSelection(
            byKey,
            normalizeCommitSelection(new Map<String, Object>{
              't' => 'CustomField',
              'n' => objectName + '.' + fieldApi,
              'm' => '',
              'j' => '',
              'c' => 'SFDX',
              'a' => 'Add'
            })
          );
        }
      }

      Map<String, String> parsed = parseMetadataFromPath(path);
      String member = parsed.get('member');
      String metaType = parsed.get('type');
      if (String.isBlank(member) || String.isBlank(metaType)) {
        continue;
      }
      // Prefer field-level selections from .object expansion over whole CustomObject
      // when we already extracted fields for that object.
      if ('CustomObject'.equals(metaType) && hasFieldSelectionsForObject(byKey, member)) {
        continue;
      }
      putSelection(
        byKey,
        normalizeCommitSelection(new Map<String, Object>{
          't' => metaType,
          'n' => member,
          'm' => '',
          'j' => '',
          'c' => 'SFDX',
          'a' => 'Add'
        })
      );
    }
    selections.addAll(byKey.values());
    return selections;
  }

  private static void putSelection(
    Map<String, Map<String, Object>> byKey,
    Map<String, Object> row
  ) {
    String key = selectionKey(row);
    if (String.isNotBlank(key)) {
      byKey.put(key, row);
    }
  }

  private static Boolean hasFieldSelectionsForObject(
    Map<String, Map<String, Object>> byKey,
    String objectName
  ) {
    if (byKey == null || String.isBlank(objectName)) {
      return false;
    }
    String prefix = 'CustomField:' + objectName + '.';
    for (String key : byKey.keySet()) {
      if (key != null && key.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  private static Boolean isMdapiObjectFile(String path) {
    if (String.isBlank(path)) {
      return false;
    }
    String p = path.replace('\\', '/');
    return p.contains('/objects/')
      && (p.endsWith('.object') || p.endsWith('.object-meta.xml'));
  }

  private static String objectApiNameFromObjectPath(String path) {
    if (String.isBlank(path)) {
      return null;
    }
    String p = path.replace('\\', '/');
    String fileName = p.substring(p.lastIndexOf('/') + 1);
    if (fileName.endsWith('.object-meta.xml')) {
      return fileName.replace('.object-meta.xml', '');
    }
    if (fileName.endsWith('.object')) {
      return fileName.replace('.object', '');
    }
    // SFDX folder form: objects/Account/Account.object-meta.xml already handled;
    // objects/Account/fields/... uses pathSegmentAfter.
    return pathSegmentAfter(p, 'objects');
  }

  private static Map<String, String> indexPackageFileContents(String packageJson) {
    Map<String, String> out = new Map<String, String>();
    if (String.isBlank(packageJson)) {
      return out;
    }
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
      if (!(parsed.get('files') instanceof List<Object>)) {
        return out;
      }
      for (Object item : (List<Object>) parsed.get('files')) {
        if (!(item instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> file = (Map<String, Object>) item;
        Object path = file.get('path');
        Object content = file.get('content');
        if (content == null) {
          content = file.get('contents');
        }
        if (path == null || content == null) {
          continue;
        }
        out.put(normalizePathKey(String.valueOf(path)), String.valueOf(content));
      }
    } catch (Exception ignore) {
    }
    return out;
  }

  private static String normalizePathKey(String path) {
    return String.isBlank(path) ? path : path.replace('\\', '/');
  }

  /**
   * Extract CustomField API names from MDAPI/SFDX object XML (&lt;fields&gt;&lt;fullName&gt;).
   */
  @TestVisible
  private static List<String> extractCustomFieldFullNamesFromObjectXml(String xml) {
    List<String> names = new List<String>();
    if (String.isBlank(xml)) {
      return names;
    }
    // Prefer field blocks: <fields> ... <fullName>X__c</fullName>
    Integer searchFrom = 0;
    String lower = xml.toLowerCase();
    while (true) {
      Integer fieldsStart = lower.indexOf('<fields', searchFrom);
      if (fieldsStart < 0) {
        break;
      }
      Integer fieldsEnd = lower.indexOf('</fields>', fieldsStart);
      if (fieldsEnd < 0) {
        break;
      }
      String block = xml.substring(fieldsStart, fieldsEnd);
      String fullName = firstXmlTagValue(block, 'fullName');
      if (String.isNotBlank(fullName) && fullName.endsWith('__c')) {
        names.add(fullName.trim());
      }
      searchFrom = fieldsEnd + 9;
    }
    // Fallback: any __c fullName if no <fields> blocks matched
    if (names.isEmpty()) {
      Matcher m = Pattern.compile('(?i)<fullName>\\s*([A-Za-z0-9_]+__c)\\s*</fullName>').matcher(xml);
      while (m.find()) {
        names.add(m.group(1));
      }
    }
    return names;
  }

  private static String firstXmlTagValue(String xml, String tagName) {
    if (String.isBlank(xml) || String.isBlank(tagName)) {
      return null;
    }
    String open = '<' + tagName + '>';
    String close = '</' + tagName + '>';
    Integer start = xml.indexOf(open);
    if (start < 0) {
      // allow attributes on open tag
      Pattern p = Pattern.compile('(?i)<' + tagName + '(?:\\s[^>]*)?>\\s*([^<]+)\\s*</' + tagName + '>');
      Matcher m = p.matcher(xml);
      return m.find() ? m.group(1).trim() : null;
    }
    Integer contentStart = start + open.length();
    Integer closeAt = xml.indexOf(close, contentStart);
    if (closeAt < 0) {
      return null;
    }
    return xml.substring(contentStart, closeAt).trim();
  }

  @TestVisible
  private static Id storeCommitSelectionsFile(
    Id userStoryId,
    List<Map<String, Object>> selections
  ) {
    if (selections == null || selections.isEmpty()) {
      return null;
    }
    try {
      // Reuse one Notes & Attachments file on the User Story (new ContentVersion).
      // Creating a fresh file every Commit left many "Copado Commit changes" rows.
      Id existingDocId = findLatestCommitChangesDocument(userStoryId);

      ContentVersion cv = new ContentVersion();
      cv.Title = 'Copado Commit changes';
      cv.PathOnClient = 'Copado Commit changes.json';
      cv.VersionData = Blob.valueOf(JSON.serialize(selections));
      if (existingDocId != null) {
        cv.ContentDocumentId = existingDocId;
      } else if (userStoryId != null) {
        cv.FirstPublishLocationId = userStoryId;
      }
      insert cv;

      // Keep a single document on the story; remove older duplicates from prior runs.
      Id keepDocId = existingDocId;
      if (keepDocId == null) {
        List<ContentVersion> created = [
          SELECT ContentDocumentId
          FROM ContentVersion
          WHERE Id = :cv.Id
          LIMIT 1
        ];
        keepDocId = created.isEmpty() ? null : created[0].ContentDocumentId;
      }
      cleanupDuplicateCommitChangesDocuments(userStoryId, keepDocId);

      // sfdx_commit_1 uses: copado --downloadfiles <Id>
      // Successful Copado runs pass a ContentVersion Id (068...), not Document (069).
      return cv.Id;
    } catch (Exception ex) {
      throw new CopadoAiApiService.ApiException(
        'Failed to store Copado commit selections file: ' + ex.getMessage()
      );
    }
  }

  /** Latest ContentDocument titled "Copado Commit changes" linked to the User Story. */
  private static Id findLatestCommitChangesDocument(Id userStoryId) {
    if (userStoryId == null) {
      return null;
    }
    try {
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.LatestPublishedVersionId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :userStoryId
          AND ContentDocument.Title = 'Copado Commit changes'
        ORDER BY SystemModstamp DESC
        LIMIT 20
      ];
      return links.isEmpty() ? null : links[0].ContentDocumentId;
    } catch (Exception ignore) {
      return null;
    }
  }

  /** Delete older duplicate "Copado Commit changes" documents; keep one. */
  private static void cleanupDuplicateCommitChangesDocuments(Id userStoryId, Id keepDocId) {
    if (userStoryId == null || keepDocId == null) {
      return;
    }
    try {
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :userStoryId
          AND ContentDocument.Title = 'Copado Commit changes'
          AND ContentDocumentId != :keepDocId
      ];
      Set<Id> toDelete = new Set<Id>();
      for (ContentDocumentLink link : links) {
        toDelete.add(link.ContentDocumentId);
      }
      if (!toDelete.isEmpty()) {
        List<ContentDocument> docs = [
          SELECT Id FROM ContentDocument WHERE Id IN :toDelete
        ];
        Database.delete(docs, false);
      }
    } catch (Exception ignore) {
    }
  }

  /** @deprecated use buildCommitSelections + storeCommitSelectionsFile(List) */
  @TestVisible
  private static Id storeCommitSelectionsFile(Id userStoryId, String packageJson) {
    return storeCommitSelectionsFile(userStoryId, buildCommitSelections(packageJson));
  }

  /** Accept ContentVersion or ContentDocument Id; return ContentDocument Id for linking. */
  @TestVisible
  private static Id resolveContentDocumentId(Id contentVersionOrDocumentId) {
    if (contentVersionOrDocumentId == null) {
      return null;
    }
    if (contentVersionOrDocumentId.getSObjectType() == ContentDocument.SObjectType) {
      return contentVersionOrDocumentId;
    }
    if (contentVersionOrDocumentId.getSObjectType() == ContentVersion.SObjectType) {
      List<ContentVersion> versions = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :contentVersionOrDocumentId
        LIMIT 1
      ];
      return versions.isEmpty() ? null : versions[0].ContentDocumentId;
    }
    return null;
  }

  /** Exact org picklist values for copado__Promotion__c.copado__Status__c (Copado AI). */
  private static final Set<String> PROMOTION_SUCCESS_STATUSES = new Set<String>{
    'Completed',
    'Validated'
  };
  private static final Set<String> PROMOTION_FAILED_STATUSES = new Set<String>{
    'Completed with errors',
    'Validation failed',
    'Merge Conflict',
    'Cancelled'
  };
  private static final Set<String> PROMOTION_IN_PROGRESS_STATUSES = new Set<String>{
    'Draft',
    'Scheduled',
    'In Progress',
    'Conflicts Resolved'
  };

  /**
   * Authoritative Validate / Deploy-next outcome from the Promotion record Status
   * (not a single Promote Job Execution). Promote JE can be Successful while the
   * dry-run Deploy step fails → Promotion Status = "Validation failed".
   */
  public static JobStatus getPromotionPipelineStatus(Id promotionId) {
    JobStatus result = new JobStatus();
    result.jobId = promotionId != null ? String.valueOf(promotionId) : null;
    result.status = 'Unknown';
    result.isComplete = false;
    result.isFailed = false;
    if (promotionId == null) {
      result.summary = 'No Promotion Id.';
      return result;
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      result.status = 'Validated';
      result.isComplete = true;
      result.summary = 'Mock promotion validated.';
      return result;
    }

    Schema.SObjectType promoType = Schema.getGlobalDescribe().get('copado__Promotion__c');
    if (promoType == null) {
      result.summary = 'Promotion object not available.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = promoType.getDescribe().fields.getMap();
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'Status'
    });
    if (statusField == null) {
      result.summary = 'Promotion Status field not found.';
      return result;
    }
    try {
      Id pid = promotionId;
      List<SObject> rows = Database.query(
        'SELECT Id, Name, ' + statusField
        + ' FROM copado__Promotion__c WHERE Id = :pid LIMIT 1'
      );
      if (rows.isEmpty()) {
        result.summary = 'Promotion not found.';
        return result;
      }
      String statusVal = rows[0].get(statusField) != null
        ? String.valueOf(rows[0].get(statusField)).trim()
        : '';
      result.status = String.isNotBlank(statusVal) ? statusVal : 'Unknown';
      classifyPromotionStatus(result, statusVal);

      // While Status is still in progress / unknown, check sibling Job Executions
      // (Promote may succeed while Deploy validate fails before Status flips).
      if (!result.isComplete || String.isBlank(statusVal)) {
        JobStatus fromJobs = aggregatePromotionJobExecutions(promotionId);
        if (fromJobs != null && fromJobs.isFailed == true) {
          result.isFailed = true;
          result.isComplete = true;
          result.status = String.isNotBlank(fromJobs.status) ? fromJobs.status : result.status;
          result.summary = fromJobs.summary;
          result.errorMessage = fromJobs.errorMessage;
        }
      }
      // Always attach deploy-step error text when Promotion failed — needed for chat fix-ups.
      if (result.isFailed == true) {
        String deployErr = extractPromotionDeployFailureDetail(promotionId);
        if (String.isNotBlank(deployErr)) {
          result.errorMessage = deployErr;
          // Prefer the Result / Deploy error as the summary (UI + Copy error use this).
          result.summary = truncate(deployErr, 3500);
        }
      }
      if (String.isBlank(result.summary)) {
        result.summary = 'Promotion status: ' + result.status;
      }
    } catch (Exception ex) {
      result.summary = 'Could not read Promotion status: ' + ex.getMessage();
    }
    return result;
  }

  @TestVisible
  private static void classifyPromotionStatus(JobStatus result, String statusVal) {
    if (String.isBlank(statusVal)) {
      result.isComplete = false;
      result.isFailed = false;
      result.summary = 'Promotion status blank (waiting).';
      return;
    }
    // Exact picklist API values from this org (case-sensitive).
    if (PROMOTION_FAILED_STATUSES.contains(statusVal)) {
      result.isFailed = true;
      result.isComplete = true;
      result.summary = 'Promotion ' + statusVal;
      result.errorMessage = statusVal;
      return;
    }
    if (PROMOTION_SUCCESS_STATUSES.contains(statusVal)) {
      result.isFailed = false;
      result.isComplete = true;
      result.summary = 'Promotion status: ' + statusVal;
      return;
    }
    if (PROMOTION_IN_PROGRESS_STATUSES.contains(statusVal)) {
      result.isComplete = false;
      result.isFailed = false;
      result.summary = 'Promotion status: ' + statusVal + ' (still running).';
      return;
    }
    // Unknown / new picklist value — do not treat as success.
    result.isComplete = false;
    result.isFailed = false;
    result.summary =
      'Promotion status: ' + statusVal + ' (unrecognized — waiting for terminal status).';
  }

  @TestVisible
  private static Boolean isPromotionSuccessStatus(String statusVal) {
    return String.isNotBlank(statusVal) && PROMOTION_SUCCESS_STATUSES.contains(statusVal);
  }

  @TestVisible
  private static Boolean isPromotionFailedStatus(String statusVal) {
    return String.isNotBlank(statusVal) && PROMOTION_FAILED_STATUSES.contains(statusVal);
  }

  /**
   * Scan recent Job Executions linked to the Promotion. Any Failed JE means the
   * overall validate/deploy failed even if the Promote JE succeeded.
   */
  @TestVisible
  private static JobStatus aggregatePromotionJobExecutions(Id promotionId) {
    JobStatus agg = new JobStatus();
    agg.isComplete = false;
    agg.isFailed = false;
    if (promotionId == null) {
      return agg;
    }
    Datetime since = Datetime.now().addHours(-12);
    List<Id> jobIds = listJobExecutionsForPromotion(promotionId, since, 10);
    if (jobIds.isEmpty()) {
      return agg;
    }
    Boolean anyIncomplete = false;
    Boolean anyFailed = false;
    String failSummary = null;
    Integer successCount = 0;
    for (Id jobId : jobIds) {
      JobStatus st = getJobExecutionStatus(String.valueOf(jobId), false);
      if (st == null) {
        continue;
      }
      if (st.isFailed == true) {
        anyFailed = true;
        // Prefer raw errorMessage over "Job failed: …" wrapper when present.
        failSummary = String.isNotBlank(st.errorMessage) ? st.errorMessage : st.summary;
      } else if (st.isComplete == true) {
        successCount++;
      } else {
        anyIncomplete = true;
      }
    }
    if (anyFailed) {
      agg.isFailed = true;
      agg.isComplete = true;
      agg.status = 'Failed';
      agg.errorMessage = failSummary;
      agg.summary = String.isNotBlank(failSummary)
        ? failSummary
        : 'A Promotion Job Execution failed (check SFDX Deploy / validate step).';
      return agg;
    }
    if (anyIncomplete) {
      agg.isComplete = false;
      agg.status = 'In Progress';
      agg.summary = 'Promotion jobs still running.';
      return agg;
    }
    if (successCount > 0) {
      agg.isComplete = true;
      agg.status = 'Successful';
      agg.summary = 'Promotion Job Executions completed successfully.';
    }
    return agg;
  }

  /**
   * Pull the real Deploy / validate failure text from Job Executions + Job Steps
   * on the Promotion (Promote JE is often Successful while Deploy fails).
   *
   * Authoritative source (this org / Copado AI):
   *   copado__Result__c.copado__Error_Message__c on the failed Deploy Job Step Result.
   * Fallback: JobExecution.ErrorMessage, then ValidationResult.json / ResultViewer.json.
   * Uses bulk SOQL (avoid SOQL 101 during getSessionState).
   */
  @TestVisible
  private static String extractPromotionDeployFailureDetail(Id promotionId) {
    if (promotionId == null) {
      return null;
    }
    // Safe CreatedDate window — never null (null breaks SOQL CreatedDate compare).
    Datetime since = Datetime.now().addDays(-7);

    // 0) Org-verified hard-coded path (ParentId = Promotion → JE → Step → Result).
    String verified = extractViaOrgVerifiedPromotionQueries(promotionId, since);
    if (String.isNotBlank(verified)) {
      return truncate(verified, 3500);
    }

    // 1–2) Dynamic discovery (legacy multi-field parent probes).
    List<Id> jobIds = listJobExecutionsForPromotion(promotionId, since, 20);
    List<String> candidates = new List<String>();
    if (!jobIds.isEmpty()) {
      String fromResults = extractFailedResultErrorMessageForJobs(jobIds);
      if (String.isNotBlank(fromResults)) {
        candidates.add(fromResults);
      }
      // Field: copado__JobExecution__c.copado__ErrorMessage__c (no underscore).
      String fromJe = extractJobExecutionErrorMessagesBulk(jobIds);
      if (String.isNotBlank(fromJe)) {
        candidates.add(fromJe);
      }
    }

    // 3) Metadata Validation Results — no CreatedBy filter (often Copado integration user).
    if (candidates.isEmpty() || bestDeployFailureScore(candidates) < 50) {
      String recent = extractRecentMetadataValidationError(since);
      if (String.isNotBlank(recent)) {
        candidates.add(recent);
      }
    }

    return pickBestDeployFailureText(candidates);
  }

  /**
   * Copado AI ground-truth queries with org-verified field API names.
   * Hard-coded so firstExisting() cannot pick JE ErrorMessage on Result.
   */
  @TestVisible
  private static String extractViaOrgVerifiedPromotionQueries(Id promotionId, Datetime since) {
    if (promotionId == null) {
      return null;
    }
    Datetime notBefore = since != null ? since : Datetime.now().addDays(-7);
    Set<Id> jobIds = new Set<Id>();
    List<String> candidates = new List<String>();
    // ParentId on JE stores 15-char Promotion Id as text (Copado AI).
    // Match 15- and 18-char forms — text ParentId misses Id-only binds.
    String promo18 = String.valueOf(promotionId);
    String promo15 = promo18.length() >= 15 ? promo18.substring(0, 15) : promo18;

    // Job Executions: ParentId / ParentRecord_Id / Promotion__c
    // Error rollup: copado__ErrorMessage__c (JE) — SELECT only, never filter.
    for (String parentFilter : new List<String>{
      '(copado__ParentId__c = :promotionId OR copado__ParentId__c = :promo15 OR copado__ParentId__c = :promo18)',
      '(copado__ParentRecord_Id__c = :promo15 OR copado__ParentRecord_Id__c = :promo18)',
      'copado__Promotion__c = :promotionId'
    }) {
      if (!jobIds.isEmpty()) {
        break;
      }
      try {
        String soql =
          'SELECT Id, Name, copado__Status__c, copado__ErrorMessage__c'
          + ' FROM copado__JobExecution__c'
          + ' WHERE ' + parentFilter
          + ' AND CreatedDate >= :notBefore'
          + ' ORDER BY CreatedDate DESC LIMIT 20';
        for (SObject row : Database.query(soql)) {
          jobIds.add((Id) row.get('Id'));
          Object em = row.get('copado__ErrorMessage__c');
          if (em != null) {
            String err = String.valueOf(em).trim();
            if (isUsefulDeployFailureText(err)) {
              candidates.add(err);
            }
          }
        }
      } catch (Exception ex) {
        System.debug(LoggingLevel.WARN, 'extractViaOrgVerified JE: ' + ex.getMessage());
      }
    }
    // Prefer JE ErrorMessage when present (JE-069 rollup is org-verified).
    String fromJeEarly = pickBestDeployFailureText(candidates);
    if (String.isNotBlank(fromJeEarly) && scoreDeployFailureText(fromJeEarly) >= 50) {
      return fromJeEarly;
    }
    if (jobIds.isEmpty()) {
      return fromJeEarly;
    }

    // Job Steps: copado__JobStep__c.copado__JobExecution__c
    Set<Id> stepIds = new Set<Id>();
    Map<Id, String> stepNames = new Map<Id, String>();
    try {
      for (SObject row : Database.query(
        'SELECT Id, Name FROM copado__JobStep__c'
          + ' WHERE copado__JobExecution__c IN :jobIds'
          + ' ORDER BY CreatedDate DESC LIMIT 200'
      )) {
        Id sid = (Id) row.get('Id');
        stepIds.add(sid);
        stepNames.put(sid, row.get('Name') != null ? String.valueOf(row.get('Name')) : '');
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractViaOrgVerified JobStep: ' + ex.getMessage());
    }

    // Results: copado__Error_Message__c (Result field, WITH underscore).
    // ParentId polymorphic → JobStep or JobExecution.
    Set<Id> parentIds = new Set<Id>();
    parentIds.addAll(jobIds);
    parentIds.addAll(stepIds);
    try {
      String soql =
        'SELECT Id, Name, copado__Status__c, copado__Error_Message__c, copado__ParentId__c'
        + ' FROM copado__Result__c'
        + ' WHERE copado__Status__c IN (\'Failed\', \'Error\')'
        + ' AND CreatedDate >= :notBefore'
        + ' AND copado__ParentId__c IN :parentIds'
        + ' ORDER BY CreatedDate DESC LIMIT 30';
      String best = null;
      Integer bestScore = -999;
      Set<Id> resultIds = new Set<Id>();
      for (SObject row : Database.query(soql)) {
        resultIds.add((Id) row.get('Id'));
        Object em = row.get('copado__Error_Message__c');
        if (em == null) {
          continue;
        }
        String err = String.valueOf(em).trim();
        if (!isUsefulDeployFailureText(err)) {
          continue;
        }
        Integer sc = scoreDeployFailureText(err);
        if (err.length() > 100) {
          sc += 3;
        }
        Id parentId = row.get('copado__ParentId__c') != null
          ? (Id) row.get('copado__ParentId__c')
          : null;
        if (parentId != null && stepNames.containsKey(parentId)) {
          String nm = stepNames.get(parentId).toLowerCase();
          if (nm.contains('deploy')) {
            sc += 50;
          } else if (nm.contains('promote') && !nm.contains('deploy')) {
            sc -= 40;
          }
        }
        if (best == null || sc > bestScore) {
          best = err;
          bestScore = sc;
        }
      }
      if (String.isNotBlank(best)) {
        return best;
      }
      if (!resultIds.isEmpty()) {
        String fromFiles = readErrorFromRelatedFiles(resultIds);
        if (isUsefulDeployFailureText(fromFiles)) {
          String meta = extractMetadataValidationLine(fromFiles);
          return String.isNotBlank(meta) ? meta : fromFiles;
        }
        String fromCv = readErrorFromContentVersionFirstPublish(resultIds);
        if (isUsefulDeployFailureText(fromCv)) {
          String meta = extractMetadataValidationLine(fromCv);
          return String.isNotBlank(meta) ? meta : fromCv;
        }
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractViaOrgVerified Result: ' + ex.getMessage());
    }

    return pickBestDeployFailureText(candidates);
  }

  /** ContentVersion via FirstPublishLocationId = Result Id (Copado AI). */
  private static String readErrorFromContentVersionFirstPublish(Set<Id> resultIds) {
    if (resultIds == null || resultIds.isEmpty()) {
      return null;
    }
    try {
      for (ContentVersion cv : [
        SELECT Title, PathOnClient, VersionData, FirstPublishLocationId
        FROM ContentVersion
        WHERE FirstPublishLocationId IN :resultIds
        ORDER BY CreatedDate DESC
        LIMIT 20
      ]) {
        String title = ((cv.Title != null ? cv.Title : '')
          + ' '
          + (cv.PathOnClient != null ? cv.PathOnClient : '')).toLowerCase();
        if (!(title.contains('valid')
          || title.contains('result')
          || title.contains('viewer')
          || title.contains('error')
          || title.contains('fail'))) {
          continue;
        }
        String body = cv.VersionData != null ? cv.VersionData.toString() : null;
        if (String.isBlank(body) || isPromoteNoiseLog(body)) {
          continue;
        }
        String fromJson = extractErrorFromJsonBlob(body);
        if (isUsefulDeployFailureText(fromJson)) {
          return fromJson;
        }
        if (isUsefulDeployFailureText(body)) {
          String extracted = extractMetadataValidationLine(body);
          return String.isNotBlank(extracted) ? extracted : truncate(body.trim(), 2500);
        }
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  /**
   * Recent Failed/Error Results — filter Error_Message in Apex only.
   * copado__Error_Message__c is NOT filterable in SOQL (Copado AI).
   */
  @TestVisible
  private static String extractRecentMetadataValidationError(Datetime since) {
    Datetime notBefore = since != null ? since : Datetime.now().addDays(-7);
    try {
      List<String> candidates = new List<String>();
      for (SObject row : Database.query(
        'SELECT Id, copado__Error_Message__c'
          + ' FROM copado__Result__c'
          + ' WHERE CreatedDate >= :notBefore'
          + ' AND copado__Status__c IN (\'Failed\', \'Error\')'
          + ' ORDER BY CreatedDate DESC LIMIT 40'
      )) {
        Object em = row.get('copado__Error_Message__c');
        if (em == null) {
          continue;
        }
        // Filter in Apex — Error_Message__c is not SOQL-filterable (Copado AI).
        String err = String.valueOf(em).trim();
        String lower = err.toLowerCase();
        if ((lower.contains('metadata validation')
            || lower.contains('customfield')
            || scoreDeployFailureText(err) >= 40)
          && isUsefulDeployFailureText(err)) {
          candidates.add(err);
        }
      }
      return pickBestDeployFailureText(candidates);
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractRecentMetadataValidationError: ' + ex.getMessage());
      return null;
    }
  }

  /**
   * Public wrapper for Validate failure UI — pulls Result.Error_Message for a Promotion.
   * Used when status-only summary leaked into the Builder panel.
   */
  public static String debugExtractPromotionDeployFailure(Id promotionId) {
    return extractPromotionDeployFailureDetail(promotionId);
  }

  private static Integer bestDeployFailureScore(List<String> texts) {
    Integer best = -999;
    if (texts == null) {
      return best;
    }
    for (String t : texts) {
      Integer sc = scoreDeployFailureText(t);
      if (sc > best) {
        best = sc;
      }
    }
    return best;
  }

  private static String pickBestDeployFailureText(List<String> scored) {
    if (scored == null || scored.isEmpty()) {
      return null;
    }
    String best = null;
    Integer bestScore = -999;
    Set<String> seen = new Set<String>();
    for (String p : scored) {
      if (String.isBlank(p) || !isUsefulDeployFailureText(p)) {
        continue;
      }
      String key = p.length() > 120 ? p.substring(0, 120) : p;
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      Integer sc = scoreDeployFailureText(p);
      // Richer messages win when scores tie (Copado AI Issue 2).
      if (p.length() > 100) {
        sc += 3;
      }
      if (best == null || sc > bestScore) {
        best = p;
        bestScore = sc;
      }
    }
    return String.isNotBlank(best) ? truncate(best, 3500) : null;
  }

  /** One SOQL: ErrorMessage on all Job Executions for the Promotion. */
  @TestVisible
  private static String extractJobExecutionErrorMessagesBulk(List<Id> jobExecutionIds) {
    if (jobExecutionIds == null || jobExecutionIds.isEmpty()) {
      return null;
    }
    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    // copado__ErrorMessage__c is on copado__JobExecution__c, NOT on Result.
    String errorField = firstExisting(fields, new List<String>{
      'copado__ErrorMessage__c',
      'copado__Message__c'
    });
    if (errorField == null) {
      return null;
    }
    Set<Id> jobIds = new Set<Id>(jobExecutionIds);
    try {
      List<SObject> rows = Database.query(
        'SELECT Id, Name, ' + errorField
        + ' FROM ' + jobType.getDescribe().getName()
        + ' WHERE Id IN :jobIds'
        + ' ORDER BY CreatedDate DESC LIMIT 20'
      );
      List<String> candidates = new List<String>();
      for (SObject row : rows) {
        if (row.get(errorField) == null) {
          continue;
        }
        String err = String.valueOf(row.get(errorField)).trim();
        if (isUsefulDeployFailureText(err)) {
          candidates.add(err);
        }
      }
      return pickBestDeployFailureText(candidates);
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractJobExecutionErrorMessagesBulk: ' + ex.getMessage());
      return null;
    }
  }

  /**
   * Query Failed Results for Job Steps / Job Executions (bulk).
   * Field: copado__Result__c.copado__Error_Message__c (underscore — NOT ErrorMessage).
   */
  @TestVisible
  private static String extractFailedResultErrorMessageForJobs(List<Id> jobExecutionIds) {
    if (jobExecutionIds == null || jobExecutionIds.isEmpty()) {
      return null;
    }
    Set<Id> jobIds = new Set<Id>(jobExecutionIds);
    Map<Id, String> stepNamesById = findJobStepNamesForJobs(jobIds);
    Set<Id> stepIds = stepNamesById.keySet();
    Set<Id> deployStepIds = new Set<Id>();
    for (Id stepId : stepNamesById.keySet()) {
      String nm = stepNamesById.get(stepId);
      if (String.isNotBlank(nm) && nm.toLowerCase().contains('deploy')) {
        deployStepIds.add(stepId);
      }
    }

    Schema.SObjectType resultType = Schema.getGlobalDescribe().get('copado__Result__c');
    if (resultType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = resultType.getDescribe().fields.getMap();
    // copado__Error_Message__c is on copado__Result__c, NOT copado__JobExecution__c.
    // Do not probe ErrorMessage__c here — that field belongs to Job Execution.
    String errField = firstExisting(fields, new List<String>{
      'copado__Error_Message__c',
      'copado__Message__c'
    });
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'Status'
    });
    String jobStepField = firstExisting(fields, new List<String>{
      'copado__JobStep__c', 'copado__Job_Step__c'
    });
    // Polymorphic parent: JobStep or JobExecution (Copado AI).
    String parentField = firstExisting(fields, new List<String>{
      'copado__ParentId__c', 'copado__Parent_Id__c'
    });
    String jobTypeField = firstExisting(fields, new List<String>{
      'copado__Job_Type__c', 'copado__JobType__c', 'copado__Type__c'
    });
    if (errField == null) {
      return null;
    }

    List<String> selectFields = new List<String>{ 'Id', 'Name', errField };
    if (statusField != null) {
      selectFields.add(statusField);
    }
    if (jobStepField != null) {
      selectFields.add(jobStepField);
    }
    if (parentField != null) {
      selectFields.add(parentField);
    }
    if (jobTypeField != null) {
      selectFields.add(jobTypeField);
    }

    // Prefer Deploy JobSteps when known; still allow ParentId→JE as fallback.
    List<String> whereParts = new List<String>();
    Set<Id> preferredStepIds = !deployStepIds.isEmpty() ? deployStepIds : stepIds;
    if (jobStepField != null && !preferredStepIds.isEmpty()) {
      whereParts.add(jobStepField + ' IN :preferredStepIds');
    }
    if (parentField != null) {
      if (!preferredStepIds.isEmpty()) {
        whereParts.add(parentField + ' IN :preferredStepIds');
      }
      // Broader: any Result parented to Promotion JEs (Deploy JE Error rollup path).
      whereParts.add(parentField + ' IN :jobIds');
    }
    if (whereParts.isEmpty()) {
      return null;
    }

    try {
      String soql =
        'SELECT ' + String.join(selectFields, ',')
        + ' FROM copado__Result__c'
        + ' WHERE (' + String.join(whereParts, ' OR ') + ')';
      if (statusField != null) {
        // Result Status values (org-verified): Failed, Error, Success
        soql += ' AND (' + statusField + ' = \'Failed\' OR ' + statusField + ' = \'Error\')';
      }
      soql += ' ORDER BY CreatedDate DESC LIMIT 30';
      List<SObject> rows = Database.query(soql);
      String best = null;
      Integer bestScore = -999;
      Set<Id> resultIdsMissingText = new Set<Id>();
      for (SObject row : rows) {
        if (row.get(errField) == null) {
          resultIdsMissingText.add((Id) row.get('Id'));
          continue;
        }
        String err = String.valueOf(row.get(errField)).trim();
        if (!isUsefulDeployFailureText(err)) {
          resultIdsMissingText.add((Id) row.get('Id'));
          continue;
        }
        Integer sc = scoreDeployFailureText(err);
        if (err.length() > 100) {
          sc += 3;
        }
        // Boost Deploy-step Results (Copado AI Issue 2) — avoid Promote/Merge Result noise.
        Id linkedStep = null;
        if (jobStepField != null && row.get(jobStepField) != null) {
          linkedStep = (Id) row.get(jobStepField);
        } else if (parentField != null && row.get(parentField) != null) {
          linkedStep = (Id) row.get(parentField);
        }
        if (linkedStep != null) {
          String stepName = stepNamesById.get(linkedStep);
          if (String.isNotBlank(stepName) && stepName.toLowerCase().contains('deploy')) {
            sc += 50;
          } else if (deployStepIds.contains(linkedStep)) {
            sc += 50;
          } else if (String.isNotBlank(stepName)
            && stepName.toLowerCase().contains('promote')
            && !stepName.toLowerCase().contains('deploy')) {
            sc -= 40;
          }
        }
        if (jobTypeField != null && row.get(jobTypeField) != null) {
          String jt = String.valueOf(row.get(jobTypeField)).toLowerCase();
          if (jt.contains('deploy') || jt.contains('promotiondeployment')) {
            sc += 20;
          }
        }
        if (best == null || sc > bestScore) {
          best = err;
          bestScore = sc;
        }
      }
      if (String.isNotBlank(best)) {
        return best;
      }
      // No Error_Message — try ValidationResult.json / ResultViewer.json (one bulk read).
      if (!resultIdsMissingText.isEmpty()) {
        String fromFiles = readErrorFromRelatedFiles(resultIdsMissingText);
        if (isUsefulDeployFailureText(fromFiles)) {
          String meta = extractMetadataValidationLine(fromFiles);
          return String.isNotBlank(meta) ? meta : fromFiles;
        }
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractFailedResultErrorMessageForJobs: ' + ex.getMessage());
    }
    return null;
  }

  /** Bulk Job Step Id → Name for many Job Executions (1–2 SOQL). */
  private static Map<Id, String> findJobStepNamesForJobs(Set<Id> jobExecutionIds) {
    Map<Id, String> stepNames = new Map<Id, String>();
    if (jobExecutionIds == null || jobExecutionIds.isEmpty()) {
      return stepNames;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      // Lookup: copado__JobStep__c.copado__JobExecution__c → parent JE
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c', 'copado__Job__c'
      });
      if (jeField == null) {
        continue;
      }
      String nameField = firstExisting(fields, new List<String>{ 'Name', 'copado__Name__c' });
      List<String> selectFields = new List<String>{ 'Id' };
      if (nameField != null) {
        selectFields.add(nameField);
      }
      try {
        for (SObject row : Database.query(
          'SELECT ' + String.join(selectFields, ',')
            + ' FROM ' + objectName
            + ' WHERE ' + jeField + ' IN :jobExecutionIds'
            + ' ORDER BY CreatedDate DESC LIMIT 200'
        )) {
          Id sid = (Id) row.get('Id');
          String nm = nameField != null && row.get(nameField) != null
            ? String.valueOf(row.get(nameField))
            : '';
          stepNames.put(sid, nm);
        }
        if (!stepNames.isEmpty()) {
          return stepNames;
        }
      } catch (Exception ignore) {
      }
    }
    return stepNames;
  }

  /**
   * Fallback when Deploy JE is not linked to the Promotion parent fields:
   * recent Failed Results created by the running user with deploy-like Error_Message.
   */
  @TestVisible
  private static String extractRecentFailedResultErrorMessage(Datetime since) {
    Schema.SObjectType resultType = Schema.getGlobalDescribe().get('copado__Result__c');
    if (resultType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = resultType.getDescribe().fields.getMap();
    // copado__Error_Message__c is on copado__Result__c, NOT copado__JobExecution__c.
    String errField = firstExisting(fields, new List<String>{
      'copado__Error_Message__c',
      'copado__Message__c'
    });
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'Status'
    });
    if (errField == null) {
      return null;
    }
    Id uid = UserInfo.getUserId();
    Datetime notBefore = since != null ? since : Datetime.now().addDays(-7);
    try {
      String soql =
        'SELECT Id, ' + errField
        + ' FROM copado__Result__c'
        + ' WHERE CreatedDate >= :notBefore'
        + ' AND CreatedById = :uid';
      if (statusField != null) {
        soql += ' AND (' + statusField + ' = \'Failed\' OR ' + statusField + ' = \'Error\')';
      }
      soql += ' ORDER BY CreatedDate DESC LIMIT 25';
      List<String> candidates = new List<String>();
      for (SObject row : Database.query(soql)) {
        String err = String.valueOf(row.get(errField)).trim();
        if (isUsefulDeployFailureText(err) && scoreDeployFailureText(err) >= 40) {
          candidates.add(err);
        }
      }
      return pickBestDeployFailureText(candidates);
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'extractRecentFailedResultErrorMessage: ' + ex.getMessage());
      return null;
    }
  }

  @TestVisible
  private static Integer scoreDeployFailureText(String text) {
    if (String.isBlank(text) || isPromoteNoiseLog(text)) {
      return -100;
    }
    String lower = text.toLowerCase();
    Integer score = 0;
    if (lower.contains('metadata validation')) {
      score += 100;
    }
    if (lower.contains('customfield') || lower.contains('no customfield')) {
      score += 80;
    }
    if (lower.contains('layout:')) {
      score += 40;
    }
    if (lower.contains('problem')) {
      score += 30;
    }
    if (lower.contains('in field:')) {
      score += 25;
    }
    if (lower.contains('not found')) {
      score += 20;
    }
    if (lower.contains('deploy')) {
      score += 10;
    }
    if (isPromoteNoiseLog(text)) {
      score -= 200;
    }
    return score;
  }

  @TestVisible
  private static Boolean isUsefulDeployFailureText(String text) {
    if (String.isBlank(text)) {
      return false;
    }
    if (isPromoteNoiseLog(text)) {
      return false;
    }
    String lower = text.toLowerCase();
    if (lower.startsWith('job status: successful')
      || lower.startsWith('job status: success')
      || lower.contains('promotion jobs completed')) {
      return false;
    }
    return scoreDeployFailureText(text) >= 10
      || lower.contains('fail')
      || lower.contains('error')
      || lower.contains('exception')
      || lower.contains('validation');
  }

  /** Promote success logs we previously scraped by mistake. */
  @TestVisible
  private static Boolean isPromoteNoiseLog(String text) {
    if (String.isBlank(text)) {
      return true;
    }
    String lower = text.toLowerCase();
    return lower.contains('fetching/creating branch')
      || lower.contains('deduplicating xml')
      || lower.contains('pushing all changes')
      || lower.contains('promotion/p')
      || (lower.contains('feature branch') && !lower.contains('fail') && !lower.contains('error'));
  }

  private static List<Id> orderJobExecutionsDeployFirst(List<Id> jobIds) {
    List<Id> deployish = new List<Id>();
    List<Id> other = new List<Id>();
    for (Id jobId : jobIds) {
      if (jobExecutionLooksLikeDeploy(jobId)) {
        deployish.add(jobId);
      } else {
        other.add(jobId);
      }
    }
    List<Id> ordered = new List<Id>();
    ordered.addAll(deployish);
    ordered.addAll(other);
    return ordered;
  }

  private static Boolean jobExecutionLooksLikeDeploy(Id jobExecutionId) {
    if (jobExecutionId == null) {
      return false;
    }
    try {
      Schema.SObjectType jobType = jobExecutionId.getSObjectType();
      Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
      String nameField = firstExisting(fields, new List<String>{ 'Name', 'copado__Name__c' });
      String dataField = firstExisting(fields, new List<String>{
        'copado__DataJson__c', 'copado__Data_JSON__c', 'copado__VolumeOptions__c'
      });
      List<String> selectFields = new List<String>{ 'Id' };
      if (nameField != null) {
        selectFields.add(nameField);
      }
      if (dataField != null) {
        selectFields.add(dataField);
      }
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
        + ' FROM ' + jobType.getDescribe().getName()
        + ' WHERE Id = :jobExecutionId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return false;
      }
      String haystack = '';
      if (nameField != null && rows[0].get(nameField) != null) {
        haystack += ' ' + String.valueOf(rows[0].get(nameField));
      }
      if (dataField != null && rows[0].get(dataField) != null) {
        haystack += ' ' + String.valueOf(rows[0].get(dataField));
      }
      String lower = haystack.toLowerCase();
      if (lower.contains('promote') && !lower.contains('deploy')) {
        return false;
      }
      return lower.contains('deploy')
        || lower.contains('promotiondeployment')
        || lower.contains('sfdx_deploy')
        || lower.contains('"action":"promotiondeployment"')
        || lower.contains('"action": "promotiondeployment"');
    } catch (Exception ignore) {
      return false;
    }
  }

  /**
   * Best-effort error text from failed Job Steps (and related Result records/files).
   * @param failedStepsOnly when true, ignore successful Promote step logs.
   */
  @TestVisible
  private static String extractFailedJobStepError(Id jobExecutionId) {
    return extractFailedJobStepError(jobExecutionId, true);
  }

  @TestVisible
  private static String extractFailedJobStepError(Id jobExecutionId, Boolean failedStepsOnly) {
    if (jobExecutionId == null) {
      return null;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c', 'copado__Job__c'
      });
      if (jeField == null) {
        continue;
      }
      String statusField = firstExisting(fields, new List<String>{
        'copado__Status__c', 'copado__JobStepStatus__c', 'Status'
      });
      String nameField = firstExisting(fields, new List<String>{ 'Name', 'copado__Name__c' });
      String typeField = firstExisting(fields, new List<String>{
        'copado__Type__c', 'Type__c'
      });
      String errField = firstExisting(fields, new List<String>{
        'copado__ErrorMessage__c', 'copado__Error_Message__c', 'copado__Message__c'
      });
      String resultField = firstExisting(fields, new List<String>{
        'copado__Result__c', 'copado__ResultId__c'
      });
      String resultDataField = firstExisting(fields, new List<String>{
        'copado__ResultDataJson__c',
        'copado__Result_Data_JSON__c',
        'copado__ResultData__c'
      });
      List<String> selectFields = new List<String>{ 'Id' };
      if (nameField != null) {
        selectFields.add(nameField);
      }
      if (typeField != null) {
        selectFields.add(typeField);
      }
      if (statusField != null) {
        selectFields.add(statusField);
      }
      if (errField != null) {
        selectFields.add(errField);
      }
      if (resultField != null) {
        selectFields.add(resultField);
      }
      if (resultDataField != null) {
        selectFields.add(resultDataField);
      }
      try {
        Id jeId = jobExecutionId;
        String soql =
          'SELECT ' + String.join(selectFields, ',')
          + ' FROM ' + objectName
          + ' WHERE ' + jeField + ' = :jeId'
          + ' ORDER BY CreatedDate ASC NULLS LAST LIMIT 20';
        List<SObject> steps = Database.query(soql);
        List<String> candidates = new List<String>();
        for (SObject step : steps) {
          String st = statusField != null && step.get(statusField) != null
            ? String.valueOf(step.get(statusField)).toLowerCase()
            : '';
          Boolean failed =
            st.contains('fail')
            || st.contains('error')
            || st.contains('cancel');
          if (failedStepsOnly == true && !failed) {
            continue;
          }
          String stepName = nameField != null && step.get(nameField) != null
            ? String.valueOf(step.get(nameField))
            : 'Job Step';
          String stepType = typeField != null && step.get(typeField) != null
            ? String.valueOf(step.get(typeField))
            : '';
          // Skip known Promote-only step names when looking for deploy errors.
          String nameLower = (stepName + ' ' + stepType).toLowerCase();
          if (nameLower.contains('promote') && !nameLower.contains('deploy') && !failed) {
            continue;
          }

          String err = errField != null && step.get(errField) != null
            ? String.valueOf(step.get(errField)).trim()
            : null;
          if (String.isBlank(err) && resultDataField != null && step.get(resultDataField) != null) {
            err = extractErrorFromJsonBlob(String.valueOf(step.get(resultDataField)));
          }
          if (String.isBlank(err) && resultField != null && step.get(resultField) != null) {
            try {
              err = readResultRecordError((Id) step.get(resultField));
            } catch (Exception ignore) {
            }
          }
          if (String.isBlank(err) && failed) {
            Set<Id> linkIds = new Set<Id>{ (Id) step.get('Id') };
            if (resultField != null && step.get(resultField) != null) {
              linkIds.add((Id) step.get(resultField));
            }
            err = readErrorFromRelatedFiles(linkIds);
          }
          if (!isUsefulDeployFailureText(err)) {
            continue;
          }
          candidates.add(truncate(stepName + ': ' + err, 2500));
        }
        if (!candidates.isEmpty()) {
          String best = null;
          Integer bestScore = -999;
          for (String c : candidates) {
            Integer sc = scoreDeployFailureText(c);
            if (best == null || sc > bestScore) {
              best = c;
              bestScore = sc;
            }
          }
          return best;
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  private static String readResultRecordError(Id resultId) {
    if (resultId == null) {
      return null;
    }
    Schema.SObjectType resultType = resultId.getSObjectType();
    if (resultType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = resultType.getDescribe().fields.getMap();
    // copado__Error_Message__c is on copado__Result__c, NOT copado__JobExecution__c.
    String errField = firstExisting(fields, new List<String>{
      'copado__Error_Message__c',
      'copado__Message__c',
      'copado__Result_Data__c',
      'copado__ResultData__c',
      'copado__Result_Data_JSON__c'
    });
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'Status'
    });
    List<String> selectFields = new List<String>{ 'Id' };
    if (errField != null) {
      selectFields.add(errField);
    }
    if (statusField != null) {
      selectFields.add(statusField);
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
        + ' FROM ' + resultType.getDescribe().getName()
        + ' WHERE Id = :resultId LIMIT 1'
      );
      if (rows.isEmpty()) {
        return null;
      }
      SObject row = rows[0];
      if (errField != null && row.get(errField) != null) {
        String raw = String.valueOf(row.get(errField)).trim();
        String fromJson = extractErrorFromJsonBlob(raw);
        return String.isNotBlank(fromJson) ? fromJson : raw;
      }
    } catch (Exception ignore) {
    }
    return readErrorFromRelatedFiles(new Set<Id>{ resultId });
  }

  private static String readErrorFromRelatedFiles(Set<Id> entityIds) {
    if (entityIds == null || entityIds.isEmpty()) {
      return null;
    }
    try {
      List<ContentDocumentLink> links = [
        SELECT ContentDocumentId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :entityIds
        ORDER BY SystemModstamp DESC
        LIMIT 20
      ];
      if (links.isEmpty()) {
        return null;
      }
      Set<Id> docIds = new Set<Id>();
      for (ContentDocumentLink link : links) {
        docIds.add(link.ContentDocumentId);
      }
      for (ContentVersion cv : [
        SELECT Title, PathOnClient, VersionData
        FROM ContentVersion
        WHERE ContentDocumentId IN :docIds AND IsLatest = true
        ORDER BY CreatedDate DESC
        LIMIT 20
      ]) {
        String title = ((cv.Title != null ? cv.Title : '')
          + ' '
          + (cv.PathOnClient != null ? cv.PathOnClient : '')).toLowerCase();
        if (!(title.contains('error')
          || title.contains('fail')
          || title.contains('deploy')
          || title.contains('result')
          || title.contains('valid')
          || title.contains('log')
          || title.contains('output')
          || title.contains('viewer'))) {
          continue;
        }
        String body = cv.VersionData != null ? cv.VersionData.toString() : null;
        if (String.isBlank(body)) {
          continue;
        }
        if (isPromoteNoiseLog(body)) {
          continue;
        }
        String fromJson = extractErrorFromJsonBlob(body);
        if (isUsefulDeployFailureText(fromJson)) {
          return fromJson;
        }
        // Plain text deploy logs — keep the most useful slice
        if (isUsefulDeployFailureText(body)) {
          // Prefer the Metadata Validation line when present in a longer log.
          String extracted = extractMetadataValidationLine(body);
          return truncate(
            String.isNotBlank(extracted) ? extracted : body.trim(),
            2500
          );
        }
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  @TestVisible
  private static String extractMetadataValidationLine(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    for (String line : body.split('\\n')) {
      if (String.isBlank(line)) {
        continue;
      }
      String t = line.trim();
      String lower = t.toLowerCase();
      if (lower.contains('metadata validation')
        || lower.contains('no customfield')
        || (lower.contains('in field:') && lower.contains('not found'))) {
        return t;
      }
    }
    return null;
  }

  @TestVisible
  private static String extractErrorFromJsonBlob(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    if (isPromoteNoiseLog(raw)) {
      return null;
    }
    String trimmed = raw.trim();
    String metaLine = extractMetadataValidationLine(trimmed);
    if (String.isNotBlank(metaLine)) {
      return metaLine;
    }
    // Not JSON — return if it already looks like an error string
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
      return isUsefulDeployFailureText(trimmed) ? truncate(trimmed, 2500) : null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(trimmed);
      List<String> found = new List<String>();
      collectJsonErrorStrings(parsed, found, 0);
      String best = null;
      Integer bestScore = -999;
      for (String f : found) {
        if (!isUsefulDeployFailureText(f)) {
          continue;
        }
        Integer sc = scoreDeployFailureText(f);
        if (best == null || sc > bestScore) {
          best = f;
          bestScore = sc;
        }
      }
      if (String.isNotBlank(best)) {
        return truncate(best, 2500);
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static void collectJsonErrorStrings(Object node, List<String> found, Integer depth) {
    if (node == null || depth > 6 || found.size() >= 8) {
      return;
    }
    if (node instanceof Map<String, Object>) {
      Map<String, Object> m = (Map<String, Object>) node;
      for (String key : m.keySet()) {
        String lower = key != null ? key.toLowerCase() : '';
        Object val = m.get(key);
        if (val == null) {
          continue;
        }
        if (
          lower.contains('error')
          || lower.contains('message')
          || lower.contains('problem')
          || lower.contains('fail')
          || lower == 'details'
          || lower == 'detail'
        ) {
          if (val instanceof String && String.isNotBlank((String) val)) {
            found.add((String) val);
          } else if (val instanceof List<Object>) {
            for (Object item : (List<Object>) val) {
              if (item instanceof String && String.isNotBlank((String) item)) {
                found.add((String) item);
              } else {
                collectJsonErrorStrings(item, found, depth + 1);
              }
            }
          } else {
            collectJsonErrorStrings(val, found, depth + 1);
          }
        } else {
          collectJsonErrorStrings(val, found, depth + 1);
        }
      }
    } else if (node instanceof List<Object>) {
      for (Object item : (List<Object>) node) {
        collectJsonErrorStrings(item, found, depth + 1);
      }
    }
  }

  @TestVisible
  private static List<Id> listJobExecutionsForPromotion(
    Id promotionId,
    Datetime notBefore,
    Integer maxRows
  ) {
    List<Id> ids = new List<Id>();
    if (promotionId == null) {
      return ids;
    }
    Integer lim = maxRows != null && maxRows > 0 ? maxRows : 10;
    for (String objectName : new List<String>{
      'copado__JobExecution__c', 'copado__Job_Execution__c'
    }) {
      Schema.SObjectType jobType = Schema.getGlobalDescribe().get(objectName);
      if (jobType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
      List<String> parentFilters = new List<String>();
      String parentRecordId = firstExisting(fields, new List<String>{
        'copado__ParentRecord_Id__c', 'copado__ParentRecordId__c', 'copado__Parent_Id__c'
      });
      String parentIdField = firstExisting(fields, new List<String>{
        'copado__ParentId__c'
      });
      String promoField = firstExisting(fields, new List<String>{
        'copado__Promotion__c', 'copado__PromotionId__c'
      });
      String dataField = firstExisting(fields, new List<String>{
        'copado__DataJson__c', 'copado__DataJSON__c', 'copado__VolumeOptions__c'
      });
      if (parentRecordId != null) {
        parentFilters.add(parentRecordId + ' = :parentIdStr');
      }
      if (parentIdField != null) {
        parentFilters.add(parentIdField + ' = :promotionId');
      }
      if (promoField != null) {
        parentFilters.add(promoField + ' = :promotionId');
      }
      if (parentFilters.isEmpty() && dataField == null) {
        continue;
      }
      String parentIdStr = String.valueOf(promotionId);
      String promo15 = parentIdStr.length() >= 15 ? parentIdStr.substring(0, 15) : parentIdStr;
      // ParentId may store 15-char text (Copado AI) — also match substring form.
      if (parentIdField != null) {
        parentFilters.add(parentIdField + ' = :promo15');
      }
      if (parentRecordId != null) {
        parentFilters.add(parentRecordId + ' = :promo15');
      }
      // Do NOT OR DataJson LIKE into the primary query — Long Text LIKE can fail
      // the whole SOQL and return zero Job Executions (silent catch).
      if (!parentFilters.isEmpty()) {
        try {
          String soql =
            'SELECT Id FROM ' + objectName
            + ' WHERE (' + String.join(parentFilters, ' OR ') + ')'
            + ' AND CreatedDate >= :notBefore'
            + ' ORDER BY CreatedDate DESC LIMIT ' + lim;
          for (SObject row : Database.query(soql)) {
            ids.add((Id) row.get('Id'));
          }
          if (!ids.isEmpty()) {
            return ids;
          }
        } catch (Exception ignore) {
        }
      }
      // Separate fallback: DataJson contains promotion Id.
      if (dataField != null) {
        String promoLike = '%' + parentIdStr + '%';
        try {
          String soql =
            'SELECT Id FROM ' + objectName
            + ' WHERE ' + dataField + ' LIKE :promoLike'
            + ' AND CreatedDate >= :notBefore'
            + ' ORDER BY CreatedDate DESC LIMIT ' + lim;
          for (SObject row : Database.query(soql)) {
            ids.add((Id) row.get('Id'));
          }
          if (!ids.isEmpty()) {
            return ids;
          }
        } catch (Exception ignore) {
        }
      }
    }
    return ids;
  }

  /**
   * For Validate / Deploy-next: prefer Promotion Status over a single Job Execution.
   * Falls back to the JE status when no Promotion Id is available.
   */
  public static JobStatus resolveValidateOrDeployNextStatus(
    String jobExecutionId,
    Id promotionId,
    Boolean linkUsc
  ) {
    if (promotionId != null) {
      JobStatus promo = getPromotionPipelineStatus(promotionId);
      // Still running on Promotion — keep polling (do not celebrate Promote JE success).
      if (promo != null && promo.isComplete != true && promo.isFailed != true) {
        return promo;
      }
      if (promo != null && (promo.isFailed == true || promo.isComplete == true)) {
        return promo;
      }
    }
    return getJobExecutionStatus(jobExecutionId, linkUsc == true);
  }

  /**
   * Read Copado Job Execution status for Status panel refresh.
   * Does not link User Story Commit (use overload with linkUsc=true after Commit).
   */
  public static JobStatus getJobExecutionStatus(String jobId) {
    return getJobExecutionStatus(jobId, false);
  }

  /**
   * @param linkUsc when true and the job is a Commit (or combined) success, attempt
   *   Snapshot Commit / USC linking. Keep false for gates and session polls to avoid
   *   SOQL governor limits (Validate / getSessionState).
   */
  public static JobStatus getJobExecutionStatus(String jobId, Boolean linkUsc) {
    JobStatus result = new JobStatus();
    result.jobId = jobId;
    result.status = 'Unknown';
    result.isComplete = false;
    result.isFailed = false;
    if (String.isBlank(jobId) || isMockDevops() || CopadoAiApiService.isMockMode()) {
      if (String.isNotBlank(jobId)) {
        result.status = 'success';
        result.summary = 'Mock job complete.';
        result.isComplete = true;
      }
      return result;
    }
    // Placeholder ids are not Salesforce Job Executions — never treat as In progress.
    if (jobId.startsWith('validate-queued') || jobId.startsWith('deploy-next-queued')) {
      result.status = 'In Progress';
      result.summary = jobId.startsWith('deploy-next-queued')
        ? 'Deploy to next environment is starting (queued).'
        : 'Validate job is starting (queued).';
      return result;
    }
    if (jobId.startsWith('create-execution-pending')
      || jobId.startsWith('validate-manual')
      || jobId.startsWith('prepared-')
      || jobId.startsWith('webhook-')) {
      result.status = 'Failed';
      result.isFailed = true;
      result.isComplete = true;
      result.summary = jobId.startsWith('create-execution-pending')
        ? 'Validate did not start a Job Execution. Confirm Validate Promote/Deploy Job Template API names in Copado Builder Settings.'
        : 'Job was prepared locally; no live Job Execution to poll.';
      return result;
    }

    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      result.summary = 'Job Execution object not available.';
      return result;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'copado__Job_Status__c', 'Status'
    });
    String errorField = firstExisting(fields, new List<String>{
      'copado__ErrorMessage__c',
      'copado__Error_Message__c',
      'copado__Message__c'
    });
    List<String> selectFields = new List<String>{ 'Id', 'Name' };
    if (statusField != null) {
      selectFields.add(statusField);
    }
    if (errorField != null) {
      selectFields.add(errorField);
    }
    try {
      Id jid = (Id) jobId;
      List<SObject> rows = Database.query(
        'SELECT ' + String.join(selectFields, ',')
        + ' FROM ' + jobType.getDescribe().getName()
        + ' WHERE Id = :jid LIMIT 1'
      );
      if (rows.isEmpty()) {
        result.summary = 'Job Execution not found.';
        return result;
      }
      SObject row = rows[0];
      String statusVal = statusField != null && row.get(statusField) != null
        ? String.valueOf(row.get(statusField))
        : 'Unknown';
      result.status = statusVal;
      String err = errorField != null && row.get(errorField) != null
        ? String.valueOf(row.get(errorField))
        : null;
      result.errorMessage = err;
      String lower = statusVal.toLowerCase();
      result.isFailed = lower.contains('fail') || lower.contains('error') || lower.contains('cancel');
      // Some Copado runs stamp Error Message before Status flips to Error.
      if (!result.isFailed && String.isNotBlank(err)
        && (err.contains('Didn\'t understand relationship')
          || err.contains('Promotion__r')
          || err.toLowerCase().contains('exception'))) {
        result.isFailed = true;
      }
      result.isComplete =
        result.isFailed
        || lower.contains('success')
        || lower.contains('complete')
        || lower == 'done'
        || lower.contains('successful');
      if (result.isFailed) {
        result.summary = 'Job failed: ' + (String.isNotBlank(err) ? err : statusVal);
      } else if (lower.contains('not started') || lower == 'n/a' || lower == 'na') {
        result.summary = 'Job has not started yet. Open the Job Execution in Copado to start it.';
        result.isComplete = false;
      } else {
        result.summary = 'Job status: ' + statusVal;
      }
      // USC linking is expensive (many SOQL). Only after Commit refresh / schedulable.
      if (linkUsc == true
        && result.isComplete
        && !result.isFailed
        && jobExpectsGitCommit(jid)) {
        String linkMsg = ensureUserStoryCommitFromJob(jid);
        if (String.isNotBlank(linkMsg)) {
          Boolean linkDone =
            linkMsg.startsWith('Linked User Story Commit')
            || linkMsg.startsWith('User Story Commit already linked');
          result.summary = linkDone
            ? linkMsg
            : ((String.isNotBlank(result.summary) ? result.summary + ' — ' : '') + linkMsg);
        }
      }
    } catch (Exception ex) {
      result.summary = 'Could not read job status: ' + ex.getMessage();
    }
    return result;
  }

  /**
   * True when this Job Execution is expected to produce a Git commit / Snapshot Commit.
   * Deploy-only Builder jobs must not trigger USC linking (no SHA exists yet).
   */
  @TestVisible
  private static Boolean jobExpectsGitCommit(Id jobExecutionId) {
    if (jobExecutionId == null) {
      return false;
    }
    Map<String, Object> data = readJobExecutionDataJson(jobExecutionId);
    if (data == null || data.isEmpty()) {
      return false;
    }
    String action = data.get('action') != null
      ? String.valueOf(data.get('action')).trim().toLowerCase()
      : '';
    if (action == 'deployonly' || action == 'deploy' || action == 'validate') {
      return false;
    }
    if (action == 'commitonly' || action == 'commit'
      || action == 'deploythencommit' || action == 'deploy_then_commit') {
      return true;
    }
    if (data.get('userStoryCommitId') != null) {
      return true;
    }
    if (data.containsKey('recreateFeatureBranch') || data.containsKey('commitMessage')) {
      return String.isBlank(action) || !action.contains('deploy');
    }
    return false;
  }

  public static JobResult deployUserStory(Id userStoryId, String environmentId, String orgName) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for deploy.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      JobResult mock = mockJob('deploy', userStoryId, orgName);
      mock.summary = 'Successfully deployed story to ' + orgName + '.';
      return mock;
    }

    if (String.isBlank(environmentId)) {
      throw new CopadoAiApiService.ApiException(
        'Select a Dev environment in the Status panel. Copado Builder will add it to the user story before deploy.'
      );
    }

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.deployJobTemplate)
      ? settings.deployJobTemplate
      : 'builder_deploy_only';

    // Callouts before DML
    JobResult webhookJob = null;
    if (String.isNotBlank(settings.actionsWebhookPath)) {
      webhookJob = callActionsWebhook(
        settings.actionsWebhookPath,
        template,
        userStoryId,
        environmentId,
        'Deploy to ' + orgName,
        null,
        'deploy'
      );
    }

    assignEnvironmentToUserStory(userStoryId, environmentId);

    JobResult job = webhookJob;
    if (job == null) {
      job = tryCreateJobExecution(template, userStoryId, environmentId, 'Deploy to ' + orgName);
    }
    if (job == null) {
      job = new JobResult();
      job.jobId = 'prepared-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
      job.status = 'Prepared';
      job.method = 'metadata-prepare';
      job.summary = 'Deploy prepared for ' + orgName + '.';
    } else {
      job.summary = 'Deploy started for ' + orgName + '. Job ' + job.jobId + '.';
    }
    return job;
  }

  /**
   * Create Copado User Story Metadata rows for generated members when the object exists.
   * Never writes AutoNumber / non-createable Name (throws "Field Name is not editable").
   * Types are always SFDX registry names (Layout, Profile, CustomField) — never UI labels.
   */
  @TestVisible
  private static Integer upsertUserStoryMetadata(Id userStoryId, List<String> artifactPaths) {
    return upsertUserStoryMetadata(userStoryId, artifactPaths, null);
  }

  @TestVisible
  private static Integer upsertUserStoryMetadata(
    Id userStoryId,
    List<String> artifactPaths,
    String packageJson
  ) {
    List<Map<String, Object>> selections = new List<Map<String, Object>>();
    if (String.isNotBlank(packageJson)) {
      selections = buildCommitSelections(packageJson);
    }
    if (selections.isEmpty() && artifactPaths != null) {
      for (String path : artifactPaths) {
        if (String.isBlank(path)) {
          continue;
        }
        Map<String, String> parsed = parseMetadataFromPath(path);
        String member = parsed.get('member');
        String metaTypeName = toSfdxMetadataType(parsed.get('type'));
        if (String.isBlank(member) || String.isBlank(metaTypeName)) {
          continue;
        }
        selections.add(normalizeCommitSelection(new Map<String, Object>{
          't' => metaTypeName,
          'n' => member,
          'm' => '',
          'j' => '',
          'c' => 'SFDX',
          'a' => 'Add'
        }));
      }
    }
    if (selections.isEmpty()) {
      return 0;
    }
    Schema.SObjectType metaType = Schema.getGlobalDescribe().get('copado__User_Story_Metadata__c');
    if (metaType == null) {
      return 0;
    }
    Map<String, Schema.SObjectField> fields = metaType.getDescribe().fields.getMap();
    String usField = firstCreateable(fields, new List<String>{
      'copado__User_Story__c', 'User_Story__c'
    });
    String apiNameField = firstCreateable(fields, new List<String>{
      'copado__Metadata_API_Name__c', 'copado__Api_Name__c'
    });
    String typeField = firstCreateable(fields, new List<String>{
      'copado__Type__c', 'copado__Metadata_Type__c'
    });
    String uniqueField = firstCreateable(fields, new List<String>{
      'copado__Unique_ID__c', 'copado__UniqueId__c'
    });
    String actionField = firstCreateable(fields, new List<String>{
      'copado__Action__c'
    });
    String categoryField = firstCreateable(fields, new List<String>{
      'copado__Category__c'
    });
    String nameField = isFieldCreateable(fields, 'Name') ? 'Name' : null;

    if (usField == null || (apiNameField == null && nameField == null)) {
      return 0;
    }

    Set<String> selectionKeys = new Set<String>();

    if (apiNameField != null && typeField != null) {
      try {
        List<SObject> malformedRows = new List<SObject>();
        String existingSoql =
          'SELECT Id,' + apiNameField + ',' + typeField
          + ' FROM ' + metaType.getDescribe().getName()
          + ' WHERE ' + usField + ' = :userStoryId';
        for (SObject existing : Database.query(existingSoql)) {
          String existingMember = existing.get(apiNameField) != null
            ? String.valueOf(existing.get(apiNameField))
            : null;
          String existingType = existing.get(typeField) != null
            ? toSfdxMetadataType(String.valueOf(existing.get(typeField)))
            : null;
          if (String.isNotBlank(existingMember) && existingMember.startsWith('force-app/')) {
            malformedRows.add(existing);
          } else if (
            'Layout'.equals(existingType)
            && isInventedDefaultLayoutName(existingMember)
          ) {
            // Purge invented English defaults left by prior Builds.
            malformedRows.add(existing);
          } else if (String.isNotBlank(existingMember) && String.isNotBlank(existingType)) {
            selectionKeys.add(existingType + ':' + existingMember);
          }
        }
        if (!malformedRows.isEmpty()) {
          Database.delete(malformedRows, false);
        }
      } catch (Exception ignore) {
      }
    }

    for (Map<String, Object> sel : selections) {
      if (sel == null) {
        continue;
      }
      String member = sel.get('n') != null ? String.valueOf(sel.get('n')) : null;
      String metaTypeName = sel.get('t') != null
        ? toSfdxMetadataType(String.valueOf(sel.get('t')))
        : null;
      if (String.isBlank(member) || String.isBlank(metaTypeName)) {
        continue;
      }
      // Do not stamp invented English default layouts onto the User Story —
      // Commit retrieve fails with "Layout named 'Account-Account Layout' cannot be found".
      if ('Layout'.equals(metaTypeName) && isInventedDefaultLayoutName(member)) {
        continue;
      }
      String selectionKey = metaTypeName + ':' + member;
      if (selectionKeys.contains(selectionKey)) {
        continue;
      }

      Boolean ok = insertUserStoryMetadataRow(
        metaType, fields, usField, apiNameField, typeField, uniqueField,
        actionField, categoryField, nameField, userStoryId, member, metaTypeName, true
      );
      if (!ok) {
        ok = insertUserStoryMetadataRow(
          metaType, fields, usField, apiNameField, typeField, null,
          actionField, categoryField, nameField, userStoryId, member, metaTypeName, false
        );
      }
      if (ok) {
        selectionKeys.add(selectionKey);
      } else {
        System.debug(
          LoggingLevel.WARN,
          'US Metadata insert failed for ' + metaTypeName + ':' + member
        );
      }
      if (selectionKeys.size() >= 40) {
        break;
      }
    }
    return selectionKeys.size();
  }

  private static Boolean insertUserStoryMetadataRow(
    Schema.SObjectType metaType,
    Map<String, Schema.SObjectField> fields,
    String usField,
    String apiNameField,
    String typeField,
    String uniqueField,
    String actionField,
    String categoryField,
    String nameField,
    Id userStoryId,
    String member,
    String metaTypeName,
    Boolean includeUnique
  ) {
    try {
      SObject row = metaType.newSObject();
      row.put(usField, userStoryId);
      if (apiNameField != null) {
        row.put(apiNameField, truncate(member, 255));
      }
      if (nameField != null) {
        row.put(nameField, truncate(member, 80));
      }
      if (typeField != null) {
        row.put(typeField, truncate(metaTypeName, 255));
      }
      if (includeUnique && uniqueField != null) {
        row.put(uniqueField, truncate(metaTypeName + '_' + member, 255));
      }
      if (actionField != null) {
        row.put(actionField, 'Add');
      }
      if (categoryField != null) {
        row.put(categoryField, 'SFDX');
      }
      Database.SaveResult sr = Database.insert(row, false);
      return sr != null && sr.isSuccess();
    } catch (Exception ignore) {
      return false;
    }
  }

  /**
   * Resolve the Copado Environment record Id from a selected Dev target.
   * Builder picklists often pass an Org Credential Id; Dynamic Expressions
   * {$Source.Credential.*} / {$Context.Credential.*} need the Environment Id.
   */
  @TestVisible
  /**
   * Resolve Copado Environment Id from an Environment or Org Credential Id.
   */
  public static Id resolveEnvironmentRecordId(String environmentOrCredentialId) {
    if (String.isBlank(environmentOrCredentialId)) {
      return null;
    }
    Id rawId;
    try {
      rawId = (Id) environmentOrCredentialId;
    } catch (Exception ignore) {
      return null;
    }
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType != null && rawId.getSObjectType() == envType) {
      return rawId;
    }
    Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
    if (credType == null) {
      credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
    }
    if (credType != null && rawId.getSObjectType() == credType) {
      Map<String, Schema.SObjectField> fields = credType.getDescribe().fields.getMap();
      String envField = firstExisting(fields, new List<String>{ 'copado__Environment__c' });
      if (envField == null) {
        return null;
      }
      try {
        List<SObject> rows = Database.query(
          'SELECT ' + envField + ' FROM ' + credType.getDescribe().getName()
            + ' WHERE Id = :rawId LIMIT 1'
        );
        if (!rows.isEmpty() && rows[0].get(envField) != null) {
          return (Id) rows[0].get(envField);
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  /**
   * Look up the Org Credential username + Salesforce Org Id so the Function can
   * target the org explicitly (`--target-org <username>`). Copado usually leaves
   * the CLI authenticated but with no default org in custom functions.
   */
  private static Map<String, String> getOrgCredentialIdentity(String environmentId) {
    if (String.isBlank(environmentId)) {
      return null;
    }
    Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
    if (credType == null) {
      credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
    }
    if (credType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = credType.getDescribe().fields.getMap();
    String usernameField = firstExisting(fields, new List<String>{
      'copado__Username__c', 'copado__Oauth_Username__c', 'copado__OAuth_Username__c'
    });
    String orgIdField = firstExisting(fields, new List<String>{
      'copado__SFDC_Org_ID__c', 'copado__Org_ID__c', 'copado__OrgId__c'
    });
    String envField = firstExisting(fields, new List<String>{ 'copado__Environment__c' });
    List<String> selectFields = new List<String>{ 'Id' };
    if (usernameField != null) {
      selectFields.add(usernameField);
    }
    if (orgIdField != null) {
      selectFields.add(orgIdField);
    }
    if (usernameField == null && orgIdField == null) {
      return null;
    }
    Map<String, String> out = new Map<String, String>();
    try {
      // environmentId may be the Org Credential Id or the Environment Id.
      String soql = 'SELECT ' + String.join(selectFields, ',')
        + ' FROM ' + credType.getDescribe().getName()
        + ' WHERE Id = :environmentId';
      if (envField != null) {
        soql += ' OR ' + envField + ' = :environmentId';
      }
      soql += ' LIMIT 1';
      List<SObject> rows = Database.query(soql);
      if (rows.isEmpty()) {
        return null;
      }
      SObject row = rows[0];
      if (usernameField != null && row.get(usernameField) != null) {
        out.put('username', String.valueOf(row.get(usernameField)));
      }
      if (orgIdField != null && row.get(orgIdField) != null) {
        out.put('orgId', String.valueOf(row.get(orgIdField)));
      }
    } catch (Exception ignore) {
      return null;
    }
    return out;
  }

  @TestVisible
  private static List<String> extractArtifactPathsFromPackage(String packageJson) {
    List<String> paths = new List<String>();
    if (String.isBlank(packageJson)) {
      return paths;
    }
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
      if (parsed.get('files') instanceof List<Object>) {
        for (Object item : (List<Object>) parsed.get('files')) {
          if (item instanceof Map<String, Object>) {
            Object path = ((Map<String, Object>) item).get('path');
            if (path != null) {
              paths.add(String.valueOf(path));
            }
          }
        }
      }
    } catch (Exception ignore) {
    }
    return paths;
  }

  @TestVisible
  private static Map<String, String> parseMetadataFromPath(String path) {
    Map<String, String> out = new Map<String, String>();
    if (String.isBlank(path)) {
      return out;
    }
    String p = path.replace('\\', '/');
    String fileName = p.substring(p.lastIndexOf('/') + 1);

    // Supporting descriptor files are part of their primary component, not
    // separate selections in Copado.
    if (p.endsWith('.cls-meta.xml') || p.endsWith('.trigger-meta.xml')) {
      return out;
    }

    if (p.contains('/objects/') && p.endsWith('.field-meta.xml')) {
      // force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml
      out.put('type', 'CustomField');
      out.put('member', objectChildFullName(p, 'fields', '.field-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.validationRule-meta.xml')) {
      out.put('type', 'ValidationRule');
      out.put('member', objectChildFullName(p, 'validationRules', '.validationRule-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.recordType-meta.xml')) {
      out.put('type', 'RecordType');
      out.put('member', objectChildFullName(p, 'recordTypes', '.recordType-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.listView-meta.xml')) {
      out.put('type', 'ListView');
      out.put('member', objectChildFullName(p, 'listViews', '.listView-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.compactLayout-meta.xml')) {
      out.put('type', 'CompactLayout');
      out.put('member', objectChildFullName(p, 'compactLayouts', '.compactLayout-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.fieldSet-meta.xml')) {
      out.put('type', 'FieldSet');
      out.put('member', objectChildFullName(p, 'fieldSets', '.fieldSet-meta.xml'));
    } else if (p.contains('/objects/') && p.endsWith('.webLink-meta.xml')) {
      out.put('type', 'WebLink');
      out.put('member', objectChildFullName(p, 'webLinks', '.webLink-meta.xml'));
    } else if (p.contains('/objects/') && (p.endsWith('.object-meta.xml') || p.endsWith('.object'))) {
      out.put('type', 'CustomObject');
      if (fileName.endsWith('.object-meta.xml')) {
        out.put('member', fileName.replace('.object-meta.xml', ''));
      } else {
        out.put('member', fileName.replace('.object', ''));
      }
    } else if (p.contains('/layouts/')
      && (p.endsWith('.layout-meta.xml') || p.endsWith('.layout'))) {
      out.put('type', 'Layout');
      if (fileName.endsWith('.layout-meta.xml')) {
        out.put('member', fileName.replace('.layout-meta.xml', ''));
      } else {
        out.put('member', fileName.replace('.layout', ''));
      }
    } else if (p.contains('/profiles/')
      && (p.endsWith('.profile-meta.xml') || p.endsWith('.profile'))) {
      out.put('type', 'Profile');
      if (fileName.endsWith('.profile-meta.xml')) {
        out.put('member', fileName.replace('.profile-meta.xml', ''));
      } else {
        out.put('member', fileName.replace('.profile', ''));
      }
    } else if (p.contains('/permissionsets/')
      && (p.endsWith('.permissionset-meta.xml') || p.endsWith('.permissionset'))) {
      out.put('type', 'PermissionSet');
      if (fileName.endsWith('.permissionset-meta.xml')) {
        out.put('member', fileName.replace('.permissionset-meta.xml', ''));
      } else {
        out.put('member', fileName.replace('.permissionset', ''));
      }
    } else if (p.contains('/flows/') && p.endsWith('.flow-meta.xml')) {
      out.put('type', 'Flow');
      out.put('member', fileName.replace('.flow-meta.xml', ''));
    } else if (p.contains('/flexipages/') && p.endsWith('.flexipage-meta.xml')) {
      out.put('type', 'FlexiPage');
      out.put('member', fileName.replace('.flexipage-meta.xml', ''));
    } else if (p.contains('/applications/') && p.endsWith('.app-meta.xml')) {
      out.put('type', 'CustomApplication');
      out.put('member', fileName.replace('.app-meta.xml', ''));
    } else if (p.contains('/tabs/') && p.endsWith('.tab-meta.xml')) {
      out.put('type', 'CustomTab');
      out.put('member', fileName.replace('.tab-meta.xml', ''));
    } else if (p.contains('/remoteSiteSettings/') && p.endsWith('.remoteSite-meta.xml')) {
      out.put('type', 'RemoteSiteSetting');
      out.put('member', fileName.replace('.remoteSite-meta.xml', ''));
    } else if (p.contains('/customMetadata/') && p.endsWith('.md-meta.xml')) {
      out.put('type', 'CustomMetadata');
      out.put('member', fileName.replace('.md-meta.xml', ''));
    } else if (p.contains('/labels/') && p.endsWith('.labels-meta.xml')) {
      out.put('type', 'CustomLabels');
      out.put('member', fileName.replace('.labels-meta.xml', ''));
    } else if (p.contains('/staticresources/') && p.endsWith('.resource-meta.xml')) {
      out.put('type', 'StaticResource');
      out.put('member', fileName.replace('.resource-meta.xml', ''));
    } else if (p.contains('/classes/') && p.endsWith('.cls')) {
      out.put('type', 'ApexClass');
      out.put('member', fileName.replace('.cls', ''));
    } else if (p.contains('/lwc/')) {
      out.put('type', 'LightningComponentBundle');
      out.put('member', pathSegmentAfter(p, 'lwc'));
    } else if (p.contains('/aura/')) {
      out.put('type', 'AuraDefinitionBundle');
      out.put('member', pathSegmentAfter(p, 'aura'));
    } else if (p.contains('/triggers/') && p.endsWith('.trigger')) {
      out.put('type', 'ApexTrigger');
      out.put('member', fileName.replace('.trigger', ''));
    }
    return out;
  }

  private static String objectChildFullName(String path, String childDirectory, String suffix) {
    String objectName = pathSegmentAfter(path, 'objects');
    String childName = pathSegmentAfter(path, childDirectory);
    if (String.isNotBlank(childName) && childName.endsWith(suffix)) {
      childName = childName.substring(0, childName.length() - suffix.length());
    }
    if (String.isBlank(objectName) || String.isBlank(childName)) {
      return null;
    }
    return objectName + '.' + childName;
  }

  private static String pathSegmentAfter(String path, String directory) {
    List<String> parts = path.split('/');
    for (Integer i = 0; i < parts.size() - 1; i++) {
      if (parts[i] == directory) {
        return parts[i + 1];
      }
    }
    return null;
  }

  // ensureUserStoryEnvironment removed — callers must pass a selected environmentId
  // via assignEnvironmentToUserStory().

  /**
   * Official Copado entry point (see "Execute a Job Template from Apex").
   * Sets Context (parentId), Source Environment (sourceId), Pipeline, DataJson,
   * clones template steps, and optionally starts the run.
   * Do NOT leave optional string fields blank — omit them when unused.
   * On failure returns a JobResult with status=Failed and errorDetail set (never silent null
   * when the call was attempted).
   */
  @TestVisible
  private static JobResult tryCreateExecutionApi(
    String templateName,
    Id userStoryId,
    String environmentId,
    Map<String, Object> payload
  ) {
    if (userStoryId == null || String.isBlank(templateName) || payload == null) {
      JobResult bad = new JobResult();
      bad.method = 'CreateExecution';
      bad.status = 'Failed';
      bad.errorDetail = 'Missing parent Id, template name, or payload.';
      return bad;
    }
    // Hard dependency on Copado managed package. Missing package → fall back.
    Type createExecutionType = Type.forName('copado', 'CreateExecution');
    if (createExecutionType == null) {
      JobResult bad = new JobResult();
      bad.method = 'CreateExecution';
      bad.status = 'Failed';
      bad.errorDetail = 'copado.CreateExecution type not available in this org.';
      return bad;
    }

    String apiName = templateName.trim();
    // Settings usually store API names (e.g. sfdx_deploy_1). Resolving by Id/label
    // burns many SOQL queries — only resolve when the value looks like a record Id.
    if (looksLikeSalesforceId(apiName)) {
      apiName = resolveJobTemplateApiName(apiName);
    }
    if (String.isBlank(apiName)) {
      JobResult bad = new JobResult();
      bad.method = 'CreateExecution';
      bad.status = 'Failed';
      bad.errorDetail = 'Could not resolve Job Template API Name for "' + templateName + '".';
      return bad;
    }

    try {
      copado.CreateExecution.Request request = new copado.CreateExecution.Request();
      request.parentId = String.valueOf(userStoryId);
      request.templateName = apiName;
      request.runAfterInstantiation = true;

      // CreateExecution Request uses Environment Ids; OOTB DataJson uses Credential Ids.
      // Builder-only keys (_builder*) are stripped from the JE DataJson.
      Id sourceEnvId = null;
      if (payload.get('_builderSourceEnvironmentId') != null) {
        try {
          sourceEnvId = (Id) String.valueOf(payload.get('_builderSourceEnvironmentId'));
        } catch (Exception ignore) {
        }
      }
      if (sourceEnvId == null && payload.get('environmentRecordId') != null) {
        try {
          sourceEnvId = (Id) String.valueOf(payload.get('environmentRecordId'));
        } catch (Exception ignore) {
        }
      }
      if (sourceEnvId == null) {
        sourceEnvId = resolveEnvironmentRecordId(environmentId);
      }
      if (sourceEnvId != null) {
        request.sourceId = String.valueOf(sourceEnvId);
      }

      String pipelineForRequest = null;
      if (payload.get('_builderPipelineId') != null) {
        pipelineForRequest = String.valueOf(payload.get('_builderPipelineId'));
      } else if (payload.get('pipelineId') != null) {
        pipelineForRequest = String.valueOf(payload.get('pipelineId'));
      }
      if (String.isNotBlank(pipelineForRequest)) {
        request.pipelineId = pipelineForRequest;
      }

      String destForRequest = null;
      if (payload.get('_builderDestinationEnvironmentId') != null) {
        destForRequest = String.valueOf(payload.get('_builderDestinationEnvironmentId'));
      } else if (payload.get('destinationRecordId') != null) {
        destForRequest = String.valueOf(payload.get('destinationRecordId'));
      }
      if (String.isNotBlank(destForRequest)) {
        try {
          request.destinationId = destForRequest;
        } catch (Exception ignore) {
          // older Copado without destinationId
        }
      }

      request.dataJson = JSON.serialize(dataJsonForCreateExecution(payload));

      Datetime startedAt = Datetime.now().addSeconds(-5);
      copado.CreateExecution.execute(
        new List<copado.CreateExecution.Request>{ request }
      );

      Id jobId = findLatestJobExecutionForParent(userStoryId, startedAt);
      // Also try Promotion Id from payload when parent search by US misses.
      if (jobId == null && payload.get('promotionId') != null) {
        try {
          jobId = findLatestJobExecutionForParent(
            (Id) String.valueOf(payload.get('promotionId')),
            startedAt
          );
        } catch (Exception ignore) {
        }
      }
      if (jobId != null && payload.get('promotionId') != null) {
        try {
          stampJobExecutionPromotion(jobId, (Id) String.valueOf(payload.get('promotionId')));
        } catch (Exception ignore) {
        }
      }
      JobResult result = new JobResult();
      result.method = 'CreateExecution';
      result.parentIdUsed = String.valueOf(userStoryId);
      if (jobId != null) {
        result.jobId = String.valueOf(jobId);
        // JE may already be Failed (e.g. Promotion__r during step init) — do not
        // report In Progress so callers can retry another parent.
        JobStatus immediate = getJobExecutionStatus(String.valueOf(jobId), false);
        if (immediate != null && immediate.isFailed == true) {
          result.status = 'Failed';
          result.errorDetail = String.isNotBlank(immediate.errorMessage)
            ? immediate.errorMessage
            : immediate.summary;
          result.summary =
            'Job template '
            + apiName
            + ' failed immediately: '
            + (String.isNotBlank(result.errorDetail) ? result.errorDetail : immediate.status);
          return result;
        }
        result.status = 'In Progress';
        result.summary = 'Started job template ' + apiName + '.';
      } else {
        // CreateExecution accepted the call but no JE appeared — not In progress.
        result.jobId = 'create-execution-pending';
        result.status = 'Failed';
        result.summary =
          'Job template '
          + apiName
          + ' did not create a Job Execution. Check the template API name and Promotion.';
        result.errorDetail =
          'CreateExecution accepted template '
          + apiName
          + ' but no Job Execution was found for parent '
          + userStoryId
          + ' within a few seconds.';
      }
      return result;
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'copado.CreateExecution failed: ' + ex.getMessage()
      );
      JobResult fail = new JobResult();
      fail.method = 'CreateExecution';
      fail.status = 'Failed';
      fail.parentIdUsed = String.valueOf(userStoryId);
      fail.errorDetail = ex.getMessage();
      String msg = ex.getMessage();
      if (String.isNotBlank(msg) && msg.contains('Promotion__r')) {
        fail.summary =
          'CreateExecution failed: Job Template / Function referenced Promotion__r '
          + '(use copado__Promotion__r). Template: '
          + apiName
          + '.';
      } else {
        fail.summary = 'CreateExecution failed for ' + apiName + ': ' + msg;
      }
      return fail;
    }
  }

  /**
   * JE DataJson for CreateExecution — OOTB shape only (no Builder wiring keys,
   * no environmentRecordId / destinationRecordId).
   */
  @TestVisible
  private static Map<String, Object> dataJsonForCreateExecution(Map<String, Object> payload) {
    Map<String, Object> clean = new Map<String, Object>();
    if (payload == null) {
      return clean;
    }
    for (String key : payload.keySet()) {
      if (String.isBlank(key) || key.startsWith('_builder')) {
        continue;
      }
      if (key.equals('environmentRecordId')
        || key.equals('destinationRecordId')
        || key.equals('pipelineId')) {
        // Pipeline goes on CreateExecution.Request; env Ids are not OOTB DataJson.
        continue;
      }
      clean.put(key, payload.get(key));
    }
    return clean;
  }

  /** Link Job Execution → Promotion when CreateExecution parent was the User Story. */
  private static void stampJobExecutionPromotion(Id jobExecutionId, Id promotionId) {
    if (jobExecutionId == null || promotionId == null) {
      return;
    }
    Schema.SObjectType jobType = jobExecutionId.getSObjectType();
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    String promoField = null;
    for (String candidate : new List<String>{ 'copado__Promotion__c', 'copado__PromotionId__c' }) {
      if (!fields.containsKey(candidate)) {
        continue;
      }
      Schema.DescribeFieldResult d = fields.get(candidate).getDescribe();
      if (d.isUpdateable() && d.getType() == Schema.DisplayType.REFERENCE) {
        promoField = candidate;
        break;
      }
    }
    if (promoField == null) {
      return;
    }
    try {
      SObject upd = jobType.newSObject(jobExecutionId);
      upd.put(promoField, promotionId);
      update upd;
    } catch (Exception ignore) {
    }
  }

  /**
   * CreateExecution expects the Job Template API Name (not Salesforce Id / label).
   */
  @TestVisible
  private static String resolveJobTemplateApiName(String templateNameOrId) {
    if (String.isBlank(templateNameOrId)) {
      return null;
    }
    Id templateId = resolveJobTemplateId(templateNameOrId);
    if (templateId == null) {
      // May already be an API name that resolve couldn't map by Id — pass through.
      return templateNameOrId.trim().replace(' ', '_');
    }
    for (String objectName : new List<String>{
      'copado__JobTemplate__c', 'copado__Job_Template__c'
    }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      String apiField = firstExisting(fields, new List<String>{
        'copado__ApiName__c', 'copado__API_Name__c', 'DeveloperName'
      });
      try {
        String soql = 'SELECT Id';
        if (apiField != null) {
          soql += ',' + apiField;
        }
        soql += ', Name FROM ' + objectName + ' WHERE Id = :templateId LIMIT 1';
        List<SObject> rows = Database.query(soql);
        if (rows.isEmpty()) {
          continue;
        }
        SObject row = rows[0];
        if (apiField != null && row.get(apiField) != null
          && String.isNotBlank(String.valueOf(row.get(apiField)))) {
          return String.valueOf(row.get(apiField));
        }
        if (row.get('Name') != null) {
          return String.valueOf(row.get('Name')).replace(' ', '_');
        }
      } catch (Exception ignore) {
      }
    }
    return templateNameOrId.trim().replace(' ', '_');
  }

  /** Public helper for session heal — latest JE linked to a Promotion. */
  public static Id findLatestJobExecutionForPromotion(Id promotionId, Datetime notBefore) {
    return findLatestJobExecutionForParent(promotionId, notBefore);
  }

  private static Id findLatestJobExecutionForParent(Id parentId, Datetime notBefore) {
    if (parentId == null) {
      return null;
    }
    for (String objectName : new List<String>{
      'copado__JobExecution__c', 'copado__Job_Execution__c'
    }) {
      Schema.SObjectType jobType = Schema.getGlobalDescribe().get(objectName);
      if (jobType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
      List<String> parentFilters = new List<String>();
      String parentRecordId = firstExisting(fields, new List<String>{
        'copado__ParentRecord_Id__c', 'copado__ParentRecordId__c', 'copado__Parent_Id__c'
      });
      String parentIdField = firstExisting(fields, new List<String>{
        'copado__ParentId__c'
      });
      String usField = firstExisting(fields, new List<String>{
        'copado__UserStory__c', 'copado__User_Story__c'
      });
      String uscField = firstExisting(fields, new List<String>{
        'copado__UserStoryCommit__c', 'copado__User_Story_Commit__c'
      });
      String promoField = firstExisting(fields, new List<String>{
        'copado__Promotion__c', 'copado__PromotionId__c'
      });
      if (parentRecordId != null) {
        parentFilters.add(parentRecordId + ' = :parentIdStr');
      }
      if (parentIdField != null) {
        parentFilters.add(parentIdField + ' = :parentId');
      }
      if (usField != null) {
        parentFilters.add(usField + ' = :parentId');
      }
      if (uscField != null) {
        parentFilters.add(uscField + ' = :parentId');
      }
      if (promoField != null) {
        parentFilters.add(promoField + ' = :parentId');
      }
      if (parentFilters.isEmpty()) {
        continue;
      }
      String parentIdStr = String.valueOf(parentId);
      try {
        String soql =
          'SELECT Id FROM ' + objectName
          + ' WHERE (' + String.join(parentFilters, ' OR ') + ')'
          + ' AND CreatedDate >= :notBefore'
          + ' ORDER BY CreatedDate DESC LIMIT 1';
        List<SObject> rows = Database.query(soql);
        if (!rows.isEmpty()) {
          return (Id) rows[0].get('Id');
        }
      } catch (Exception ignore) {
      }
    }
    return null;
  }

  private static JobResult tryCreateJobExecution(
    String templateName,
    Id userStoryId,
    String environmentId,
    String message
  ) {
    return tryCreateJobExecution(templateName, userStoryId, environmentId, message, null);
  }

  private static JobResult tryCreateJobExecution(
    String templateName,
    Id userStoryId,
    String environmentId,
    String message,
    Map<String, Object> dataPayload
  ) {
    Schema.SObjectType jobType = Schema.getGlobalDescribe().get('copado__JobExecution__c');
    if (jobType == null) {
      jobType = Schema.getGlobalDescribe().get('copado__Job_Execution__c');
    }
    if (jobType == null) {
      return null;
    }
    Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
    SObject job = jobType.newSObject();

    Id templateId = resolveJobTemplateId(templateName);
    if (templateId == null) {
      return null;
    }
    String templateField = firstExisting(fields, new List<String>{
      'copado__JobTemplate__c', 'copado__Job_Template__c', 'copado__Template__c'
    });
    String nameField = firstCreateable(fields, new List<String>{ 'Name', 'copado__Name__c' });
    String usField = firstCreateable(fields, new List<String>{
      'copado__UserStory__c', 'copado__User_Story__c'
    });
    // Copado Context UI reads ParentRecord_Id (text) — not ParentId alone.
    List<String> parentFieldCandidates = new List<String>{
      'copado__ParentRecord_Id__c',
      'copado__ParentRecordId__c',
      'copado__ParentId__c',
      'copado__Parent_Id__c',
      'copado__ContextId__c',
      'copado__Context_Id__c'
    };
    String statusField = firstCreateable(fields, new List<String>{
      'copado__Status__c', 'copado__Job_Status__c'
    });
    String dataField = firstCreateable(fields, new List<String>{
      'copado__DataJson__c', 'copado__DataJSON__c', 'copado__VolumeOptions__c'
    });

    Map<String, Object> payload = dataPayload != null
      ? dataPayload
      : new Map<String, Object>{
          'userStoryId' => String.valueOf(userStoryId),
          'environmentId' => environmentId,
          'message' => message,
          'source' => 'CopadoBuilder'
        };

    if (templateField != null) {
      job.put(templateField, templateId);
    }
    if (nameField != null) {
      String n = 'Builder ' + templateName + ' ' + Datetime.now().format('yyyy-MM-dd HH:mm');
      job.put(nameField, truncate(n, 80));
    }
    // parentId may be User Story Commit (preferred) or User Story.
    Id contextUserStoryId = userStoryId;
    if (payload.containsKey('userStoryId') && payload.get('userStoryId') != null) {
      try {
        contextUserStoryId = (Id) String.valueOf(payload.get('userStoryId'));
      } catch (Exception ignore) {
      }
    }
    Id userStoryCommitId = null;
    if (payload.containsKey('userStoryCommitId') && payload.get('userStoryCommitId') != null) {
      try {
        userStoryCommitId = (Id) String.valueOf(payload.get('userStoryCommitId'));
      } catch (Exception ignore) {
      }
    }
    if (userStoryCommitId == null
      && userStoryId != null
      && String.valueOf(userStoryId.getSObjectType()).contains('User_Story_Commit')) {
      userStoryCommitId = userStoryId;
    }

    if (usField != null && contextUserStoryId != null) {
      job.put(usField, contextUserStoryId);
    }
    String uscField = firstCreateable(fields, new List<String>{
      'copado__UserStoryCommit__c', 'copado__User_Story_Commit__c'
    });
    if (uscField != null && userStoryCommitId != null) {
      job.put(uscField, userStoryCommitId);
    }
    // Stamp every createable parent/context field so Context is not blank on the JE.
    for (String parentField : parentFieldCandidates) {
      if (!fields.containsKey(parentField) || !fields.get(parentField).getDescribe().isCreateable()) {
        continue;
      }
      try {
        Schema.DisplayType dt = fields.get(parentField).getDescribe().getType();
        if (dt == Schema.DisplayType.STRING || dt == Schema.DisplayType.TEXTAREA
          || dt == Schema.DisplayType.ID) {
          job.put(parentField, String.valueOf(userStoryId));
        } else {
          job.put(parentField, userStoryId);
        }
      } catch (Exception ignore) {
        try {
          job.put(parentField, String.valueOf(userStoryId));
        } catch (Exception ignore2) {
        }
      }
    }

    // Ad-hoc Builder jobs are not commit/promote/deploy Actions, so Copado never
    // fills Source/Destination. Without those, {$Source.Credential.*} resolves to
    // "environment: null". Populate them from the selected Dev org.
    Id envRecordId = resolveEnvironmentRecordId(environmentId);
    if (envRecordId == null && userStoryId != null) {
      try {
        Schema.SObjectType usType = userStoryId.getSObjectType();
        Map<String, Schema.SObjectField> usFields = usType.getDescribe().fields.getMap();
        String usEnvField = firstExisting(usFields, new List<String>{
          'copado__Environment__c', 'copado__Org_Credential__c', 'copado__Org__c'
        });
        if (usEnvField != null) {
          List<SObject> usRows = Database.query(
            'SELECT ' + usEnvField + ' FROM ' + usType.getDescribe().getName()
              + ' WHERE Id = :userStoryId LIMIT 1'
          );
          if (!usRows.isEmpty() && usRows[0].get(usEnvField) != null) {
            envRecordId = resolveEnvironmentRecordId(String.valueOf(usRows[0].get(usEnvField)));
            if (envRecordId == null) {
              Id related = (Id) usRows[0].get(usEnvField);
              Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
              if (envType != null && related.getSObjectType() == envType) {
                envRecordId = related;
              }
            }
          }
        }
      } catch (Exception ignore) {
      }
    }
    if (envRecordId != null) {
      String sourceEnvField = firstCreateable(fields, new List<String>{
        'copado__Source_Environment__c',
        'copado__SourceEnv__c',
        'copado__Source_Env__c'
      });
      String destEnvField = firstCreateable(fields, new List<String>{
        'copado__Destination_Environment__c',
        'copado__DestinationEnv__c',
        'copado__Destination_Env__c'
      });
      if (sourceEnvField != null) {
        job.put(sourceEnvField, envRecordId);
      }
      if (destEnvField != null) {
        // Deploy-then-commit targets Dev; destination for the function = same env.
        job.put(destEnvField, envRecordId);
      }
      payload.put('environmentRecordId', String.valueOf(envRecordId));
    }
    // Also stamp Org Credential lookups when the picker passed a credential Id.
    Id credRecordId = null;
    try {
      Id maybeCred = (Id) environmentId;
      Schema.SObjectType credType = Schema.getGlobalDescribe().get('copado__Org__c');
      if (credType == null) {
        credType = Schema.getGlobalDescribe().get('copado__Org_Credential__c');
      }
      if (credType != null && maybeCred.getSObjectType() == credType) {
        credRecordId = maybeCred;
      }
    } catch (Exception ignore) {
    }
    if (credRecordId != null) {
      String sourceCredField = firstCreateable(fields, new List<String>{
        'copado__Source_Org_Credential__c',
        'copado__SourceOrgCredential__c',
        'copado__Org_Credential__c',
        'copado__Org__c'
      });
      String destCredField = firstCreateable(fields, new List<String>{
        'copado__Destination_Org_Credential__c',
        'copado__DestinationOrgCredential__c'
      });
      if (sourceCredField != null) {
        job.put(sourceCredField, credRecordId);
      }
      if (destCredField != null) {
        job.put(destCredField, credRecordId);
      }
    }

    // Commit step uses {$Pipeline.*}; stamp Pipeline from the User Story's project.
    if (payload.containsKey('pipelineId') && payload.get('pipelineId') != null) {
      try {
        Id pipelineId = (Id) String.valueOf(payload.get('pipelineId'));
        String pipelineField = firstCreateable(fields, new List<String>{
          'copado__Pipeline__c',
          'copado__Deployment_Flow__c',
          'copado__DeploymentFlow__c'
        });
        if (pipelineField != null) {
          job.put(pipelineField, pipelineId);
        }
      } catch (Exception ignore) {
      }
    }

    if (statusField != null) {
      // Leave Not Started; Copado starts the run via Callable / Execute action / webhook.
      job.put(statusField, 'Not Started');
    }
    if (dataField != null) {
      job.put(dataField, JSON.serialize(payload));
    }

    try {
      insert job;
      Id jobId = (Id) job.get('Id');

      // Raw Apex insert often leaves JE with 0 steps (Copado's UI "is Empty").
      // Clone template steps onto the execution before any status nudge/start.
      Integer stepCount = countJobExecutionSteps(jobId);
      if (stepCount == 0) {
        stepCount = cloneJobStepsFromTemplate(templateId, jobId);
      }
      if (stepCount == 0) {
        JobResult empty = new JobResult();
        empty.jobId = String.valueOf(jobId);
        empty.status = 'Not Started';
        empty.method = 'JobExecution';
        empty.summary =
          'Created Job Execution '
          + empty.jobId
          + ' but template '
          + templateName
          + ' ('
          + templateId
          + ') has no clonable Job Steps. Open that Job Template Id, confirm Steps (2), then retry. '
          + 'Do not use an empty duplicate template.';
        return empty;
      }

      Boolean started = tryStartJobExecution(
        jobId,
        templateName,
        templateId,
        userStoryId,
        JSON.serialize(payload)
      );

      JobResult result = new JobResult();
      result.jobId = String.valueOf(jobId);
      result.status = started ? 'In Progress' : 'Not Started';
      result.method = 'JobExecution';
      result.summary = started
        ? ('Started Copado Job Execution '
          + result.jobId
          + ' with '
          + stepCount
          + ' step(s). Template Id '
          + templateId
          + '.')
        : ('Created Copado Job Execution '
          + result.jobId
          + ' with '
          + stepCount
          + ' step(s) (Not Started). Open it and click Execute/Start.');
      return result;
    } catch (Exception ex) {
      return null;
    }
  }

  private static Integer countJobExecutionSteps(Id jobExecutionId) {
    if (jobExecutionId == null) {
      return 0;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(objectName);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = stepType.getDescribe().fields.getMap();
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c'
      });
      if (jeField == null) {
        continue;
      }
      try {
        Integer cnt = Database.countQuery(
          'SELECT COUNT() FROM ' + objectName + ' WHERE ' + jeField + ' = :jobExecutionId'
        );
        return cnt;
      } catch (Exception ignore) {
      }
    }
    return 0;
  }

  /**
   * Copy Job Template steps onto a Job Execution. Needed when Apex insert does not
   * trigger Copado's normal step-instantiation path.
   */
  @TestVisible
  private static Integer cloneJobStepsFromTemplate(Id templateId, Id jobExecutionId) {
    if (templateId == null || jobExecutionId == null) {
      return 0;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(objectName);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = stepType.getDescribe().fields.getMap();
      String templateField = firstExisting(fields, new List<String>{
        'copado__JobTemplate__c', 'copado__Job_Template__c'
      });
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c'
      });
      if (templateField == null || jeField == null) {
        continue;
      }

      List<String> selectFields = new List<String>{ 'Id' };
      for (String fieldName : fields.keySet()) {
        Schema.DescribeFieldResult d = fields.get(fieldName).getDescribe();
        if (d.isCreateable() && !d.isUnique() && !d.isAutoNumber()
          && fieldName != 'Id' && fieldName != 'OwnerId') {
          selectFields.add(fieldName);
        }
      }
      try {
        String soql =
          'SELECT ' + String.join(selectFields, ',')
          + ' FROM ' + objectName
          + ' WHERE ' + templateField + ' = :templateId'
          + ' AND ' + jeField + ' = null'
          + ' ORDER BY CreatedDate ASC LIMIT 40';
        List<SObject> templateSteps = Database.query(soql);
        if (templateSteps.isEmpty()) {
          // Some orgs keep template steps with a blank execution differently.
          soql =
            'SELECT ' + String.join(selectFields, ',')
            + ' FROM ' + objectName
            + ' WHERE ' + templateField + ' = :templateId'
            + ' LIMIT 40';
          List<SObject> allSteps = Database.query(soql);
          templateSteps = new List<SObject>();
          for (SObject row : allSteps) {
            if (row.get(jeField) == null) {
              templateSteps.add(row);
            }
          }
        }
        if (templateSteps.isEmpty()) {
          continue;
        }

        List<SObject> clones = new List<SObject>();
        for (SObject src : templateSteps) {
          SObject cloneRow = stepType.newSObject();
          for (String fieldName : selectFields) {
            if (fieldName == 'Id') {
              continue;
            }
            if (fieldName == jeField) {
              cloneRow.put(jeField, jobExecutionId);
              continue;
            }
            // Keep template lookup so the step remains associated.
            if (src.get(fieldName) != null) {
              cloneRow.put(fieldName, src.get(fieldName));
            }
          }
          if (cloneRow.get(jeField) == null) {
            cloneRow.put(jeField, jobExecutionId);
          }
          clones.add(cloneRow);
        }
        if (clones.isEmpty()) {
          continue;
        }
        Database.SaveResult[] results = Database.insert(clones, false);
        Integer ok = 0;
        for (Database.SaveResult sr : results) {
          if (sr.isSuccess()) {
            ok++;
          }
        }
        if (ok > 0) {
          return ok;
        }
      } catch (Exception ignore) {
      }
    }
    return 0;
  }

  /**
   * Copado does not run Job Executions on insert alone. Try managed-package
   * Callable entry points, then a status nudge. Returns true if a start attempt
   * appears to have been accepted.
   */
  private static Boolean tryStartJobExecution(
    Id jobId,
    String templateName,
    Id templateId,
    Id userStoryId,
    String dataJson
  ) {
    if (jobId == null) {
      return false;
    }

    Map<String, Object> args = new Map<String, Object>{
      'jobExecutionId' => jobId,
      'recordId' => jobId,
      'jobTemplateId' => templateId,
      'jobTemplateName' => templateName,
      'templateName' => templateName,
      'parentId' => userStoryId,
      'userStoryId' => userStoryId,
      'dataJson' => dataJson,
      'runAfterInstantiation' => true
    };

    List<String> classNames = new List<String>{
      'copado.RunJobTemplate',
      'copado.JobExecutionService',
      'copado.JobTemplateService',
      'copado.Jobs',
      'copado.CreateExecution',
      'copado.ExecuteJobTemplate'
    };
    List<String> actions = new List<String>{
      'execute', 'run', 'start', 'runJobTemplate', 'createAndRun', 'call'
    };

    for (String className : classNames) {
      Type t = Type.forName(className);
      if (t == null) {
        // Namespace.Class form already included; also try without package prefix parsing
        continue;
      }
      Object instance;
      try {
        instance = t.newInstance();
      } catch (Exception ignore) {
        continue;
      }
      if (!(instance instanceof System.Callable)) {
        continue;
      }
      for (String action : actions) {
        try {
          ((System.Callable) instance).call(action, args);
          return true;
        } catch (Exception ignore) {
        }
      }
    }

    // Last resort: nudge status (some orgs use automation on status change).
    try {
      Schema.SObjectType jobType = jobId.getSObjectType();
      Map<String, Schema.SObjectField> fields = jobType.getDescribe().fields.getMap();
      String statusField = firstCreateable(fields, new List<String>{
        'copado__Status__c', 'copado__Job_Status__c'
      });
      if (statusField != null) {
        for (String candidate : new List<String>{ 'In Progress', 'Queued' }) {
          try {
            SObject upd = jobType.newSObject(jobId);
            upd.put(statusField, candidate);
            update upd;
            return true;
          } catch (Exception ignore) {
          }
        }
      }
    } catch (Exception ignore) {
    }
    return false;
  }

  @TestVisible
  private static Id storePackageContent(Id userStoryId, String packageJson) {
    if (String.isBlank(packageJson)) {
      return null;
    }
    ContentVersion cv = new ContentVersion();
    cv.Title = 'CopadoBuilder-Package-' + String.valueOf(userStoryId).left(15);
    cv.PathOnClient = cv.Title + '.json';
    cv.VersionData = Blob.valueOf(
      packageJson.length() > 4 * 1024 * 1024
        ? packageJson.substring(0, 4 * 1024 * 1024)
        : packageJson
    );
    insert cv;
    ContentVersion created = [
      SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1
    ];
    linkContentToUserStory(created.ContentDocumentId, userStoryId);
    return created.ContentDocumentId;
  }

  private static void linkContentToUserStory(Id contentDocumentId, Id userStoryId) {
    if (contentDocumentId == null || userStoryId == null) {
      return;
    }
    try {
      List<ContentDocumentLink> existing = [
        SELECT Id
        FROM ContentDocumentLink
        WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :userStoryId
        LIMIT 1
      ];
      if (existing.isEmpty()) {
        insert new ContentDocumentLink(
          ContentDocumentId = contentDocumentId,
          LinkedEntityId = userStoryId,
          ShareType = 'V',
          Visibility = 'AllUsers'
        );
      }
    } catch (Exception ignore) {
    }
  }

  private static Id resolveJobTemplateId(String templateName) {
    if (String.isBlank(templateName)) {
      return null;
    }
    // Already an Id?
    try {
      if ((templateName.length() == 15 || templateName.length() == 18)
        && Pattern.compile('^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$').matcher(templateName).matches()) {
        return (Id) templateName;
      }
    } catch (Exception ignore) {
    }

    Set<String> candidates = new Set<String>{ templateName.trim() };
    candidates.add(templateName.trim().replace(' ', '_'));
    candidates.add(templateName.trim().replace('_', ' '));

    List<Id> matches = new List<Id>();
    for (String objectName : new List<String>{
      'copado__JobTemplate__c', 'copado__Job_Template__c'
    }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = t.getDescribe().fields.getMap();
      for (String candidate : candidates) {
        for (Id found : queryJobTemplateIds(objectName, fields, candidate)) {
          if (!matches.contains(found)) {
            matches.add(found);
          }
        }
      }
    }
    if (matches.isEmpty()) {
      return null;
    }
    // Prefer a template that already has Job Steps (avoid empty duplicate names).
    for (Id candidateId : matches) {
      if (countTemplateJobSteps(candidateId) > 0) {
        return candidateId;
      }
    }
    return matches[0];
  }

  private static Integer countTemplateJobSteps(Id templateId) {
    if (templateId == null) {
      return 0;
    }
    for (String objectName : new List<String>{ 'copado__JobStep__c', 'copado__Job_Step__c' }) {
      Schema.SObjectType stepType = Schema.getGlobalDescribe().get(objectName);
      if (stepType == null) {
        continue;
      }
      Map<String, Schema.SObjectField> fields = stepType.getDescribe().fields.getMap();
      String templateField = firstExisting(fields, new List<String>{
        'copado__JobTemplate__c', 'copado__Job_Template__c'
      });
      String jeField = firstExisting(fields, new List<String>{
        'copado__JobExecution__c', 'copado__Job_Execution__c'
      });
      if (templateField == null) {
        continue;
      }
      try {
        String soql = 'SELECT COUNT() FROM ' + objectName
          + ' WHERE ' + templateField + ' = :templateId';
        if (jeField != null) {
          soql += ' AND ' + jeField + ' = null';
        }
        return Database.countQuery(soql);
      } catch (Exception ignore) {
      }
    }
    return 0;
  }

  private static List<Id> queryJobTemplateIds(
    String objectName,
    Map<String, Schema.SObjectField> fields,
    String candidate
  ) {
    List<Id> ids = new List<Id>();
    List<String> whereParts = new List<String>();
    if (fields.containsKey('Name')) {
      whereParts.add('Name = :candidate');
    }
    if (fields.containsKey('DeveloperName')) {
      whereParts.add('DeveloperName = :candidate');
    }
    if (fields.containsKey('copado__ApiName__c')) {
      whereParts.add('copado__ApiName__c = :candidate');
    }
    if (fields.containsKey('copado__API_Name__c')) {
      whereParts.add('copado__API_Name__c = :candidate');
    }
    if (whereParts.isEmpty()) {
      return ids;
    }
    try {
      List<SObject> rows = Database.query(
        'SELECT Id FROM ' + objectName
        + ' WHERE (' + String.join(whereParts, ' OR ') + ') LIMIT 10'
      );
      for (SObject row : rows) {
        ids.add((Id) row.get('Id'));
      }
    } catch (Exception ignore) {
      try {
        List<SObject> rows = Database.query(
          'SELECT Id FROM ' + objectName + ' WHERE Name = :candidate LIMIT 10'
        );
        for (SObject row : rows) {
          ids.add((Id) row.get('Id'));
        }
      } catch (Exception ignore2) {
      }
    }
    return ids;
  }

  private static JobResult callActionsWebhook(
    String path,
    String templateName,
    Id userStoryId,
    String environmentId,
    String message,
    String packageJson,
    String actionKind
  ) {
    Map<String, Object> body = new Map<String, Object>{
      'templateName' => templateName,
      'userStoryId' => String.valueOf(userStoryId),
      'environmentId' => environmentId,
      'message' => message,
      'action' => actionKind,
      'source' => 'CopadoBuilder'
    };
    if (String.isNotBlank(packageJson) && packageJson.length() < 90000) {
      body.put('packageJson', packageJson);
    }

    HttpRequest req = new HttpRequest();
    // Same-org REST via session: path may be full URL or relative apexrest
    if (path.startsWith('http')) {
      req.setEndpoint(path);
    } else if (path.startsWith('/')) {
      req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + path);
    } else {
      req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/' + path);
    }
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
    req.setTimeout(120000);
    req.setBody(JSON.serialize(body));

    HttpResponse res = new Http().send(req);
    Integer code = res.getStatusCode();
    if (code < 200 || code >= 300) {
      throw new CopadoAiApiService.ApiException(
        'Copado Actions call failed (' + code + '): ' + truncate(res.getBody(), 500)
      );
    }

    JobResult result = new JobResult();
    result.method = 'ActionsWebhook';
    result.status = 'Queued';
    result.jobId = extractJobId(res.getBody());
    if (String.isBlank(result.jobId)) {
      result.jobId = 'webhook-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    }
    result.summary = 'Triggered Copado job template ' + templateName;
    return result;
  }

  private static String extractJobId(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> m = (Map<String, Object>) parsed;
        for (String key : new List<String>{ 'jobId', 'id', 'jobExecutionId', 'executionId' }) {
          if (m.containsKey(key) && m.get(key) != null) {
            return String.valueOf(m.get(key));
          }
        }
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static JobResult mockJob(String kind, Id userStoryId, String detail) {
    JobResult result = new JobResult();
    result.jobId = 'mock-' + kind + '-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.status = 'success';
    result.method = 'mock';
    result.summary = 'Mock ' + kind + ' for story ' + userStoryId
      + (String.isNotBlank(detail) ? ' (' + detail + ')' : '');
    return result;
  }

  private static String firstExisting(Map<String, Schema.SObjectField> fields, List<String> candidates) {
    for (String c : candidates) {
      if (fields.containsKey(c)) {
        return c;
      }
    }
    // Case-insensitive fallback
    Map<String, String> lower = new Map<String, String>();
    for (String k : fields.keySet()) {
      lower.put(k.toLowerCase(), k);
    }
    for (String c : candidates) {
      if (lower.containsKey(c.toLowerCase())) {
        return lower.get(c.toLowerCase());
      }
    }
    return null;
  }

  private static String firstCreateable(Map<String, Schema.SObjectField> fields, List<String> candidates) {
    for (String c : candidates) {
      if (isFieldCreateable(fields, c)) {
        return resolveFieldName(fields, c);
      }
    }
    return null;
  }

  private static Boolean isFieldCreateable(Map<String, Schema.SObjectField> fields, String apiName) {
    String resolved = resolveFieldName(fields, apiName);
    if (resolved == null) {
      return false;
    }
    try {
      return fields.get(resolved).getDescribe().isCreateable();
    } catch (Exception ignore) {
      return false;
    }
  }

  private static String resolveFieldName(Map<String, Schema.SObjectField> fields, String apiName) {
    if (String.isBlank(apiName)) {
      return null;
    }
    if (fields.containsKey(apiName)) {
      return apiName;
    }
    for (String k : fields.keySet()) {
      if (k != null && k.equalsIgnoreCase(apiName)) {
        return k;
      }
    }
    return null;
  }

  private static String truncate(String value, Integer maxLen) {
    if (String.isBlank(value) || value.length() <= maxLen) {
      return value;
    }
    return value.substring(0, maxLen);
  }
}
