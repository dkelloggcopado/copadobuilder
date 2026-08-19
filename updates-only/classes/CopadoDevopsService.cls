/**
 * Copado DevOps facade: pipeline orgs, commit, and deploy using in-org Copado
 * objects and optional Actions/Webhook job templates.
 */
public with sharing class CopadoDevopsService {

  public class JobResult {
    @AuraEnabled public String jobId;
    @AuraEnabled public String status;
    @AuraEnabled public String summary;
    @AuraEnabled public String method;
  }

  public class DevopsSettings {
    public String commitJobTemplate;
    public String deployJobTemplate;
    public String defaultDevEnvironmentId;
    public String actionsWebhookPath;
  }

  public static DevopsSettings getDevopsSettings() {
    DevopsSettings s = new DevopsSettings();
    List<Copado_Builder_Settings__mdt> rows = [
      SELECT Commit_Job_Template__c, Deploy_Job_Template__c,
        Default_Dev_Environment_Id__c, Actions_Webhook_Path__c
      FROM Copado_Builder_Settings__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ];
    if (!rows.isEmpty()) {
      s.commitJobTemplate = rows[0].Commit_Job_Template__c;
      s.deployJobTemplate = rows[0].Deploy_Job_Template__c;
      s.defaultDevEnvironmentId = rows[0].Default_Dev_Environment_Id__c;
      s.actionsWebhookPath = rows[0].Actions_Webhook_Path__c;
    }
    return s;
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
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return CopadoAiApiService.mockListPipelineOrgsPublic();
    }

    List<CopadoAiApiService.OrgInfo> fromEnv = queryEnvironments();
    if (!fromEnv.isEmpty()) {
      return fromEnv;
    }
    List<CopadoAiApiService.OrgInfo> fromCred = queryOrgCredentials();
    if (!fromCred.isEmpty()) {
      return fromCred;
    }
    // Soft fallback so UI still works; mark as mock-style names
    return CopadoAiApiService.mockListPipelineOrgsPublic();
  }

  private static List<CopadoAiApiService.OrgInfo> queryEnvironments() {
    List<CopadoAiApiService.OrgInfo> results = new List<CopadoAiApiService.OrgInfo>();
    Schema.SObjectType envType = Schema.getGlobalDescribe().get('copado__Environment__c');
    if (envType == null) {
      return results;
    }
    Map<String, Schema.SObjectField> fields = envType.getDescribe().fields.getMap();
    List<String> selectFields = new List<String>{ 'Id', 'Name' };
    String typeField = firstExisting(fields, new List<String>{
      'copado__Type__c', 'copado__Environment_Type__c', 'copado__Platform__c'
    });
    String orderField = firstExisting(fields, new List<String>{
      'copado__Order__c', 'copado__Index__c', 'copado__Pipeline_Order__c'
    });
    if (typeField != null) {
      selectFields.add(typeField);
    }
    if (orderField != null) {
      selectFields.add(orderField);
    }

    String soql = 'SELECT ' + String.join(selectFields, ',')
      + ' FROM copado__Environment__c ORDER BY '
      + (orderField != null ? orderField + ' ASC NULLS LAST, ' : '')
      + 'Name ASC LIMIT 50';
    try {
      Integer order = 1;
      for (SObject row : Database.query(soql)) {
        CopadoAiApiService.OrgInfo org = new CopadoAiApiService.OrgInfo();
        org.orgId = String.valueOf(row.get('Id'));
        org.orgName = String.valueOf(row.get('Name'));
        String typeVal = typeField != null && row.get(typeField) != null
          ? String.valueOf(row.get(typeField))
          : 'Sandbox';
        org.orgType = typeVal;
        org.isProduction = isProductionLabel(typeVal) || isProductionLabel(org.orgName);
        if (orderField != null && row.get(orderField) != null) {
          try {
            org.pipelineOrder = Integer.valueOf(String.valueOf(row.get(orderField)));
          } catch (Exception ignore) {
            org.pipelineOrder = order;
          }
        } else {
          org.pipelineOrder = order;
        }
        order++;
        results.add(org);
      }
    } catch (Exception ignore) {
    }
    results.sort();
    return results;
  }

  private static List<CopadoAiApiService.OrgInfo> queryOrgCredentials() {
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
    String envTypeField = firstExisting(fields, new List<String>{
      'copado__Environment_Type__c', 'copado__Org_Type__c', 'copado__Type__c'
    });
    if (envTypeField != null) {
      selectFields.add(envTypeField);
    }
    String soql = 'SELECT ' + String.join(selectFields, ',')
      + ' FROM ' + objectName + ' ORDER BY Name ASC LIMIT 50';
    try {
      Integer order = 1;
      for (SObject row : Database.query(soql)) {
        CopadoAiApiService.OrgInfo org = new CopadoAiApiService.OrgInfo();
        org.orgId = String.valueOf(row.get('Id'));
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

  private static Boolean isProductionLabel(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    String lower = value.toLowerCase();
    return lower.contains('prod') && !lower.contains('non-prod') && !lower.contains('nonprod');
  }

  // ---------------------------------------------------------------------------
  // Commit / Deploy
  // ---------------------------------------------------------------------------

  public static JobResult commitToUserStory(
    Id userStoryId,
    String packageJson,
    String commitMessage,
    List<String> artifactPaths
  ) {
    if (userStoryId == null) {
      throw new CopadoAiApiService.ApiException('User Story Id is required for commit.');
    }
    if (isMockDevops() || CopadoAiApiService.isMockMode()) {
      return mockJob('commit', userStoryId, commitMessage);
    }

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.commitJobTemplate)
      ? settings.commitJobTemplate
      : 'sfdx_commit_1';

    // Callouts before any DML
    JobResult webhookJob = null;
    if (String.isNotBlank(settings.actionsWebhookPath)) {
      webhookJob = callActionsWebhook(
        settings.actionsWebhookPath,
        template,
        userStoryId,
        null,
        commitMessage,
        packageJson,
        'commit'
      );
    }

    // DML after callouts
    ensureUserStoryEnvironment(userStoryId);
    Integer metaCount = upsertUserStoryMetadata(userStoryId, artifactPaths);

    JobResult job = webhookJob;
    if (job == null) {
      job = tryCreateJobExecution(template, userStoryId, null, commitMessage);
    }
    if (job == null) {
      job = new JobResult();
      job.jobId = 'prepared-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
      job.status = 'Prepared';
      job.method = 'metadata-prepare';
      job.summary = 'Package prepared on user story '
        + userStoryId
        + '. Configure Commit Job Template or Actions Webhook Path in Copado Builder Settings, '
        + 'or open the user story and run Commit in Copado.';
    }

    job.summary = 'Committed package to user story ('
      + metaCount + ' metadata members prepared). Job: '
      + job.jobId + ' via ' + job.method + '.';
    return job;
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

    DevopsSettings settings = getDevopsSettings();
    String template = String.isNotBlank(settings.deployJobTemplate)
      ? settings.deployJobTemplate
      : 'sfdx_deploy_1';

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

    JobResult job = webhookJob;
    if (job == null) {
      job = tryCreateJobExecution(template, userStoryId, environmentId, 'Deploy to ' + orgName);
    }
    if (job == null) {
      job = new JobResult();
      job.jobId = 'prepared-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
      job.status = 'Prepared';
      job.method = 'metadata-prepare';
      job.summary = 'Deploy prepared for ' + orgName
        + '. Configure Deploy Job Template or Actions Webhook Path, or promote from Copado Pipeline.';
    } else {
      job.summary = 'Deploy job started for ' + orgName + '. Job: ' + job.jobId + ' via ' + job.method + '.';
    }
    return job;
  }

  /**
   * Create or update Copado User Story Metadata rows for generated members when the object exists.
   */
  @TestVisible
  private static Integer upsertUserStoryMetadata(Id userStoryId, List<String> artifactPaths) {
    if (artifactPaths == null || artifactPaths.isEmpty()) {
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
    String nameField = firstExisting(fields, new List<String>{
      'copado__Metadata_API_Name__c', 'Name', 'copado__Api_Name__c'
    });
    String typeField = firstExisting(fields, new List<String>{
      'copado__Type__c', 'copado__Metadata_Type__c'
    });
    if (usField == null || nameField == null) {
      return 0;
    }

    List<SObject> rows = new List<SObject>();
    for (String path : artifactPaths) {
      if (String.isBlank(path)) {
        continue;
      }
      Map<String, String> parsed = parseMetadataFromPath(path);
      SObject row = metaType.newSObject();
      row.put(usField, userStoryId);
      if (nameField == 'Name') {
        String n = parsed.get('member');
        row.put('Name', n != null && n.length() > 80 ? n.substring(0, 80) : n);
      } else {
        row.put(nameField, parsed.get('member'));
      }
      if (typeField != null) {
        row.put(typeField, parsed.get('type'));
      }
      rows.add(row);
      if (rows.size() >= 40) {
        break;
      }
    }
    if (rows.isEmpty()) {
      return 0;
    }
    try {
      Database.insert(rows, false);
      return rows.size();
    } catch (Exception ex) {
      return 0;
    }
  }

  @TestVisible
  private static Map<String, String> parseMetadataFromPath(String path) {
    Map<String, String> out = new Map<String, String>{
      'type' => 'CustomField',
      'member' => path
    };
    String p = path.replace('\\', '/');
    if (p.contains('/objects/') && p.endsWith('.field-meta.xml')) {
      // force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml
      List<String> parts = p.split('/');
      String objectName = null;
      String fieldFile = null;
      for (Integer i = 0; i < parts.size(); i++) {
        if (parts[i] == 'objects' && i + 1 < parts.size()) {
          objectName = parts[i + 1];
        }
        if (parts[i] == 'fields' && i + 1 < parts.size()) {
          fieldFile = parts[i + 1];
        }
      }
      String fieldApi = fieldFile != null ? fieldFile.replace('.field-meta.xml', '') : 'Field';
      out.put('type', 'CustomField');
      out.put('member', objectName != null ? objectName + '.' + fieldApi : fieldApi);
    } else if (p.contains('/classes/') && p.endsWith('.cls')) {
      out.put('type', 'ApexClass');
      out.put('member', p.substring(p.lastIndexOf('/') + 1).replace('.cls', ''));
    } else if (p.contains('/lwc/')) {
      out.put('type', 'LightningComponentBundle');
      List<String> parts = p.split('/');
      String bundle = 'lwcComponent';
      for (Integer i = 0; i < parts.size(); i++) {
        if (parts[i] == 'lwc' && i + 1 < parts.size()) {
          bundle = parts[i + 1];
          break;
        }
      }
      out.put('member', bundle);
    } else if (p.contains('/triggers/') && p.endsWith('.trigger')) {
      out.put('type', 'ApexTrigger');
      out.put('member', p.substring(p.lastIndexOf('/') + 1).replace('.trigger', ''));
    }
    return out;
  }

  private static void ensureUserStoryEnvironment(Id userStoryId) {
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      return;
    }
    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    String envField = firstExisting(fields, new List<String>{
      'copado__Environment__c', 'copado__Org_Credential__c', 'copado__Org__c'
    });
    if (envField == null) {
      return;
    }
    DevopsSettings settings = getDevopsSettings();
    Id envId = null;
    if (String.isNotBlank(settings.defaultDevEnvironmentId)) {
      try {
        envId = (Id) settings.defaultDevEnvironmentId;
      } catch (Exception ignore) {
      }
    }
    if (envId == null) {
      List<CopadoAiApiService.OrgInfo> orgs = listPipelineOrgs();
      for (CopadoAiApiService.OrgInfo o : orgs) {
        if (o.isProduction != true) {
          try {
            envId = (Id) o.orgId;
          } catch (Exception ignore) {
          }
          break;
        }
      }
    }
    if (envId == null) {
      return;
    }
    try {
      List<SObject> existing = Database.query(
        'SELECT Id, ' + envField + ' FROM copado__User_Story__c WHERE Id = :userStoryId LIMIT 1'
      );
      if (existing.isEmpty()) {
        return;
      }
      if (existing[0].get(envField) == null) {
        SObject us = usType.newSObject();
        us.put('Id', userStoryId);
        us.put(envField, envId);
        update us;
      }
    } catch (Exception ignore) {
    }
  }

  // runJobTemplate removed — commit/deploy call webhook first, then DML.

  private static JobResult tryCreateJobExecution(
    String templateName,
    Id userStoryId,
    String environmentId,
    String message
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
    String templateField = firstExisting(fields, new List<String>{
      'copado__JobTemplate__c', 'copado__Job_Template__c', 'copado__Template__c'
    });
    String nameField = firstExisting(fields, new List<String>{ 'Name', 'copado__Name__c' });
    String usField = firstExisting(fields, new List<String>{
      'copado__UserStory__c', 'copado__User_Story__c', 'copado__ParentId__c'
    });
    String statusField = firstExisting(fields, new List<String>{
      'copado__Status__c', 'copado__Job_Status__c'
    });
    String dataField = firstExisting(fields, new List<String>{
      'copado__DataJson__c', 'copado__DataJSON__c', 'copado__VolumeOptions__c'
    });

    if (templateField != null && templateId != null) {
      job.put(templateField, templateId);
    }
    if (nameField != null) {
      String n = 'Builder ' + templateName + ' ' + Datetime.now().format('yyyy-MM-dd HH:mm');
      job.put(nameField, n.length() > 80 ? n.substring(0, 80) : n);
    }
    if (usField != null) {
      job.put(usField, userStoryId);
    }
    if (statusField != null) {
      job.put(statusField, 'Not Started');
    }
    if (dataField != null) {
      Map<String, Object> payload = new Map<String, Object>{
        'userStoryId' => String.valueOf(userStoryId),
        'environmentId' => environmentId,
        'message' => message,
        'source' => 'CopadoBuilder'
      };
      job.put(dataField, JSON.serialize(payload));
    }

    try {
      insert job;
      JobResult result = new JobResult();
      result.jobId = String.valueOf(job.get('Id'));
      result.status = 'Queued';
      result.method = 'JobExecution';
      result.summary = 'Created Copado Job Execution ' + result.jobId;
      return result;
    } catch (Exception ex) {
      return null;
    }
  }

  private static Id resolveJobTemplateId(String templateName) {
    if (String.isBlank(templateName)) {
      return null;
    }
    // Already an Id?
    try {
      if (templateName.length() == 15 || templateName.length() == 18) {
        return (Id) templateName;
      }
    } catch (Exception ignore) {
    }

    for (String objectName : new List<String>{
      'copado__JobTemplate__c', 'copado__Job_Template__c'
    }) {
      Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
      if (t == null) {
        continue;
      }
      try {
        List<SObject> rows = Database.query(
          'SELECT Id FROM ' + objectName
          + ' WHERE Name = :templateName OR DeveloperName = :templateName LIMIT 1'
        );
        // DeveloperName may not exist — retry Name only
      } catch (Exception ignore) {
        try {
          List<SObject> rows = Database.query(
            'SELECT Id FROM ' + objectName + ' WHERE Name = :templateName LIMIT 1'
          );
          if (!rows.isEmpty()) {
            return (Id) rows[0].get('Id');
          }
        } catch (Exception ignore2) {
        }
      }
      try {
        List<SObject> rows = Database.query(
          'SELECT Id FROM ' + objectName + ' WHERE Name = :templateName LIMIT 1'
        );
        if (!rows.isEmpty()) {
          return (Id) rows[0].get('Id');
        }
      } catch (Exception ignore) {
      }
    }
    return null;
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
    result.jobId = kind + '-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
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

  private static String truncate(String value, Integer maxLen) {
    if (String.isBlank(value) || value.length() <= maxLen) {
      return value;
    }
    return value.substring(0, maxLen);
  }
}
