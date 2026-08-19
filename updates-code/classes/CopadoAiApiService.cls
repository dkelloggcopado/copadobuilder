/**
 * Copado AI API integration layer.
 * Callouts use the CMDT Base URL (Remote Site allowlisted) so per-user PAT
 * headers set in Apex are not stripped. Named Credential Copado_AI_API is
 * URL/config only — do not rely on its External Credential for Builder auth.
 * Toggle live vs mock via Copado_Builder_Settings__mdt.Use_Mock_API__c.
 */
public with sharing class CopadoAiApiService {

  /** Fallback when Copado Builder Settings Base Url is blank. */
  private static final String DEFAULT_BASE_URL = 'https://copadogpt-api.robotic.copado.com';
  private static final String WORKSPACE_NAME = 'Copado Builder';
  /**
   * Copado AI specialist agents (assistantId / expert slug):
   *   build    → Salesforce Org Analysis + Org Intelligence (live org metadata)
   *   plan     → user stories, acceptance criteria, requirements
   *   test     → Apex tests, coverage, CRT
   *   release  → promotions, deployments
   *   operate  → change mgmt, incident/error triage
   *   knowledge→ Copado Expert (general Copado/SF best practices; NO org metadata)
   * Org Intelligence is requested via message integrations (copado_cicd) on
   * assistantId=build. POST /agents is optional and must never block chat.
   *
   * Note: "orchestrate" is marketed as the coordinator but many tenants return
   * 403 "no access to the given AI assistant" — do not use it as default.
   */
  public static final String ASSISTANT_BUILD = 'build';
  public static final String ASSISTANT_PLAN = 'plan';
  public static final String ASSISTANT_TEST = 'test';
  public static final String ASSISTANT_RELEASE = 'release';
  public static final String ASSISTANT_OPERATE = 'operate';
  public static final String ASSISTANT_KNOWLEDGE = 'knowledge';
  /** Default dialogue assistant — Build (OI-capable + widely licensed). */
  private static final String BUILDER_ASSISTANT_ID = ASSISTANT_BUILD;
  private static final String BUILDER_SYSTEM_PROMPT =
    'You are Copado Builder, a helpful assistant for Salesforce/Copado user stories. '
    + 'Ask clarifying questions about requirements, acceptance criteria, org context, and testability. '
    + 'When Org Intelligence is available, use live target-org metadata '
    + '(existing objects, fields, automation, naming conventions) before proposing new components. '
    + 'For Copado User Story / backlog questions, use injected COPADO GOVERNANCE DATA. '
    + 'Format like Copado AI chat: short paragraphs, bullet lists with "- ", '
    + 'bold field/API names sparingly, prefer bullets over markdown tables. '
    + 'Keep replies plain-English and concise.';

  /** Used for Build / package generation — never ask questions; JSON only. */
  private static final String PACKAGE_BUILD_SYSTEM_PROMPT =
    'You are Copado Builder’s metadata package generator. '
    + 'Your only job is to output a valid Salesforce metadata package as JSON. '
    + 'Never ask clarifying questions. Never apologize. Never use markdown fences. '
    + 'Generate from the story technical specs. Prefer the smallest complete package. '
    + 'If a detail is unclear, apply safe defaults for field type/label/API name and FLS. '
    + 'When specs list picklist values, include EVERY value in the field XML — never omit or summarize the list. '
    + 'When AUTHORITATIVE LIVE METADATA is present, use those exact fullNames verbatim for any '
    + 'type listed (Layout, Flow, FlexiPage, Profile, PermissionSet, CustomObject, etc.). '
    + 'Never invent, translate, or default names. '
    + 'When the story requires adding a field to a page layout, include CustomField + Profile '
    + '(or Permission Set) FLS + Layout — but ONLY if AUTHORITATIVE LIVE METADATA (or '
    + 'AUTHORITATIVE LIVE LAYOUTS) lists the exact Layout fullName '
    + '(example shape: Account-Formato de cuentas). '
    + 'NEVER invent or guess layout names. NEVER default to Account-Account Layout or '
    + 'Object-Object Layout — those English defaults are often wrong in localized orgs. '
    + 'Layout file path must be force-app/main/default/layouts/<exact-fullName>.layout-meta.xml. '
    + 'If no authoritative Layout fullName is listed, omit the layout file and say so in summary. '
    + 'Layout XML must include required field Name plus every new custom field. '
    + 'Reply with ONLY the JSON object.';

  /**
   * @deprecated Do not use on Org Intelligence turns — native Copado AI sends the
   * raw user prompt only. Prefixing breaks tool use / causes UNAVAILABLE replies.
   */
  public static String prefixOrgIntelligencePrompt(String message) {
    return blankTo(message, '');
  }

  /**
   * Route a user message to the best specialist. Default is Build.
   * Governance/backlog → Plan. Metadata → Build (Org Intelligence).
   */
  public static String routeAssistant(String message) {
    if (String.isBlank(message)) {
      return ASSISTANT_BUILD;
    }
    String m = message.toLowerCase();
    if (isGovernanceBacklogQuestion(message)) {
      return ASSISTANT_PLAN;
    }
    // Live Dev-org metadata → Build (Org Intelligence tools)
    if (containsAny(m, new List<String>{
      'field', 'object', 'schema', 'metadata', 'exist', 'exists', 'flow',
      'apex class', 'trigger', 'validation rule', 'layout', 'permission set',
      'profile', 'record type', 'lwc', 'component', 'picklist',
      'where is', 'where used', 'in the org', 'in my org', 'in this org',
      'generate', 'build'
    })) {
      return ASSISTANT_BUILD;
    }
    if (containsAny(m, new List<String>{ 'in dev', 'dev1', 'sandbox' })
      && containsAny(m, new List<String>{
        'field', 'object', 'exist', 'metadata', 'class', 'flow', 'layout'
      })) {
      return ASSISTANT_BUILD;
    }
    if (containsAny(m, new List<String>{
      'unit test', 'apex test', 'test coverage', 'crt', 'robotic test'
    })) {
      return ASSISTANT_TEST;
    }
    if (containsAny(m, new List<String>{
      'promote', 'promotion', 'back-promote', 'pipeline stage'
    })) {
      return ASSISTANT_RELEASE;
    }
    if (containsAny(m, new List<String>{
      'incident', 'root cause', 'rollback', 'outage'
    })) {
      return ASSISTANT_OPERATE;
    }
    if (containsAny(m, new List<String>{
      'user story', 'story', 'acceptance criteria', 'requirement', 'persona',
      'sprint', 'epic', 'prioriti', 'scope', 'business need'
    })) {
      return ASSISTANT_PLAN;
    }
    return ASSISTANT_BUILD;
  }

  /** True when the user is asking about Copado User Story records / backlog. */
  public static Boolean isGovernanceBacklogQuestion(String message) {
    if (String.isBlank(message)) {
      return false;
    }
    String m = message.toLowerCase();
    return containsAny(m, new List<String>{
      'how many user stor',
      'how many stor',
      'user stories',
      'user story count',
      'story count',
      'backlog',
      'what should i work',
      'what to work on',
      'what should we work',
      'work on next',
      'stories in',
      'which user stor',
      'list user stor',
      'all user stor',
      'story dependenc',
      'user story dependenc',
      'related user stor',
      'governance org',
      'copado org',
      'read the copado',
      'see the copado',
      'query the copado',
      'from the copado'
    });
  }

  /**
   * True when the prompt needs live Dev-org metadata (Org Intelligence).
   * Greetings and story chat must NOT attach integrations — that path hangs
   * simple turns like "Hello" on empty streams / tool waits.
   */
  public static Boolean needsOrgIntelligence(String message) {
    if (String.isBlank(message) || isGovernanceBacklogQuestion(message)) {
      return false;
    }
    String m = message.toLowerCase().trim();
    // Very short greetings / pings
    if (m.length() <= 40 && containsAny(m, new List<String>{
      'hello', 'hi ', 'hi!', 'hey', 'thanks', 'thank you', 'test', 'ping', 'hola'
    })) {
      return false;
    }
    if (m.contains('__c') || m.contains('__e') || m.contains('__mdt') || m.contains('__b')) {
      return true;
    }
    return containsAny(m, new List<String>{
      'field', 'object', 'schema', 'metadata', 'exist', 'exists', 'flow',
      'apex class', 'trigger', 'validation rule', 'layout', 'permission set',
      'profile', 'record type', 'lwc', 'component', 'picklist',
      'where is', 'where used', 'in the org', 'in my org', 'in this org',
      'custom field', 'api name', 'data type', 'what type of field',
      'deployed', 'deployment', 'check the component', 'check component'
    });
  }

  /**
   * True when the user is asking whether Builder already deployed / committed
   * components — answer from session job state, not from Org Intelligence guesswork.
   */
  public static Boolean isDeployVerificationQuestion(String message) {
    if (String.isBlank(message)) {
      return false;
    }
    String m = message.toLowerCase().trim();
    // Explicit deploy / component-check asks — answer from Builder job state.
    if (containsAny(m, new List<String>{
      'were they deployed',
      'was it deployed',
      'were the components',
      'are the components',
      'did we deploy',
      'have we deployed',
      'did deploy',
      'deploy succeed',
      'deploy succeeded',
      'deploy status',
      'deployment status',
      'check deployment',
      'check the deploy',
      'check deploy',
      'check the component',
      'check component',
      'check the artifact',
      'verify deploy',
      'verify the deploy',
      'verify component',
      'confirm deploy',
      'confirm the deploy',
      'deployed to',
      'deployed in',
      'deployed yet'
    })) {
      return true;
    }
    // "check ... in the/dev1 org" style without inventing a live OI scan.
    if (containsAny(m, new List<String>{ 'check', 'verify', 'confirm' })
      && containsAny(m, new List<String>{ 'component', 'artifact', 'package', 'field', 'layout' })
      && containsAny(m, new List<String>{
        'org', 'dev1', 'sandbox', 'environment', 'deploy'
      })) {
      return true;
    }
    return false;
  }

  private static Boolean containsAny(String haystack, List<String> needles) {
    for (String n : needles) {
      if (haystack.contains(n)) {
        return true;
      }
    }
    return false;
  }

  public class WorkspaceResult {
    @AuraEnabled public String workspaceId;
    @AuraEnabled public String workspaceName;
    @AuraEnabled public String status;
  }

  public class DialogueResult {
    @AuraEnabled public String dialogueId;
    @AuraEnabled public String message;
    @AuraEnabled public String status;
    @AuraEnabled public String assistantId;
    /** True when POST /messages returned empty and reply must be polled. */
    @AuraEnabled public Boolean pending;
    @AuraEnabled public String requestId;
    /** Dialogue size / last assistant text before this POST (for safe polling). */
    @AuraEnabled public Integer baselineMessageCount;
    @AuraEnabled public String baselineAssistantText;
  }

  public class DocumentResult {
    @AuraEnabled public String documentId;
    @AuraEnabled public String fileName;
    @AuraEnabled public String status;
  }

  public class BuildResult {
    @AuraEnabled public String buildId;
    @AuraEnabled public String summary;
    @AuraEnabled public String status;
    @AuraEnabled public List<String> artifacts;
    @AuraEnabled public String packageJson;
    /** True when Copado AI is still generating — caller should poll. */
    @AuraEnabled public Boolean pending;
    @AuraEnabled public String dialogueId;
    @AuraEnabled public String requestId;
    @AuraEnabled public Integer baselineMessageCount;
    @AuraEnabled public String baselineAssistantText;
  }

  public class TestResult {
    @AuraEnabled public String testSuiteId;
    @AuraEnabled public String summary;
    @AuraEnabled public String status;
    @AuraEnabled public Integer testCount;
  }

  public class DeployResult {
    @AuraEnabled public String deploymentId;
    @AuraEnabled public String summary;
    @AuraEnabled public String status;
    @AuraEnabled public String targetOrg;
  }

  public class OrgInfo implements Comparable {
    @AuraEnabled public String orgId;
    @AuraEnabled public String orgName;
    @AuraEnabled public String orgType;
    @AuraEnabled public Boolean isProduction;
    @AuraEnabled public Integer pipelineOrder;

    public Integer compareTo(Object other) {
      OrgInfo o = (OrgInfo) other;
      if (this.pipelineOrder == o.pipelineOrder) {
        return 0;
      }
      return this.pipelineOrder < o.pipelineOrder ? -1 : 1;
    }
  }

  public class StoryResult {
    @AuraEnabled public String storyId;
    @AuraEnabled public String storyName;
    @AuraEnabled public String summary;
    @AuraEnabled public String status;
    @AuraEnabled public String recordId;
  }

  /** Org Intelligence / Copado CI/CD integration probe + bind result. */
  public class OrgIntelligenceResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String status;
    @AuraEnabled public String integrationId;
    @AuraEnabled public String salesforceIntegrationId;
    @AuraEnabled public Boolean needsSalesforceAuth;
    @AuraEnabled public String workspaceId;
    @AuraEnabled public String orgCredentialId;
    @AuraEnabled public String orgName;
    @AuraEnabled public String message;
    @AuraEnabled public String probeAnswer;
    /** Fresh dialogue for chat after probe (avoids poisoning session dialogue). */
    @AuraEnabled public String chatDialogueId;
    /** True only when configure shows the selected Dev credential as the active one. */
    @AuraEnabled public Boolean credentialBound;
    @AuraEnabled public String rawConfigureJson;
    @AuraEnabled public String rawIntegrationsJson;
    @AuraEnabled public String rawCheckStatusJson;
  }

  /** Result of starting Copado AI Salesforce OAuth (Org Intelligence metadata). */
  public class SalesforceAuthResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String authUrl;
    @AuraEnabled public String message;
    @AuraEnabled public String rawResponse;
  }

  /** Copado AI integration row for Org Intelligence picker. */
  public class IntegrationInfo implements Comparable {
    @AuraEnabled public String id;
    @AuraEnabled public String name;
    @AuraEnabled public String type;
    @AuraEnabled public String level;
    @AuraEnabled public String status;
    @AuraEnabled public Boolean connected;
    @AuraEnabled public String label;
    /** Higher = better match to the running Salesforce user (name/email). */
    @AuraEnabled public Integer matchScore;
    @AuraEnabled public Boolean matchedToCurrentUser;

    public Integer compareTo(Object other) {
      IntegrationInfo o = (IntegrationInfo) other;
      Integer ascore = this.matchScore == null ? 0 : this.matchScore;
      Integer bscore = o.matchScore == null ? 0 : o.matchScore;
      if (ascore != bscore) {
        return ascore > bscore ? -1 : 1;
      }
      Boolean a = this.connected == true;
      Boolean b = o.connected == true;
      if (a != b) {
        return a ? -1 : 1;
      }
      String an = this.name == null ? '' : this.name.toLowerCase();
      String bn = o.name == null ? '' : o.name.toLowerCase();
      if (an == bn) {
        return 0;
      }
      return an < bn ? -1 : 1;
    }
  }

  public class WorkspaceOrgIntelligenceStatus {
    @AuraEnabled public Boolean connected;
    @AuraEnabled public String status;
    @AuraEnabled public String integrationId;
  }

  public class Settings {
    public String organizationId;
    public String workspaceId;
    public Boolean useMockApi;
    /** Copado AI API host for the org's region (no trailing slash). */
    public String baseUrl;
  }

  /** Prefer this over AuraHandledException so catch blocks can read the real message. */
  public class ApiException extends Exception {
  }

  /**
   * One typed Metadata API listMetadata request for Org Intelligence.
   * Child types (CustomField, RecordType, ValidationRule) should set objectApi.
   * Foldered types (EmailTemplate, Report, Dashboard, Document) may set folder.
   */
  public class MetadataListRequest {
    public String metadataType;
    public String objectApi;
    public String folder;
    public String namePrefix;

    public MetadataListRequest() {
    }

    public MetadataListRequest(String metadataType) {
      this.metadataType = metadataType;
    }

    public MetadataListRequest(String metadataType, String objectApi) {
      this.metadataType = metadataType;
      this.objectApi = objectApi;
    }
  }

  public static Settings getSettings() {
    Settings settings = new Settings();
    settings.useMockApi = true;
    settings.organizationId = null;
    settings.workspaceId = null;
    settings.baseUrl = DEFAULT_BASE_URL;

    List<Copado_Builder_Settings__mdt> rows = [
      SELECT Organization_Id__c, Workspace_Id__c, Use_Mock_API__c, Base_Url__c,
        Commit_Job_Template__c, Deploy_Job_Template__c,
        Default_Dev_Environment_Id__c, Actions_Webhook_Path__c
      FROM Copado_Builder_Settings__mdt
      WHERE DeveloperName = 'Default'
      LIMIT 1
    ];
    if (!rows.isEmpty()) {
      settings.organizationId = rows[0].Organization_Id__c;
      settings.workspaceId = rows[0].Workspace_Id__c;
      settings.useMockApi = rows[0].Use_Mock_API__c == true;
      if (String.isNotBlank(rows[0].Base_Url__c)) {
        settings.baseUrl = rows[0].Base_Url__c.trim().removeEnd('/');
      }
    }
    return settings;
  }

  /**
   * Absolute Copado AI URL. Avoids Named Credential + External Credential, which
   * manages auth headers and can drop Apex-set X-Authorization / Api-Key.
   */
  @TestVisible
  private static String calloutUrl(String path) {
    String base = getSettings().baseUrl;
    if (String.isBlank(base)) {
      base = DEFAULT_BASE_URL;
    }
    String p = String.isBlank(path) ? '' : path;
    if (!p.startsWith('/')) {
      p = '/' + p;
    }
    return base.removeEnd('/') + p;
  }

  /** When true in tests, resolveApiKey/hasUserCopadoAiPat read Hierarchy CS (not mock short-circuit). */
  @TestVisible
  private static Boolean bypassMockForAuthInTest = false;

  /**
   * Running user's Copado AI Personal Access Token.
   * Stored on private Copado_Builder_User_Secret__c (Long Text) — never a shared org PAT.
   */
  @TestVisible
  public static String resolveApiKey() {
    if (isMockMode() && !bypassMockForAuthInTest) {
      return null;
    }
    String pat = readUserPatFromSetting();
    if (String.isNotBlank(pat)) {
      return pat;
    }
    throw new ApiException(
      'Add your Copado AI Personal Access Token in Copado Builder setup. '
        + 'Each user must use their own token — a shared org token cannot access '
        + 'another user\'s Org Intelligence / User Level integration.'
    );
  }

  @TestVisible
  private static String readUserPatFromSetting() {
    Id userId = UserInfo.getUserId();
    String key = String.valueOf(userId);
    // Preferred: private custom object (supports Long Text PATs).
    try {
      List<Copado_Builder_User_Secret__c> secrets = [
        SELECT Copado_AI_PAT__c
        FROM Copado_Builder_User_Secret__c
        WHERE OwnerId = :userId AND External_Key__c = :key
        LIMIT 1
      ];
      if (!secrets.isEmpty() && String.isNotBlank(secrets[0].Copado_AI_PAT__c)) {
        return normalizePat(secrets[0].Copado_AI_PAT__c);
      }
    } catch (Exception ignore) {
    }
    // Legacy fallback: Hierarchy Custom Setting (255-char limit — often truncates JWTs).
    String legacyPat = null;
    try {
      List<Copado_Builder_Auth__c> rows = [
        SELECT Copado_AI_PAT__c
        FROM Copado_Builder_Auth__c
        WHERE SetupOwnerId = :userId
        LIMIT 1
      ];
      if (!rows.isEmpty() && String.isNotBlank(rows[0].Copado_AI_PAT__c)) {
        legacyPat = normalizePat(rows[0].Copado_AI_PAT__c);
      }
    } catch (Exception ignore) {
    }
    if (String.isBlank(legacyPat)) {
      Copado_Builder_Auth__c row = Copado_Builder_Auth__c.getValues(userId);
      legacyPat = row != null && String.isNotBlank(row.Copado_AI_PAT__c)
        ? normalizePat(row.Copado_AI_PAT__c)
        : null;
    }
    if (String.isBlank(legacyPat)) {
      return null;
    }
    // Exact 255 usually means Salesforce truncated a longer PAT on save.
    if (legacyPat.length() >= 255) {
      throw new ApiException(
        'Your saved Copado AI token looks truncated (old 255-character limit). '
          + 'Open Builder → Update Copado AI token, paste a fresh full PAT, then retry.'
      );
    }
    return legacyPat;
  }

  @TestVisible
  private static String normalizePat(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String trimmed = raw.trim().replaceAll('\\s+', '');
    // Strip accidental wrapping quotes from paste.
    if (trimmed.length() >= 2
      && ((trimmed.startsWith('"') && trimmed.endsWith('"'))
        || (trimmed.startsWith('\'') && trimmed.endsWith('\'')))) {
      trimmed = trimmed.substring(1, trimmed.length() - 1).trim();
    }
    return String.isNotBlank(trimmed) ? trimmed : null;
  }

  /** True when the running user has a user-level PAT stored (never returns the secret). */
  public static Boolean hasUserCopadoAiPat() {
    if (isMockMode() && !bypassMockForAuthInTest) {
      return true;
    }
    return String.isNotBlank(readUserPatFromSetting());
  }

  /** Last 4 characters of the stored PAT for UI confirmation (empty if none). */
  public static String getUserCopadoAiPatMask() {
    if (isMockMode() && !bypassMockForAuthInTest) {
      return 'mock';
    }
    String trimmed = readUserPatFromSetting();
    if (String.isBlank(trimmed)) {
      return '';
    }
    if (trimmed.length() <= 4) {
      return '••••';
    }
    return '••••' + trimmed.substring(trimmed.length() - 4);
  }

  /** Upsert the running user's PAT (Long Text on private User Secret). */
  public static void saveUserCopadoAiPat(String pat) {
    if (String.isBlank(pat)) {
      throw new ApiException('Copado AI Personal Access Token is required.');
    }
    String trimmed = normalizePat(pat);
    if (String.isBlank(trimmed)) {
      throw new ApiException('Copado AI Personal Access Token is required.');
    }
    if (trimmed.length() > 32768) {
      throw new ApiException(
        'Copado AI Personal Access Token is too long. '
          + 'Paste the token from Copado AI Platform → Personal Access Tokens.'
      );
    }
    Id userId = UserInfo.getUserId();
    String key = String.valueOf(userId);
    Copado_Builder_User_Secret__c secret = new Copado_Builder_User_Secret__c(
      OwnerId = userId,
      External_Key__c = key,
      Copado_AI_PAT__c = trimmed
    );
    upsert secret External_Key__c;
    // Clear legacy Hierarchy CS row so a truncated 255-char PAT cannot override.
    try {
      List<Copado_Builder_Auth__c> legacy = [
        SELECT Id
        FROM Copado_Builder_Auth__c
        WHERE SetupOwnerId = :userId
        LIMIT 1
      ];
      if (!legacy.isEmpty()) {
        delete legacy;
      }
    } catch (Exception ignore) {
    }
  }

  /** Remove the running user's stored PAT. */
  public static void clearUserCopadoAiPat() {
    Id userId = UserInfo.getUserId();
    String key = String.valueOf(userId);
    try {
      List<Copado_Builder_User_Secret__c> secrets = [
        SELECT Id
        FROM Copado_Builder_User_Secret__c
        WHERE OwnerId = :userId AND External_Key__c = :key
        LIMIT 1
      ];
      if (!secrets.isEmpty()) {
        delete secrets;
      }
    } catch (Exception ignore) {
    }
    try {
      List<Copado_Builder_Auth__c> legacy = [
        SELECT Id
        FROM Copado_Builder_Auth__c
        WHERE SetupOwnerId = :userId
        LIMIT 1
      ];
      if (!legacy.isEmpty()) {
        delete legacy;
      }
    } catch (Exception ignore) {
    }
  }

  /** Apply per-user PAT auth headers (literal — not Named Credential merge fields). */
  @TestVisible
  private static void applyCopadoAiAuthHeaders(HttpRequest req) {
    String pat = resolveApiKey();
    if (String.isBlank(pat)) {
      return;
    }
    req.setHeader('X-Authorization', pat);
    req.setHeader('Api-Key', pat);
  }

  public static Boolean isMockMode() {
    // Always mock in unit tests to avoid live callouts during deploy
    if (Test.isRunningTest()) {
      return true;
    }
    return getSettings().useMockApi;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  public static WorkspaceResult ensureBuilderWorkspace() {
    if (isMockMode()) {
      return mockCreateWorkspace(WORKSPACE_NAME);
    }

    Settings settings = getSettings();
    requireOrgId(settings);

    // Prefer configured workspace id — but recover if it was deleted in Copado AI.
    if (String.isNotBlank(settings.workspaceId)) {
      try {
        ensureWorkspaceCapabilities(settings.organizationId, settings.workspaceId);
        return getWorkspace(settings.workspaceId);
      } catch (Exception staleWorkspace) {
        // Fall through to name lookup / create.
      }
    }

    // Prefer existing Builder workspaces (UI may show "CB Copado Builder").
    HttpResponse listRes = sendRequest('GET', '/organizations/' + settings.organizationId + '/workspaces', null);
    assertOk(listRes, 'List workspaces');
    Object parsed = JSON.deserializeUntyped(listRes.getBody());
    if (parsed instanceof List<Object>) {
      String preferredId = null;
      String preferredName = null;
      for (Object item : (List<Object>) parsed) {
        Map<String, Object> ws = (Map<String, Object>) item;
        String name = String.valueOf(ws.get('name'));
        if (isBuilderWorkspaceName(name)) {
          String existingId = String.valueOf(ws.get('id'));
          // Prefer exact "Copado Builder", else first CB* match.
          if (WORKSPACE_NAME.equals(name)) {
            preferredId = existingId;
            preferredName = name;
            break;
          }
          if (preferredId == null) {
            preferredId = existingId;
            preferredName = name;
          }
        }
      }
      if (String.isNotBlank(preferredId)) {
        ensureWorkspaceCapabilities(settings.organizationId, preferredId);
        WorkspaceResult existing = new WorkspaceResult();
        existing.workspaceId = preferredId;
        existing.workspaceName = preferredName;
        existing.status = 'active';
        return existing;
      }
    }

    Map<String, Object> body = new Map<String, Object>{
      'name' => WORKSPACE_NAME,
      'description' => 'Workspace for Copado Builder chat sessions',
      // OpenAPI WorkspaceCapability enum uses PascalCase values.
      'capabilities' => builderWorkspaceCapabilities()
    };
    HttpResponse createRes = sendRequest(
      'POST',
      '/organizations/' + settings.organizationId + '/workspaces',
      JSON.serialize(body)
    );
    assertOk(createRes, 'Create workspace');
    Map<String, Object> created = (Map<String, Object>) JSON.deserializeUntyped(createRes.getBody());
    WorkspaceResult result = new WorkspaceResult();
    result.workspaceId = String.valueOf(created.get('id'));
    result.workspaceName = WORKSPACE_NAME;
    result.status = 'active';
    return result;
  }

  @TestVisible
  private static Boolean isBuilderWorkspaceName(String name) {
    if (String.isBlank(name)) {
      return false;
    }
    String n = name.trim().toLowerCase();
    return n == 'copado builder'
      || n == 'cb copado builder'
      || n.contains('copado builder');
  }

  /**
   * Resolve workspace + dialogue ids that are guaranteed to exist in Copado AI.
   * Recreates either when missing or when Copado returns 404 (deleted in UI).
   */
  public static Map<String, String> resolveLiveChatIds(
    String workspaceId,
    String dialogueId,
    String dialogueName
  ) {
    Map<String, String> out = new Map<String, String>();
    if (isMockMode()) {
      out.put('workspaceId', String.isNotBlank(workspaceId) ? workspaceId : 'mock-ws');
      out.put(
        'dialogueId',
        String.isNotBlank(dialogueId) ? dialogueId : 'mock-dlg'
      );
      return out;
    }
    Settings settings = getSettings();
    requireOrgId(settings);

    String wsId = workspaceId;
    if (String.isBlank(wsId) || !workspaceExists(settings.organizationId, wsId)) {
      wsId = ensureBuilderWorkspace().workspaceId;
    }
    String dlgId = dialogueId;
    if (String.isBlank(dlgId) || !dialogueExists(settings.organizationId, dlgId)) {
      DialogueResult created = createDialogue(
        wsId,
        String.isBlank(dialogueName) ? 'Builder Chat' : dialogueName
      );
      dlgId = created.dialogueId;
    }
    out.put('workspaceId', wsId);
    out.put('dialogueId', dlgId);
    return out;
  }

  @TestVisible
  private static Boolean workspaceExists(String organizationId, String workspaceId) {
    if (String.isBlank(organizationId) || String.isBlank(workspaceId)) {
      return false;
    }
    try {
      HttpResponse res = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/workspaces/' + workspaceId,
        null
      );
      return res.getStatusCode() >= 200 && res.getStatusCode() < 300;
    } catch (Exception ignore) {
      return false;
    }
  }

  @TestVisible
  private static Boolean dialogueExists(String organizationId, String dialogueId) {
    if (String.isBlank(organizationId) || String.isBlank(dialogueId)) {
      return false;
    }
    try {
      HttpResponse res = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/dialogues/' + dialogueId,
        null
      );
      return res.getStatusCode() >= 200 && res.getStatusCode() < 300;
    } catch (Exception ignore) {
      return false;
    }
  }

  public static WorkspaceResult createWorkspace(String name) {
    if (isMockMode()) {
      return mockCreateWorkspace(name);
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    Map<String, Object> body = new Map<String, Object>{
      'name' => name,
      'description' => 'Created by Copado Builder'
    };
    HttpResponse res = sendRequest(
      'POST',
      '/organizations/' + settings.organizationId + '/workspaces',
      JSON.serialize(body)
    );
    assertOk(res, 'Create workspace');
    Map<String, Object> created = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    WorkspaceResult result = new WorkspaceResult();
    result.workspaceId = String.valueOf(created.get('id'));
    result.workspaceName = name;
    result.status = 'active';
    return result;
  }

  public static WorkspaceResult getWorkspace(String workspaceId) {
    if (isMockMode()) {
      return mockGetWorkspace(workspaceId);
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    HttpResponse res = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId + '/workspaces/' + workspaceId,
      null
    );
    assertOk(res, 'Get workspace');
    Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    WorkspaceResult result = new WorkspaceResult();
    result.workspaceId = String.valueOf(data.get('id'));
    result.workspaceName = data.containsKey('name') ? String.valueOf(data.get('name')) : WORKSPACE_NAME;
    result.status = 'active';
    return result;
  }

  private static List<String> builderWorkspaceCapabilities() {
    return new List<String>{
      'FollowUpQuestions',
      'Reasoning',
      'SourceFormatKnowledge',
      'MetadataFormatKnowledge',
      'EssentialsKnowledge',
      // Required for Build Agent tool runtime (Org Intelligence / CI/CD actions).
      'AgentFramework'
    };
  }

  /**
   * Ensure an existing Builder workspace has AgentFramework + knowledge caps.
   * Non-fatal on failure — older workspaces may lack Org Intelligence tools without this.
   */
  @TestVisible
  private static void ensureWorkspaceCapabilities(String organizationId, String workspaceId) {
    if (String.isBlank(organizationId) || String.isBlank(workspaceId) || isMockMode()) {
      return;
    }
    try {
      HttpResponse res = sendRequest(
        'PATCH',
        '/organizations/' + organizationId + '/workspaces/' + workspaceId,
        JSON.serialize(new Map<String, Object>{
          'capabilities' => builderWorkspaceCapabilities()
        })
      );
      // Soft-fail: capability patch is best-effort.
      if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
        System.debug(
          LoggingLevel.WARN,
          'Workspace capability patch failed (' + res.getStatusCode() + '): '
            + (res.getBody() != null ? res.getBody().left(300) : '')
        );
      }
    } catch (Exception ex) {
      System.debug(LoggingLevel.WARN, 'Workspace capability patch: ' + ex.getMessage());
    }
  }

  /**
   * Start a Copado Agent Worker session bound to a dialogue + integrations.
   * The Build Agent only gets live Org Intelligence tools when a worker is running.
   * OpenAPI: POST /organizations/{orgId}/agents
   *
   * Common failure: 403 {"detail":"Access to the 'build' agent is not allowed."}
   * That means the Personal Access Key user is not entitled to start the Build
   * agent worker via API (UI chat can still work for a different session/user).
   */
  public static Map<String, Object> startAgentWorker(
    String agent,
    String workspaceId,
    String dialogueId,
    Map<String, Object> integrations
  ) {
    Map<String, Object> started = tryStartAgentWorker(agent, workspaceId, dialogueId, integrations);
    if (started.containsKey('error')) {
      throw new ApiException(String.valueOf(started.get('error')));
    }
    return started;
  }

  /**
   * Best-effort agent worker start. Returns session fields on success, or
   * { error, statusCode, agentDenied } on failure (does not throw).
   */
  public static Map<String, Object> tryStartAgentWorker(
    String agent,
    String workspaceId,
    String dialogueId,
    Map<String, Object> integrations
  ) {
    Map<String, Object> out = new Map<String, Object>();
    if (isMockMode()) {
      out.put('session_id', 'mock-agent-session');
      out.put('agent_worker_url', 'mock://agent');
      out.put('session_auth_key', 'mock');
      return out;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    if (String.isBlank(agent)) {
      agent = ASSISTANT_BUILD;
    }
    Map<String, Object> body = new Map<String, Object>{
      'agent' => agent
    };
    if (String.isNotBlank(workspaceId)) {
      body.put('workspace_id', workspaceId);
    }
    if (String.isNotBlank(dialogueId)) {
      body.put('dialogue_id', dialogueId);
    }
    if (integrations != null && !integrations.isEmpty()) {
      body.put('integrations', integrations);
    }
    HttpResponse res = sendRequest(
      'POST',
      '/organizations/' + settings.organizationId + '/agents',
      JSON.serialize(body)
    );
    Integer code = res.getStatusCode();
    String resBody = res.getBody();
    if (code < 200 || code >= 300) {
      String snippet = String.isBlank(resBody)
        ? res.getStatus()
        : resBody.left(Math.min(400, resBody.length()));
      out.put('error', 'Start agent worker failed (' + code + '): ' + snippet);
      out.put('statusCode', code);
      out.put(
        'agentDenied',
        code == 403
          && String.isNotBlank(resBody)
          && resBody.toLowerCase().contains('not allowed')
      );
      return out;
    }
    if (String.isNotBlank(resBody)) {
      Object parsed = JSON.deserializeUntyped(resBody);
      if (parsed instanceof Map<String, Object>) {
        return (Map<String, Object>) parsed;
      }
    }
    return out;
  }

  /** GET /dialogues/{id}/agent-session — null when no worker is attached. */
  public static Map<String, Object> getAgentSession(String dialogueId) {
    if (isMockMode() || String.isBlank(dialogueId)) {
      return null;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    HttpResponse res = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId
        + '/dialogues/' + dialogueId + '/agent-session',
      null
    );
    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      return null;
    }
    if (String.isBlank(res.getBody())) {
      return null;
    }
    Object parsed = JSON.deserializeUntyped(res.getBody());
    return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
  }

  public static String explainBuildAgentDenied() {
    String features = null;
    try {
      Map<String, Object> org = readOrganization();
      if (org != null && org.get('feature_list') != null) {
        features = String.valueOf(org.get('feature_list'));
      }
    } catch (Exception ignore) {
    }
    String msg =
      'Copado AI rejected POST /organizations/{id}/agents for agent=build '
      + '(403: Access to the \'build\' agent is not allowed). '
      + 'Org Intelligence requires that agent worker (OpenAPI AgentWorkerCreate). '
      + 'Fix: Personal Access Key must belong to a user licensed for Build Agent; '
      + 'Organization Id in Copado Builder Settings must match that Copado AI org; '
      + 'workspace needs AgentFramework capability. '
      + 'UI Build Agent chat can work while this API call still returns 403.';
    if (String.isNotBlank(features)) {
      msg += ' Org feature_list=' + features.left(500) + '.';
    }
    return msg;
  }

  /**
   * GET /organizations/{organization_id}/ — includes feature_list (org entitlements).
   * OpenAPI: "feature_list is a comma separated list of features enabled for the organization"
   */
  public static Map<String, Object> readOrganization() {
    if (isMockMode()) {
      return new Map<String, Object>{
        'feature_list' => new List<Object>{ 'build', 'plan', 'knowledge' }
      };
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    HttpResponse res = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId + '/',
      null
    );
    assertOk(res, 'Read organization');
    if (String.isBlank(res.getBody())) {
      return new Map<String, Object>();
    }
    Object parsed = JSON.deserializeUntyped(res.getBody());
    return parsed instanceof Map<String, Object>
      ? (Map<String, Object>) parsed
      : new Map<String, Object>();
  }

  @TestVisible
  private static Boolean isSuccessfulOrgIntelligenceProbe(String answer) {
    if (String.isBlank(answer)) {
      return false;
    }
    String a = answer.toLowerCase();
    if (a.contains('org_intelligence_unavailable')) {
      return false;
    }
    if (a.contains('missing int_id') || a.contains('missing instance_url')) {
      return false;
    }
    if (
      a.contains('unable to query live')
      || a.contains('missing configuration')
      || a.contains('cannot currently browse')
      || a.contains('integration needs to be refreshed')
    ) {
      return false;
    }
    if (a.contains('could not parse') || a.contains('empty body') || a.contains('(empty body)')) {
      return false;
    }
    if (a.contains('still generating') || a.contains('stream body was empty')) {
      return false;
    }
    if (a.contains('probe chat failed')) {
      return false;
    }
    // Explicit denials from the model when tools are missing.
    if (
      a.contains('don\'t have a tool')
      || a.contains('do not have a tool')
      || a.contains('don\'t reach live')
      || a.contains('do not reach live')
      || a.contains('can\'t check that')
      || a.contains('cannot check that')
      || a.contains('still can\'t check')
      || a.contains('tools don\'t reach')
      || a.contains('no way to confirm')
    ) {
      return false;
    }
    return true;
  }

  @TestVisible
  private static List<Map<String, Object>> orgIntelligencePayloads(
    String integrationId,
    String orgCredentialId,
    String orgName,
    String salesforceIntegrationId
  ) {
    List<Map<String, Object>> payloads = new List<Map<String, Object>>();
    // Match Copado AI native chat first: integrations.copado_cicd = "<uuid>".
    // Fat objects (int_id / credentialId) can break Org Intelligence tools.
    if (String.isNotBlank(integrationId)) {
      payloads.add(new Map<String, Object>{
        'copado_cicd' => integrationId
      });
      payloads.add(new Map<String, Object>{
        'copado_cicd' => new Map<String, Object>{
          'id' => integrationId
        }
      });
      if (String.isNotBlank(orgCredentialId)) {
        payloads.add(new Map<String, Object>{
          'copado_cicd' => new Map<String, Object>{
            'id' => integrationId,
            'credentialId' => orgCredentialId,
            'name' => blankTo(orgName, orgCredentialId)
          }
        });
        payloads.add(new Map<String, Object>{
          'copado_cicd' => new Map<String, Object>{
            'id' => integrationId,
            'credential' => new Map<String, Object>{
              'id' => orgCredentialId,
              'name' => blankTo(orgName, orgCredentialId)
            }
          }
        });
      }
    }
    if (String.isNotBlank(salesforceIntegrationId)) {
      payloads.add(new Map<String, Object>{
        'salesforce' => salesforceIntegrationId
      });
      payloads.add(new Map<String, Object>{
        'salesforce' => new Map<String, Object>{ 'id' => salesforceIntegrationId }
      });
    }
    return payloads;
  }

  /**
   * Combined integrations payload for chat/agent worker (CI/CD + optional Salesforce).
   * Prefer the native Copado AI shape: type key → integration UUID string.
   */
  public static Map<String, Object> buildIntegrationsPayload(
    String cicdIntegrationId,
    String salesforceIntegrationId,
    String orgCredentialId,
    String orgName
  ) {
    Map<String, Object> payload = new Map<String, Object>();
    if (String.isNotBlank(cicdIntegrationId)) {
      payload.put('copado_cicd', cicdIntegrationId);
    }
    if (String.isNotBlank(salesforceIntegrationId)) {
      payload.put('salesforce', salesforceIntegrationId);
    }
    return payload;
  }

  /**
   * Resolve CI/CD integration binding for a chat turn.
   * Use the existing User Level / copado_cicd connection only — do NOT attach
   * Salesforce-type integrations (expired Builder SF causes Missing instance_url).
   * Shape matches Copado AI native chat: { "copado_cicd": "<uuid>" }.
   */
  public static Map<String, Object> resolveIntegrationsForChat(
    String cicdIntegrationId,
    String orgCredentialId,
    String orgName,
    String workspaceId
  ) {
    if (String.isBlank(cicdIntegrationId) && String.isBlank(orgCredentialId)) {
      return new Map<String, Object>();
    }
    return buildIntegrationsPayload(
      cicdIntegrationId,
      null,
      orgCredentialId,
      orgName
    );
  }

  public static DialogueResult createDialogue(String workspaceId, String name) {
    if (isMockMode()) {
      return mockCreateDialogue(workspaceId, name);
    }
    Settings settings = getSettings();
    requireOrgId(settings);

    Map<String, Object> body = new Map<String, Object>{
      'name' => String.isBlank(name) ? 'Builder Chat' : name,
      'workspaceId' => workspaceId,
      // Dialogue shell uses knowledge; each message sets assistantId (build/plan/…).
      'assistantId' => ASSISTANT_KNOWLEDGE
    };
    HttpResponse res = sendRequest(
      'POST',
      '/organizations/' + settings.organizationId + '/dialogues',
      JSON.serialize(body)
    );
    assertOk(res, 'Create dialogue');
    Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    DialogueResult result = new DialogueResult();
    result.dialogueId = String.valueOf(data.get('id'));
    result.message = 'What are you trying to fix or build? Describe the problem, feature, or paste a transcript.';
    result.status = 'active';
    return result;
  }

  /**
   * Delete a Copado AI dialogue. Best-effort — 404 means already gone.
   */
  public static void deleteDialogue(String dialogueId) {
    if (isMockMode() || String.isBlank(dialogueId)) {
      return;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    HttpResponse res = sendRequest(
      'DELETE',
      '/organizations/' + settings.organizationId + '/dialogues/' + dialogueId,
      null
    );
    Integer code = res.getStatusCode();
    // 404 = already deleted in Copado AI; treat as success.
    if (code == 404) {
      return;
    }
    assertOk(res, 'Delete dialogue');
  }

  public static DialogueResult sendDialogueMessage(String dialogueId, String message) {
    return sendDialogueMessage(dialogueId, message, null, null);
  }

  public static DialogueResult sendDialogueMessage(
    String dialogueId,
    String message,
    Map<String, Object> integrations
  ) {
    return sendDialogueMessage(dialogueId, message, integrations, null);
  }

  public static DialogueResult sendDialogueMessage(
    String dialogueId,
    String message,
    Map<String, Object> integrations,
    String assistantId
  ) {
    return sendDialogueMessage(dialogueId, message, integrations, assistantId, null);
  }

  /**
   * @param workspaceIdIfStale when the stored dialogue was deleted in Copado AI (404),
   *        recreate a dialogue in this workspace and retry once.
   */
  public static DialogueResult sendDialogueMessage(
    String dialogueId,
    String message,
    Map<String, Object> integrations,
    String assistantId,
    String workspaceIdIfStale
  ) {
    return sendDialogueMessage(
      dialogueId,
      message,
      integrations,
      assistantId,
      workspaceIdIfStale,
      null
    );
  }

  /**
   * @param systemPromptOverride when set, replaces the default Builder chat system prompt
   *        (used for package JSON generation so the model does not ask questions).
   */
  public static DialogueResult sendDialogueMessage(
    String dialogueId,
    String message,
    Map<String, Object> integrations,
    String assistantId,
    String workspaceIdIfStale,
    String systemPromptOverride
  ) {
    String resolvedAssistant = String.isNotBlank(assistantId)
      ? assistantId
      : routeAssistant(message);
    if (integrations != null && !integrations.isEmpty()) {
      resolvedAssistant = ASSISTANT_BUILD;
    }
    if (isMockMode()) {
      DialogueResult mock = mockSendDialogueMessage(dialogueId, message);
      mock.assistantId = resolvedAssistant;
      mock.requestId = newRequestId();
      mock.pending = false;
      return mock;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    if (String.isBlank(dialogueId) && String.isBlank(workspaceIdIfStale)) {
      throw new ApiException('Dialogue ID is required for live Copado AI chat.');
    }
    if (String.isBlank(dialogueId) && String.isNotBlank(workspaceIdIfStale)) {
      dialogueId = createDialogue(workspaceIdIfStale, 'Builder Chat').dialogueId;
    }

    // Snapshot before POST so empty-body polling picks up the new assistant turn only.
    DialogueSnapshot before = readDialogueSnapshot(settings.organizationId, dialogueId);

    String requestId = newRequestId();
    Map<String, Object> body = new Map<String, Object>{
      'request_id' => requestId,
      'prompt' => message,
      'assistantId' => resolvedAssistant
    };
    // OpenAPI MessageCreate. Never attach integrations here — an active Copado
    // connection is already known server-side. Always send a normal chat body.
    body.put(
      'system_prompt',
      String.isNotBlank(systemPromptOverride) ? systemPromptOverride : BUILDER_SYSTEM_PROMPT
    );

    HttpResponse res;
    try {
      res = sendMessageRequest(
        settings.organizationId,
        dialogueId,
        JSON.serialize(body),
        false
      );
    } catch (System.CalloutException cex) {
      // POST held open while Copado/OI generated — treat as accepted and poll from LWC.
      DialogueResult pendingOnTimeout = new DialogueResult();
      pendingOnTimeout.dialogueId = dialogueId;
      pendingOnTimeout.assistantId = resolvedAssistant;
      pendingOnTimeout.requestId = requestId;
      pendingOnTimeout.pending = true;
      pendingOnTimeout.message = '';
      pendingOnTimeout.status = 'active';
      pendingOnTimeout.baselineMessageCount = before != null ? before.messageCount : null;
      pendingOnTimeout.baselineAssistantText = before != null ? before.lastAssistantText : null;
      return pendingOnTimeout;
    }

    // Stale dialogue deleted in Copado AI → one recreate + retry.
    if (isDialogueNotFound(res) && String.isNotBlank(workspaceIdIfStale)) {
      dialogueId = createDialogue(workspaceIdIfStale, 'Builder Chat').dialogueId;
      before = new DialogueSnapshot();
      before.messageCount = 0;
      before.lastAssistantText = null;
      requestId = newRequestId();
      body.put('request_id', requestId);
      try {
        res = sendMessageRequest(
          settings.organizationId,
          dialogueId,
          JSON.serialize(body),
          false
        );
      } catch (System.CalloutException cex) {
        DialogueResult pendingOnTimeout = new DialogueResult();
        pendingOnTimeout.dialogueId = dialogueId;
        pendingOnTimeout.assistantId = resolvedAssistant;
        pendingOnTimeout.requestId = requestId;
        pendingOnTimeout.pending = true;
        pendingOnTimeout.message = '';
        pendingOnTimeout.status = 'active';
        pendingOnTimeout.baselineMessageCount = 0;
        pendingOnTimeout.baselineAssistantText = null;
        return pendingOnTimeout;
      }
    }
    if (
      res.getStatusCode() == 403
      && resolvedAssistant != ASSISTANT_BUILD
      && (res.getBody() == null || res.getBody().toLowerCase().contains('no access'))
    ) {
      resolvedAssistant = ASSISTANT_BUILD;
      body.put('assistantId', resolvedAssistant);
      try {
        res = sendMessageRequest(
          settings.organizationId,
          dialogueId,
          JSON.serialize(body),
          false
        );
      } catch (System.CalloutException cex) {
        DialogueResult pendingOnTimeout = new DialogueResult();
        pendingOnTimeout.dialogueId = dialogueId;
        pendingOnTimeout.assistantId = resolvedAssistant;
        pendingOnTimeout.requestId = requestId;
        pendingOnTimeout.pending = true;
        pendingOnTimeout.message = '';
        pendingOnTimeout.status = 'active';
        pendingOnTimeout.baselineMessageCount = before != null ? before.messageCount : null;
        pendingOnTimeout.baselineAssistantText = before != null ? before.lastAssistantText : null;
        return pendingOnTimeout;
      }
    }
    assertOk(res, 'Send dialogue message');

    DialogueResult result = new DialogueResult();
    result.dialogueId = dialogueId;
    result.assistantId = resolvedAssistant;
    result.requestId = requestId;
    result.pending = false;
    result.message = parseStreamedMessage(res.getBody());

    // Package builds: short first-pass poll — LWC pollBuildPackage + nudge handles the rest.
    // Burning 20 GETs here often hit Apex time limits and left Build soft-pending forever.
    Integer pollAttempts = String.isNotBlank(systemPromptOverride) ? 8 : 6;
    if (String.isBlank(result.message)) {
      result.message = waitForAssistantReply(
        settings.organizationId,
        dialogueId,
        requestId,
        pollAttempts,
        before
      );
    }

    result.status = 'active';
    if (String.isBlank(result.message)) {
      result.pending = true;
      result.message = '';
      result.baselineMessageCount = before != null ? before.messageCount : null;
      result.baselineAssistantText = before != null ? before.lastAssistantText : null;
    }
    return result;
  }

  @TestVisible
  private static Boolean isDialogueNotFound(HttpResponse res) {
    if (res == null || res.getStatusCode() != 404) {
      return false;
    }
    String body = res.getBody();
    if (String.isBlank(body)) {
      return true;
    }
    String lower = body.toLowerCase();
    return lower.contains('dialogue not found') || lower.contains('not found');
  }

  /**
   * Public poll helper for LWC: read latest assistant text from a dialogue.
   */
  public static String pollAssistantText(
    String dialogueId,
    String requestId,
    Integer baselineMessageCount,
    String baselineAssistantText
  ) {
    if (isMockMode()) {
      return 'Mock assistant reply for ' + blankTo(requestId, 'request');
    }
    if (String.isBlank(dialogueId)) {
      return null;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    DialogueSnapshot before = null;
    if (baselineMessageCount != null || String.isNotBlank(baselineAssistantText)) {
      before = new DialogueSnapshot();
      before.messageCount = baselineMessageCount == null ? 0 : baselineMessageCount;
      before.lastAssistantText = baselineAssistantText;
    }
    return fetchLatestAssistantMessage(
      settings.organizationId,
      dialogueId,
      requestId,
      before
    );
  }

  /** Back-compat overload. */
  public static String pollAssistantText(String dialogueId, String requestId) {
    return pollAssistantText(dialogueId, requestId, null, null);
  }

  /**
   * Message POST. Prefer application/json so the gateway can return a buffered
   * body; Apex Named Credentials often drop NDJSON/event-stream bodies as empty.
   */
  @TestVisible
  private static HttpResponse sendMessageRequest(
    String organizationId,
    String dialogueId,
    String body
  ) {
    return sendMessageRequest(organizationId, dialogueId, body, false);
  }

  @TestVisible
  private static HttpResponse sendMessageRequest(
    String organizationId,
    String dialogueId,
    String body,
    Boolean orgIntelligence
  ) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint(
      calloutUrl(
        '/organizations/' + organizationId
          + '/dialogues/' + dialogueId + '/messages'
      )
    );
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    // Normal chat: JSON only so Apex gets a body quickly (Hello must not hang).
    // OI turns: allow streams; LWC polls if the body is empty.
    if (orgIntelligence == true) {
      req.setHeader('Accept', 'application/json, application/x-ndjson, text/event-stream, */*');
      req.setTimeout(120000);
    } else {
      req.setHeader('Accept', 'application/json');
      req.setTimeout(45000);
    }
    applyCopadoAiAuthHeaders(req);
    req.setHeader('x-client', 'copado-builder');
    if (String.isNotBlank(body)) {
      req.setBody(body);
    }
    return new Http().send(req);
  }

  /**
   * Poll GET /dialogues/{id} until an assistant message for requestId appears
   * (or any new assistant text message if requestId match is missing).
   * Uses callout latency as the wait — no CPU busy-spin.
   */
  @TestVisible
  private static String waitForAssistantReply(
    String organizationId,
    String dialogueId,
    String requestId,
    Integer maxAttempts,
    DialogueSnapshot before
  ) {
    Integer attempts = maxAttempts == null || maxAttempts < 1 ? 8 : maxAttempts;
    String lastSeen = null;
    for (Integer i = 0; i < attempts; i++) {
      String reply = fetchLatestAssistantMessage(
        organizationId,
        dialogueId,
        requestId,
        before
      );
      if (String.isNotBlank(reply)) {
        return reply;
      }
      lastSeen = reply;
    }
    return lastSeen;
  }

  private class DialogueSnapshot {
    Integer messageCount;
    String lastAssistantText;
  }

  @TestVisible
  private static DialogueSnapshot readDialogueSnapshot(
    String organizationId,
    String dialogueId
  ) {
    DialogueSnapshot snap = new DialogueSnapshot();
    snap.messageCount = 0;
    snap.lastAssistantText = null;
    try {
      HttpResponse res = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/dialogues/' + dialogueId,
        null
      );
      if (res.getStatusCode() < 200 || res.getStatusCode() >= 300 || String.isBlank(res.getBody())) {
        return snap;
      }
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
      List<Object> messages = asObjectList(data.get('messages'));
      if (messages == null) {
        messages = asObjectList(data.get('Messages'));
      }
      if (messages == null) {
        return snap;
      }
      snap.messageCount = messages.size();
      for (Integer i = messages.size() - 1; i >= 0; i--) {
        String content = usableAssistantContent(messages[i]);
        if (String.isNotBlank(content)) {
          snap.lastAssistantText = content;
          break;
        }
      }
    } catch (Exception ignore) {
    }
    return snap;
  }

  @TestVisible
  private static String fetchLatestAssistantMessage(
    String organizationId,
    String dialogueId,
    String requestId,
    DialogueSnapshot before
  ) {
    try {
      HttpResponse res = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/dialogues/' + dialogueId,
        null,
        15000
      );
      if (res.getStatusCode() < 200 || res.getStatusCode() >= 300 || String.isBlank(res.getBody())) {
        return null;
      }
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
      List<Object> messages = asObjectList(data.get('messages'));
      if (messages == null) {
        messages = asObjectList(data.get('Messages'));
      }
      if (messages == null || messages.isEmpty()) {
        return null;
      }

      // 1) Exact assistant row for this requestId
      for (Integer i = messages.size() - 1; i >= 0; i--) {
        String content = usableAssistantContent(messages[i]);
        if (String.isBlank(content)) {
          continue;
        }
        Map<String, Object> msg = (Map<String, Object>) messages[i];
        String msgReq = firstJsonString(msg, new List<String>{ 'requestId', 'request_id' });
        if (String.isNotBlank(requestId) && requestId.equals(msgReq)) {
          return content;
        }
      }

      // 2) Assistant rows after the user turn that used this requestId
      if (String.isNotBlank(requestId)) {
        Integer userIdx = -1;
        for (Integer i = 0; i < messages.size(); i++) {
          if (!(messages[i] instanceof Map<String, Object>)) {
            continue;
          }
          Map<String, Object> msg = (Map<String, Object>) messages[i];
          String role = msg.containsKey('role') ? String.valueOf(msg.get('role')) : '';
          String msgReq = firstJsonString(msg, new List<String>{ 'requestId', 'request_id' });
          if (
            requestId.equals(msgReq)
            && ('user'.equalsIgnoreCase(role) || 'human'.equalsIgnoreCase(role))
          ) {
            userIdx = i;
          }
        }
        if (userIdx >= 0) {
          for (Integer i = messages.size() - 1; i > userIdx; i--) {
            String content = usableAssistantContent(messages[i]);
            if (String.isNotBlank(content)) {
              return content;
            }
          }
          return null; // user turn seen, reply not ready yet
        }
      }

      // 3) Fallback: newest usable assistant text.
      // When before-snapshot is null (simple chat path), allow latest reply so
      // empty-stream turns still surface an answer.
      String latest = null;
      for (Integer i = messages.size() - 1; i >= 0; i--) {
        String content = usableAssistantContent(messages[i]);
        if (String.isNotBlank(content)) {
          latest = content;
          break;
        }
      }
      if (String.isBlank(latest)) {
        return null;
      }
      if (before != null) {
        if (
          before.messageCount != null
          && messages.size() <= before.messageCount
          && latest.equals(before.lastAssistantText)
        ) {
          return null;
        }
        if (
          String.isNotBlank(before.lastAssistantText)
          && latest.equals(before.lastAssistantText)
          && (before.messageCount == null || messages.size() <= before.messageCount)
        ) {
          return null;
        }
      }
      return latest;
    } catch (Exception ignore) {
      return null;
    }
  }

  @TestVisible
  private static String usableAssistantContent(Object messageObj) {
    if (!(messageObj instanceof Map<String, Object>)) {
      return null;
    }
    Map<String, Object> msg = (Map<String, Object>) messageObj;
    String role = msg.containsKey('role') ? String.valueOf(msg.get('role')) : '';
    if (!'assistant'.equalsIgnoreCase(role) && !'ai'.equalsIgnoreCase(role)) {
      return null;
    }
    String content = extractMessageContent(msg, true);
    if (String.isBlank(content)) {
      content = extractMessageContent(msg, false);
    }
    if (String.isBlank(content) || isNoiseContent(content) || isUnusableAssistantText(content)) {
      return null;
    }
    return content;
  }

  @TestVisible
  private static List<Object> asObjectList(Object value) {
    return value instanceof List<Object> ? (List<Object>) value : null;
  }

  /** Builder / stream errors that must not be treated as a real agent answer. */
  @TestVisible
  private static Boolean isUnusableAssistantText(String value) {
    if (String.isBlank(value)) {
      return true;
    }
    String a = value.toLowerCase();
    return a.contains('could not parse the assistant text')
      || a.contains('stream body was empty')
      || a.contains('raw preview: (empty body)')
      || a.contains('org_intelligence_unavailable')
      || a.contains('still generating (empty body)');
  }

  @TestVisible
  private static String extractMessageContent(Map<String, Object> msg) {
    return extractMessageContent(msg, false);
  }

  @TestVisible
  private static String extractMessageContent(Map<String, Object> msg, Boolean textPartsOnly) {
    if (msg == null) {
      return null;
    }
    Object content = msg.get('content');
    if (content == null) {
      content = msg.get('message');
    }
    if (content == null && msg.get('parts') != null) {
      content = msg.get('parts');
    }
    if (content instanceof String) {
      return (String) content;
    }
    if (content instanceof Map<String, Object>) {
      Map<String, Object> contentMap = (Map<String, Object>) content;
      String nested = firstJsonString(contentMap, new List<String>{ 'text', 'content', 'message', 'output' });
      if (String.isNotBlank(nested)) {
        return nested;
      }
    }
    if (content instanceof List<Object>) {
      List<String> textParts = new List<String>();
      List<String> otherParts = new List<String>();
      for (Object partObj : (List<Object>) content) {
        if (partObj instanceof String) {
          textParts.add((String) partObj);
          continue;
        }
        if (!(partObj instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> part = (Map<String, Object>) partObj;
        String partType = part.containsKey('type')
          ? String.valueOf(part.get('type')).toLowerCase()
          : '';
        String text = firstJsonString(part, new List<String>{
          'text', 'content', 'output'
        });
        if (String.isBlank(text)) {
          continue;
        }
        if (String.isBlank(partType) || partType == 'text') {
          textParts.add(text);
        } else if (partType != 'tool_use' && partType != 'thinking') {
          otherParts.add(text);
        }
      }
      if (!textParts.isEmpty()) {
        return String.join(textParts, '');
      }
      if (textPartsOnly == true) {
        return null; // still generating (tools/thinking only)
      }
      return otherParts.isEmpty() ? null : String.join(otherParts, '');
    }
    return content != null ? String.valueOf(content) : null;
  }

  /**
   * Lightweight check: is a copado_cicd integration connected for this workspace + credential?
   * Does not create integrations or run a Build Agent probe.
   */
  public static WorkspaceOrgIntelligenceStatus resolveWorkspaceOrgIntelligence(
    String workspaceId,
    String orgCredentialId
  ) {
    WorkspaceOrgIntelligenceStatus result = new WorkspaceOrgIntelligenceStatus();
    result.connected = false;
    result.status = 'Not connected';

    if (String.isBlank(orgCredentialId)) {
      return result;
    }

    if (isMockMode()) {
      result.connected = true;
      result.status = 'connected';
      result.integrationId = 'mock-cicd-' + orgCredentialId;
      return result;
    }

    if (String.isBlank(workspaceId)) {
      return result;
    }

    Settings settings = getSettings();
    requireOrgId(settings);

    HttpResponse listRes = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId + '/integrations',
      null
    );
    assertOk(listRes, 'List integrations');

    OrgIntelligenceResult scratch = new OrgIntelligenceResult();
    List<Map<String, Object>> cicdCandidates = listCicdIntegrations(
      listRes.getBody(),
      workspaceId,
      orgCredentialId
    );
    for (Map<String, Object> candidate : cicdCandidates) {
      String candidateId = firstJsonString(candidate, new List<String>{ 'id' });
      if (String.isBlank(candidateId)) {
        continue;
      }
      String st = checkIntegrationStatus(settings.organizationId, candidateId, scratch);
      if ('connected'.equalsIgnoreCase(st)) {
        result.connected = true;
        result.status = 'connected';
        result.integrationId = candidateId;
        return result;
      }
    }
    return result;
  }


  /**
   * List Copado (copado_cicd) integrations so the user can pick which connection
   * Org Intelligence should update (e.g. "User Level" or a custom-named one).
   */
  public static List<IntegrationInfo> listActiveCopadoIntegrations(String workspaceId) {
    List<IntegrationInfo> out = new List<IntegrationInfo>();
    CurrentUserMatchHints hints = loadCurrentUserMatchHints();
    if (isMockMode()) {
      IntegrationInfo userLevel = new IntegrationInfo();
      userLevel.id = 'mock-user-level';
      userLevel.name = 'User Level';
      userLevel.type = 'copado_cicd';
      userLevel.level = 'USER';
      userLevel.status = 'connected';
      userLevel.connected = true;
      userLevel.label = 'User Level · Connected';
      applyUserMatchScore(userLevel, hints);
      out.add(userLevel);
      IntegrationInfo personal = new IntegrationInfo();
      personal.id = 'mock-personal-cicd';
      String personalName = 'User Level — '
        + (String.isNotBlank(hints.fullName) ? hints.fullName : 'Demo User');
      personal.name = personalName;
      personal.type = 'copado_cicd';
      personal.level = 'USER';
      personal.status = 'connected';
      personal.connected = true;
      personal.label = personalName + ' · Connected';
      applyUserMatchScore(personal, hints);
      out.add(personal);
      IntegrationInfo custom = new IntegrationInfo();
      custom.id = 'mock-custom-cicd';
      custom.name = 'My Team Copado';
      custom.type = 'copado_cicd';
      custom.level = 'USER';
      custom.status = 'connected';
      custom.connected = true;
      custom.label = 'My Team Copado · Connected';
      applyUserMatchScore(custom, hints);
      out.add(custom);
      out.sort();
      return out;
    }

    Settings settings = getSettings();
    requireOrgId(settings);
    HttpResponse listRes = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId + '/integrations',
      null
    );
    assertOk(listRes, 'List integrations');

    List<Map<String, Object>> cicdCandidates = listCicdIntegrations(
      listRes.getBody(),
      workspaceId,
      null
    );
    // If type filter matched nothing, still show raw integrations so setup isn't empty.
    if (cicdCandidates.isEmpty()) {
      cicdCandidates = listAllIntegrationsLoose(listRes.getBody());
    }
    OrgIntelligenceResult scratch = new OrgIntelligenceResult();
    Integer checked = 0;
    for (Map<String, Object> row : cicdCandidates) {
      if (checked >= 25) {
        break;
      }
      String id = firstJsonString(row, new List<String>{ 'id' });
      if (String.isBlank(id)) {
        continue;
      }
      checked++;
      IntegrationInfo info = new IntegrationInfo();
      info.id = id;
      info.name = blankTo(firstJsonString(row, new List<String>{ 'name' }), id);
      info.type = blankTo(
        firstJsonString(row, new List<String>{ 'type' }),
        'copado_cicd'
      );
      info.level = blankTo(firstJsonString(row, new List<String>{ 'level' }), '');
      try {
        info.status = checkIntegrationStatus(settings.organizationId, id, scratch);
      } catch (Exception statusEx) {
        info.status = 'unknown';
      }
      info.connected = 'connected'.equalsIgnoreCase(info.status);
      String scope = String.isNotBlank(info.level) ? info.level : 'All Workspaces';
      info.label = info.name + ' · ' + (info.connected ? 'Connected' : blankTo(info.status, 'Unknown'))
        + ' · ' + scope;
      applyUserMatchScore(info, hints);
      out.add(info);
    }
    // Personal match first, then connected, then name
    out.sort();
    return out;
  }

  /** Unfiltered integration rows from list API (setup fallback when cicd filter is empty). */
  @TestVisible
  private static List<Map<String, Object>> listAllIntegrationsLoose(String listBody) {
    List<Map<String, Object>> out = new List<Map<String, Object>>();
    if (String.isBlank(listBody)) {
      return out;
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(listBody);
    } catch (Exception ex) {
      return out;
    }
    List<Object> items = new List<Object>();
    if (parsed instanceof List<Object>) {
      items = (List<Object>) parsed;
    } else if (parsed instanceof Map<String, Object>) {
      Map<String, Object> wrap = (Map<String, Object>) parsed;
      if (wrap.get('items') instanceof List<Object>) {
        items = (List<Object>) wrap.get('items');
      } else if (wrap.get('integrations') instanceof List<Object>) {
        items = (List<Object>) wrap.get('integrations');
      } else if (wrap.get('data') instanceof List<Object>) {
        items = (List<Object>) wrap.get('data');
      }
    }
    for (Object item : items) {
      if (item instanceof Map<String, Object>) {
        out.add((Map<String, Object>) item);
      }
    }
    return out;
  }

  /**
   * Pick the best Copado AI cicd integration for the running Salesforce user.
   * Prefers name/email match over the shared generic "User Level".
   */
  public static IntegrationInfo pickBestIntegrationForCurrentUser(
    List<IntegrationInfo> rows,
    String preferredIntegrationId
  ) {
    if (rows == null || rows.isEmpty()) {
      return null;
    }
    IntegrationInfo preferred = null;
    if (String.isNotBlank(preferredIntegrationId)) {
      for (IntegrationInfo row : rows) {
        if (preferredIntegrationId.equals(row.id)) {
          preferred = row;
          break;
        }
      }
    }
    IntegrationInfo bestPersonalConnected = null;
    IntegrationInfo bestPersonalAny = null;
    IntegrationInfo genericUserLevel = null;
    IntegrationInfo anyConnected = null;
    for (IntegrationInfo row : rows) {
      Integer score = row.matchScore == null ? 0 : row.matchScore;
      Boolean personal = row.matchedToCurrentUser == true || score >= 70;
      if (personal) {
        if (row.connected == true) {
          if (
            bestPersonalConnected == null
            || score > (bestPersonalConnected.matchScore == null ? 0 : bestPersonalConnected.matchScore)
          ) {
            bestPersonalConnected = row;
          }
        }
        if (
          bestPersonalAny == null
          || score > (bestPersonalAny.matchScore == null ? 0 : bestPersonalAny.matchScore)
        ) {
          bestPersonalAny = row;
        }
      }
      if (
        row.name != null
        && row.name.trim().equalsIgnoreCase('user level')
        && genericUserLevel == null
      ) {
        genericUserLevel = row;
      }
      if (row.connected == true && anyConnected == null) {
        anyConnected = row;
      }
    }

    // Keep an explicit personal/session pick; upgrade a stale generic "User Level"
    // session id when a personal match exists.
    if (preferred != null) {
      Boolean preferredIsGeneric =
        preferred.name != null && preferred.name.trim().equalsIgnoreCase('user level');
      if (!preferredIsGeneric || bestPersonalConnected == null) {
        return preferred;
      }
      return bestPersonalConnected;
    }
    if (bestPersonalConnected != null) {
      return bestPersonalConnected;
    }
    if (bestPersonalAny != null) {
      return bestPersonalAny;
    }
    if (genericUserLevel != null && genericUserLevel.connected == true) {
      return genericUserLevel;
    }
    if (anyConnected != null) {
      return anyConnected;
    }
    return rows[0];
  }

  private class CurrentUserMatchHints {
    String fullName;
    String firstName;
    String lastName;
    String email;
    String emailLocal;
    String usernameLocal;
    String nickname;
    String alias;
    List<String> strongTokens = new List<String>();
  }

  @TestVisible
  private static CurrentUserMatchHints loadCurrentUserMatchHints() {
    CurrentUserMatchHints hints = new CurrentUserMatchHints();
    try {
      User u = [
        SELECT Name, FirstName, LastName, Email, Username, CommunityNickname, Alias
        FROM User
        WHERE Id = :UserInfo.getUserId()
        LIMIT 1
      ];
      hints.fullName = blankTo(u.Name, UserInfo.getName());
      hints.firstName = blankTo(u.FirstName, UserInfo.getFirstName());
      hints.lastName = blankTo(u.LastName, UserInfo.getLastName());
      hints.email = blankTo(u.Email, UserInfo.getUserEmail());
      hints.nickname = u.CommunityNickname;
      hints.alias = u.Alias;
      hints.emailLocal = localPart(hints.email);
      hints.usernameLocal = localPart(blankTo(u.Username, UserInfo.getUserName()));
    } catch (Exception ignore) {
      hints.fullName = UserInfo.getName();
      hints.firstName = UserInfo.getFirstName();
      hints.lastName = UserInfo.getLastName();
      hints.email = UserInfo.getUserEmail();
      hints.emailLocal = localPart(hints.email);
      hints.usernameLocal = localPart(UserInfo.getUserName());
    }
    addStrongToken(hints, hints.email);
    addStrongToken(hints, hints.emailLocal);
    addStrongToken(hints, hints.usernameLocal);
    addStrongToken(hints, hints.fullName);
    if (String.isNotBlank(hints.firstName) && String.isNotBlank(hints.lastName)) {
      addStrongToken(hints, hints.firstName + ' ' + hints.lastName);
      addStrongToken(hints, hints.lastName + ', ' + hints.firstName);
      addStrongToken(hints, hints.lastName + ' ' + hints.firstName);
      addStrongToken(hints, hints.firstName + '.' + hints.lastName);
      addStrongToken(hints, hints.firstName + '-' + hints.lastName);
      addStrongToken(hints, hints.firstName + hints.lastName);
    }
    addStrongToken(hints, hints.nickname);
    if (String.isNotBlank(hints.alias) && hints.alias.length() >= 3) {
      addStrongToken(hints, hints.alias);
    }
    if (String.isNotBlank(hints.lastName) && hints.lastName.length() >= 3) {
      addStrongToken(hints, hints.lastName);
    }
    return hints;
  }

  private static void addStrongToken(CurrentUserMatchHints hints, String raw) {
    String n = normalizeMatchToken(raw);
    if (String.isBlank(n) || n.length() < 2) {
      return;
    }
    if (!hints.strongTokens.contains(n)) {
      hints.strongTokens.add(n);
    }
  }

  private static String localPart(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    Integer at = value.indexOf('@');
    return at > 0 ? value.substring(0, at) : value;
  }

  @TestVisible
  private static String normalizeMatchToken(String raw) {
    if (String.isBlank(raw)) {
      return '';
    }
    String s = raw.toLowerCase().trim();
    s = s.replace('—', ' ').replace('–', ' ').replace('_', ' ').replace('.', ' ').replace('-', ' ');
    while (s.contains('  ')) {
      s = s.replace('  ', ' ');
    }
    return s.trim();
  }

  @TestVisible
  private static void applyUserMatchScore(IntegrationInfo info, CurrentUserMatchHints hints) {
    if (info == null) {
      return;
    }
    Integer score = scoreIntegrationNameForUser(info.name, hints);
    info.matchScore = score;
    info.matchedToCurrentUser = score >= 70;
    if (info.matchedToCurrentUser == true && String.isNotBlank(info.label)) {
      info.label = info.label + ' · You';
    }
  }

  /**
   * Score how well an integration name matches the running Salesforce user.
   * 100 email/username, 90 full name, 80 first+last, 70 last/nickname, 1 generic User Level.
   */
  @TestVisible
  private static Integer scoreIntegrationNameForUser(
    String integrationName,
    CurrentUserMatchHints hints
  ) {
    if (String.isBlank(integrationName) || hints == null) {
      return 0;
    }
    String hay = normalizeMatchToken(integrationName);
    if (String.isBlank(hay)) {
      return 0;
    }
    if (hay == 'user level' || hay == 'userlevel') {
      return 1;
    }
    Integer best = 0;
    for (String token : hints.strongTokens) {
      if (String.isBlank(token) || !hay.contains(token)) {
        continue;
      }
      Integer score = 70;
      if (token.equals(normalizeMatchToken(hints.email))
        || token.equals(normalizeMatchToken(hints.emailLocal))
        || token.equals(normalizeMatchToken(hints.usernameLocal))) {
        score = 100;
      } else if (token.equals(normalizeMatchToken(hints.fullName))) {
        score = 90;
      } else if (
        String.isNotBlank(hints.firstName)
        && String.isNotBlank(hints.lastName)
        && (
          token.equals(normalizeMatchToken(hints.firstName + ' ' + hints.lastName))
          || token.equals(normalizeMatchToken(hints.lastName + ' ' + hints.firstName))
          || token.equals(normalizeMatchToken(hints.lastName + ', ' + hints.firstName))
        )
      ) {
        score = 80;
      } else if (token.equals(normalizeMatchToken(hints.firstName)) && token.length() >= 3) {
        // First name alone is weak — only count when integration also looks personal.
        score = hay.contains('user level') || hay.contains('userlevel') ? 60 : 40;
      }
      if (score > best) {
        best = score;
      }
    }
    return best;
  }

  /**
   * Discover / bind Copado Org Intelligence for a selected Dev Org Credential,
   * then ask a live smoke-test question against that org.
   *
   * Flow:
   *  1. Check for an existing connected copado_cicd integration (prefer "User Level")
   *  2. Reuse it — do NOT create a new integration when one already exists
   *  3. Update that integration's credential/config to the selected Dev environment
   *  4. Probe with cicd-only payload (never attach expired Salesforce integrations)
   */
  public static OrgIntelligenceResult ensureOrgIntelligence(
    String workspaceId,
    String orgCredentialId,
    String orgName,
    String dialogueId,
    Boolean askProbeQuestion,
    String preferredIntegrationId
  ) {
    OrgIntelligenceResult out = new OrgIntelligenceResult();
    out.orgCredentialId = orgCredentialId;
    out.orgName = orgName;
    out.workspaceId = workspaceId;
    out.needsSalesforceAuth = false;
    out.salesforceIntegrationId = null;

    if (String.isBlank(orgCredentialId)) {
      out.success = false;
      out.status = 'Missing org';
      out.message = 'Select a Dev environment (Org Credential) first.';
      return out;
    }

    if (isMockMode()) {
      out.success = true;
      out.status = 'connected';
      out.credentialBound = true;
      out.integrationId = String.isNotBlank(preferredIntegrationId)
        ? preferredIntegrationId
        : 'mock-cicd-' + orgCredentialId;
      out.message = 'Mock Org Intelligence connected for ' + blankTo(orgName, orgCredentialId) + '.';
      out.probeAnswer = askProbeQuestion == true
        ? 'Mock: I can see Account, Contact, and Opportunity plus custom metadata in this org.'
        : null;
      out.rawIntegrationsJson = '[]';
      out.rawConfigureJson = '{"type":"copado_cicd","config":{"credentialId":"' + orgCredentialId + '"}}';
      out.rawCheckStatusJson = '{"id":"' + out.integrationId + '","type":"copado_cicd","status":"connected"}';
      return out;
    }

    Settings settings = getSettings();
    requireOrgId(settings);

    if (String.isBlank(workspaceId)) {
      WorkspaceResult ws = ensureBuilderWorkspace();
      workspaceId = ws.workspaceId;
      out.workspaceId = workspaceId;
    }

    // 1) List existing integrations — prefer "User Level" / USER-level cicd
    HttpResponse listRes = sendRequest(
      'GET',
      '/organizations/' + settings.organizationId + '/integrations',
      null
    );
    assertOk(listRes, 'List integrations');
    out.rawIntegrationsJson = truncateJson(listRes.getBody(), 8000);

    List<Map<String, Object>> cicdCandidates = listCicdIntegrations(
      listRes.getBody(),
      workspaceId,
      orgCredentialId
    );

    String integrationId = null;
    if (String.isNotBlank(preferredIntegrationId)) {
      // User-selected integration — reuse it and update credential to selected env.
      integrationId = preferredIntegrationId;
      out.rawConfigureJson = truncateJson(
        'USER_SELECTED=' + preferredIntegrationId,
        8000
      );
    } else {
      integrationId = pickExistingCicdIntegrationId(
        cicdCandidates,
        settings.organizationId,
        out
      );
    }

    // 2) Discover configure options (diagnostic only)
    try {
      HttpResponse cfgRes = sendRequest(
        'POST',
        '/organizations/' + settings.organizationId + '/integrations/configure',
        JSON.serialize(new Map<String, Object>{ 'type' => 'copado_cicd' })
      );
      out.rawConfigureJson = truncateJson(cfgRes.getBody(), 8000);
      if (cfgRes.getStatusCode() < 200 || cfgRes.getStatusCode() >= 300) {
        out.message = 'Configure probe returned ' + cfgRes.getStatusCode() + '. ';
      } else if (String.isBlank(cfgRes.getBody()) || cfgRes.getBody().trim() == 'null') {
        out.rawConfigureJson =
          '{"note":"configure returned null — CI/CD integration already exists; '
          + 'updating credential on existing User Level connection"}';
      }
    } catch (Exception cfgEx) {
      out.rawConfigureJson = '{"error":"' + String.valueOf(cfgEx.getMessage()).left(400) + '"}';
    }

    // 3) Create ONLY if no cicd integration exists at all (last resort)
    if (String.isBlank(integrationId)) {
      List<Map<String, Object>> attempts = buildCicdCreateAttempts(
        workspaceId,
        orgCredentialId,
        orgName
      );
      List<String> errors = new List<String>();
      for (Map<String, Object> attempt : attempts) {
        try {
          HttpResponse createRes = sendRequest(
            'POST',
            '/organizations/' + settings.organizationId + '/integrations',
            JSON.serialize(attempt)
          );
          if (createRes.getStatusCode() >= 200 && createRes.getStatusCode() < 300) {
            Map<String, Object> created =
              (Map<String, Object>) JSON.deserializeUntyped(createRes.getBody());
            integrationId = String.valueOf(created.get('id'));
            out.rawConfigureJson = truncateJson(
              (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
                + 'CREATE_OK shape=' + JSON.serialize(attempt.keySet())
                + ' body=' + createRes.getBody(),
              8000
            );
            break;
          }
          errors.add(
            'shape=' + JSON.serialize(attempt.get('credential'))
              + '/' + JSON.serialize(attempt.get('config'))
              + ' => ' + createRes.getStatusCode() + ' '
              + truncateJson(createRes.getBody(), 240)
          );
        } catch (Exception createEx) {
          errors.add(String.valueOf(createEx.getMessage()).left(200));
        }
      }
      if (String.isBlank(integrationId)) {
        out.success = false;
        out.status = 'error';
        out.message =
          'No existing Copado (User Level) integration found, and create failed for credential '
          + orgCredentialId + '. '
          + (String.isBlank(out.message) ? '' : out.message)
          + 'Attempts: ' + String.join(errors, ' | ');
        return out;
      }
    } else {
      out.rawConfigureJson = truncateJson(
        (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
          + 'REUSE_EXISTING=' + integrationId,
        8000
      );
    }

    out.integrationId = integrationId;

    // 4) Always force-push the selected Dev credential onto User Level / cicd.
    // Skipping "already selected" caused Org Context changes (e.g. → dev1) to leave
    // the integration on the prior org when configure parsing was ambiguous.
    Boolean bound = bindOrgToIntegration(
      settings.organizationId,
      integrationId,
      orgCredentialId,
      orgName,
      out,
      true
    );
    out.credentialBound = bound;

    out.status = checkIntegrationStatus(settings.organizationId, integrationId, out);
    Boolean connected = 'connected'.equalsIgnoreCase(out.status);

    // Do not soft-accept "connected + wanted org name" — that reported Connected
    // while User Level stayed on a prior org (e.g. int after switching to dev1).

    out.success = connected && bound;
    if (out.success) {
      out.message =
        'Using existing Copado connection; credential set to '
        + blankTo(orgName, orgCredentialId) + '.';
    } else if (!bound) {
      out.status = 'Not bound';
      out.message =
        'Could not confirm Org Intelligence is bound to '
        + blankTo(orgName, orgCredentialId)
        + '. Copado AI may not allow programmatic User Level updates after the initial Connect. '
        + 'In Copado AI Settings, reconnect your Org Credential to '
        + blankTo(orgName, orgCredentialId)
        + ' (use your own PAT), then click Update OI again.';
    } else {
      out.message =
        'Found existing Copado connection but it is not healthy (status='
        + out.status
        + '). Re-check the User Level integration in Copado AI.';
    }
    if (String.isNotBlank(dialogueId)) {
      out.chatDialogueId = dialogueId;
    }

    // 5) Optional smoke-test — reuse the session dialogue only.
    // Never create "OI Probe" / "dev1 chat" throwaways (they clutter Copado AI).
    if (askProbeQuestion == true && connected) {
      String probeDialogueId = dialogueId;
      if (String.isBlank(probeDialogueId)) {
        try {
          DialogueResult probeDlg = createDialogue(
            workspaceId,
            blankTo(orgName, 'Builder') + ' — ' + Datetime.now().format('yyyy-MM-dd HH:mm')
          );
          probeDialogueId = probeDlg != null ? probeDlg.dialogueId : null;
          if (String.isNotBlank(probeDialogueId)) {
            out.chatDialogueId = probeDialogueId;
          }
        } catch (Exception dlgEx) {
          out.rawCheckStatusJson =
            (String.isBlank(out.rawCheckStatusJson) ? '' : out.rawCheckStatusJson + '\n')
            + 'PROBE_DIALOGUE_ERROR=' + dlgEx.getMessage();
        }
      }

      if (String.isBlank(probeDialogueId)) {
        out.success = connected;
        out.message =
          'Copado connection ready for '
          + blankTo(orgName, orgCredentialId)
          + ' (skipped live probe — no dialogue).';
        return out;
      }

      List<Map<String, Object>> payloads = orgIntelligencePayloads(
        integrationId,
        orgCredentialId,
        orgName,
        null
      );
      // Prefer the native string-UUID shape only (first payload) to avoid multi-turn spam.
      if (payloads.size() > 1) {
        payloads = new List<Map<String, Object>>{ payloads[0] };
      }
      String probePrompt =
        'List 3 custom fields or custom objects that exist in the connected Salesforce org. '
        + 'Reply with a short bullet list of API names only.';
      Exception lastProbeEx = null;
      Boolean probeOk = false;
      for (Map<String, Object> integrationsPayload : payloads) {
        try {
          DialogueResult reply = sendDialogueMessage(
            probeDialogueId,
            probePrompt,
            integrationsPayload,
            ASSISTANT_BUILD
          );
          out.probeAnswer = reply != null ? reply.message : null;
          if (reply != null && reply.pending == true && String.isBlank(out.probeAnswer)) {
            for (Integer p = 0; p < 12; p++) {
              String polled = pollAssistantText(probeDialogueId, reply.requestId);
              if (String.isNotBlank(polled)) {
                out.probeAnswer = polled;
                break;
              }
            }
          }
          if (!isSuccessfulOrgIntelligenceProbe(out.probeAnswer)) {
            continue;
          }
          probeOk = true;
          out.success = true;
          out.status = 'connected';
          out.message =
            'Org Intelligence connected for '
            + blankTo(orgName, orgCredentialId) + '.';
          lastProbeEx = null;
          break;
        } catch (Exception probeEx) {
          lastProbeEx = probeEx;
          out.probeAnswer = 'Probe chat failed: ' + probeEx.getMessage();
        }
      }
      // Keep the same session dialogue — do not spawn a second chat.
      if (String.isBlank(out.chatDialogueId)) {
        out.chatDialogueId = probeDialogueId;
      }
      if (!probeOk) {
        out.success = false;
        if (String.isNotBlank(out.probeAnswer)
          && out.probeAnswer.toLowerCase().contains('org_intelligence_unavailable')) {
          out.status = 'unavailable';
        } else {
          out.status = 'probe_failed';
        }
        out.message =
          'Copado connection found for '
          + blankTo(orgName, orgCredentialId)
          + ', but live metadata tools did not respond on a probe chat. '
          + 'Retry in a new Builder chat, or confirm Build Agent + this org works '
          + 'in Copado AI (same workspace id in Builder Settings).';
        if (lastProbeEx != null && String.isBlank(out.probeAnswer)) {
          out.probeAnswer = 'Probe chat failed: ' + lastProbeEx.getMessage();
        }
      }
    }

    return out;
  }

  /**
   * Ranked list of copado_cicd integrations.
   * Prefer named "User Level", then USER-level / All Workspaces, then credential
   * match, then workspace-scoped, then any other cicd.
   */
  @TestVisible
  private static List<Map<String, Object>> listCicdIntegrations(
    String listBody,
    String workspaceId,
    String orgCredentialId
  ) {
    List<Map<String, Object>> namedUserLevel = new List<Map<String, Object>>();
    List<Map<String, Object>> userLevel = new List<Map<String, Object>>();
    List<Map<String, Object>> credentialMatches = new List<Map<String, Object>>();
    List<Map<String, Object>> allWorkspaces = new List<Map<String, Object>>();
    List<Map<String, Object>> workspaceMatches = new List<Map<String, Object>>();
    List<Map<String, Object>> others = new List<Map<String, Object>>();
    if (String.isBlank(listBody)) {
      return namedUserLevel;
    }
    Object parsed = JSON.deserializeUntyped(listBody);
    List<Object> items = new List<Object>();
    if (parsed instanceof List<Object>) {
      items = (List<Object>) parsed;
    } else if (parsed instanceof Map<String, Object>) {
      Map<String, Object> wrap = (Map<String, Object>) parsed;
      if (wrap.get('items') instanceof List<Object>) {
        items = (List<Object>) wrap.get('items');
      } else if (wrap.get('integrations') instanceof List<Object>) {
        items = (List<Object>) wrap.get('integrations');
      }
    }
    for (Object item : items) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> row = (Map<String, Object>) item;
      String typeVal = row.containsKey('type') ? String.valueOf(row.get('type')) : '';
      if (!'copado_cicd'.equalsIgnoreCase(typeVal) && !'Copado'.equalsIgnoreCase(typeVal)) {
        // UI may show provider "Copado"; API type is usually copado_cicd.
        if (String.isBlank(typeVal) || !typeVal.toLowerCase().contains('cicd')) {
          continue;
        }
      }
      if (isUserLevelNamedIntegration(row)) {
        namedUserLevel.add(row);
        continue;
      }
      String level = firstJsonString(row, new List<String>{ 'level' });
      Boolean isUserLevel = 'USER'.equalsIgnoreCase(level);
      if (integrationMentionsCredential(row, orgCredentialId)) {
        if (isUserLevel) {
          userLevel.add(row);
        } else {
          credentialMatches.add(row);
        }
      } else {
        String ws = firstJsonString(row, new List<String>{ 'workspaceId', 'workspace_id' });
        if (String.isBlank(ws)) {
          // All Workspaces scope — typical for User Level governance connections
          if (isUserLevel) {
            userLevel.add(row);
          } else {
            allWorkspaces.add(row);
          }
        } else if (String.isNotBlank(workspaceId) && workspaceId.equals(ws)) {
          workspaceMatches.add(row);
        } else {
          others.add(row);
        }
      }
    }
    List<Map<String, Object>> ranked = new List<Map<String, Object>>();
    ranked.addAll(namedUserLevel);
    ranked.addAll(userLevel);
    ranked.addAll(credentialMatches);
    ranked.addAll(allWorkspaces);
    ranked.addAll(workspaceMatches);
    ranked.addAll(others);
    return ranked;
  }

  /**
   * Prefer current-user name/email match, then connected "User Level", then any
   * connected cicd, then first candidate.
   */
  @TestVisible
  private static String pickExistingCicdIntegrationId(
    List<Map<String, Object>> cicdCandidates,
    String organizationId,
    OrgIntelligenceResult out
  ) {
    if (cicdCandidates == null || cicdCandidates.isEmpty()) {
      return null;
    }
    CurrentUserMatchHints hints = loadCurrentUserMatchHints();
    String bestPersonalId = null;
    Integer bestPersonalScore = 0;
    Boolean bestPersonalConnected = false;
    for (Map<String, Object> candidate : cicdCandidates) {
      String candidateId = firstJsonString(candidate, new List<String>{ 'id' });
      String candidateName = firstJsonString(candidate, new List<String>{ 'name' });
      if (String.isBlank(candidateId)) {
        continue;
      }
      Integer score = scoreIntegrationNameForUser(candidateName, hints);
      if (score < 70) {
        continue;
      }
      String st = checkIntegrationStatus(organizationId, candidateId, out);
      Boolean connected = 'connected'.equalsIgnoreCase(st);
      if (
        bestPersonalId == null
        || (connected && !bestPersonalConnected)
        || (connected == bestPersonalConnected && score > bestPersonalScore)
      ) {
        bestPersonalId = candidateId;
        bestPersonalScore = score;
        bestPersonalConnected = connected;
        if (connected) {
          out.status = 'connected';
        }
      }
    }
    if (String.isNotBlank(bestPersonalId)) {
      out.rawConfigureJson = truncateJson(
        (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
          + 'AUTO_MATCH_USER score=' + bestPersonalScore + ' id=' + bestPersonalId,
        8000
      );
      return bestPersonalId;
    }
    // Pass 1: connected + named User Level
    for (Map<String, Object> candidate : cicdCandidates) {
      if (!isUserLevelNamedIntegration(candidate)) {
        continue;
      }
      String candidateId = firstJsonString(candidate, new List<String>{ 'id' });
      if (String.isBlank(candidateId)) {
        continue;
      }
      String st = checkIntegrationStatus(organizationId, candidateId, out);
      if ('connected'.equalsIgnoreCase(st)) {
        out.status = 'connected';
        return candidateId;
      }
    }
    // Pass 2: any connected cicd (prefer earlier rank = User Level / USER)
    for (Map<String, Object> candidate : cicdCandidates) {
      String candidateId = firstJsonString(candidate, new List<String>{ 'id' });
      if (String.isBlank(candidateId)) {
        continue;
      }
      String st = checkIntegrationStatus(organizationId, candidateId, out);
      if ('connected'.equalsIgnoreCase(st)) {
        out.status = 'connected';
        return candidateId;
      }
    }
    // Pass 3: reuse first ranked candidate even if not connected (update path)
    return firstJsonString(cicdCandidates[0], new List<String>{ 'id' });
  }

  @TestVisible
  private static Boolean isUserLevelNamedIntegration(Map<String, Object> row) {
    String name = firstJsonString(row, new List<String>{ 'name' });
    if (String.isBlank(name)) {
      return false;
    }
    String n = name.trim().toLowerCase();
    return n.equals('user level') || n.contains('user level');
  }

  /**
   * Find an existing CONNECTED Salesforce-type Copado AI integration that has int_id.
   * Do NOT create one from a Copado Org Credential Id — that produces a broken
   * salesforce integration and the agent errors with "Missing int_id".
   * Real Salesforce integrations come from Copado AI OAuth (salesforce_auth).
   */
  @TestVisible
  private static String ensureSalesforceIntegration(
    String listBody,
    String organizationId,
    String workspaceId,
    String orgCredentialId,
    String orgName,
    OrgIntelligenceResult out
  ) {
    if (isMockMode()) {
      return 'mock-salesforce-' + orgCredentialId;
    }
    String usableId = pickUsableSalesforceIntegrationId(
      listBody,
      organizationId,
      workspaceId,
      orgCredentialId,
      out
    );
    if (String.isNotBlank(usableId)) {
      out.rawConfigureJson = truncateJson(
        (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
          + 'SF_CONNECTED=' + usableId,
        8000
      );
      return usableId;
    }
    out.rawConfigureJson = truncateJson(
      (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
        + 'SF_SKIP_CREATE=no connected salesforce OAuth integration; '
        + 'using copado_cicd only',
      8000
    );
    return null;
  }

  /**
   * Prefer connected Salesforce integrations. Skip Builder-created stubs (they
   * lack OAuth and cause "Missing int_id"). The API list payload usually has
   * `id` only — chat bindings always send int_id = that id.
   */
  @TestVisible
  private static String pickUsableSalesforceIntegrationId(
    String listBody,
    String organizationId,
    String workspaceId,
    String orgCredentialId,
    OrgIntelligenceResult out
  ) {
    List<Map<String, Object>> candidates = listIntegrationsByType(
      listBody,
      'salesforce',
      workspaceId,
      orgCredentialId
    );
    for (Map<String, Object> candidate : candidates) {
      String name = firstJsonString(candidate, new List<String>{ 'name' });
      if (String.isNotBlank(name) && name.toLowerCase().startsWith('builder sf')) {
        if (out != null) {
          out.rawConfigureJson = truncateJson(
            (String.isBlank(out.rawConfigureJson) ? '' : out.rawConfigureJson + '\n')
              + 'SF_SKIP_BUILDER_STUB=' + name,
            8000
          );
        }
        continue;
      }
      String intId = firstJsonString(candidate, new List<String>{ 'int_id', 'intId' });
      String recordId = firstJsonString(candidate, new List<String>{ 'id' });
      String usableId = String.isNotBlank(intId) ? intId : recordId;
      if (String.isBlank(usableId)) {
        continue;
      }
      String statusId = String.isNotBlank(recordId) ? recordId : usableId;
      String st = checkIntegrationStatus(organizationId, statusId, out);
      if ('connected'.equalsIgnoreCase(st)) {
        return usableId;
      }
    }
    return null;
  }

  /**
   * Start Copado AI Salesforce OAuth so Org Intelligence can query live metadata.
   * Returns a browser URL the user must open (sandbox or production login).
   */
  public static SalesforceAuthResult beginSalesforceOrgAuth(
    String workspaceId,
    String integrationName,
    String orgType,
    String redirectUri
  ) {
    SalesforceAuthResult out = new SalesforceAuthResult();
    if (isMockMode()) {
      out.success = true;
      out.authUrl = 'https://test.salesforce.com/?mock=builder-sf-auth';
      out.message = 'Mock Salesforce auth URL ready.';
      return out;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    if (String.isBlank(redirectUri)) {
      out.success = false;
      out.message = 'redirectUri is required for Salesforce OAuth.';
      return out;
    }
    String name = blankTo(integrationName, 'Builder Org Intelligence');
    String level = 'USER';
    String type = String.isNotBlank(orgType) ? orgType : 'SANDBOX';
    if (!'SANDBOX'.equals(type) && !'PRODUCTION/DEVELOPER'.equals(type)) {
      type = 'SANDBOX';
    }
    String path =
      '/organizations/' + settings.organizationId + '/integrations/salesforce_auth'
      + '?name=' + EncodingUtil.urlEncode(name.left(100), 'UTF-8')
      + '&level=' + EncodingUtil.urlEncode(level, 'UTF-8')
      + '&redirect_uri=' + EncodingUtil.urlEncode(redirectUri, 'UTF-8')
      + '&org_type=' + EncodingUtil.urlEncode(type, 'UTF-8');
    if (String.isNotBlank(workspaceId)) {
      path += '&workspace_id=' + EncodingUtil.urlEncode(workspaceId, 'UTF-8');
    }
    try {
      HttpResponse res = sendRequest('GET', path, null);
      out.rawResponse = truncateJson(blankTo(res.getBody(), ''), 2000);
      String loc = res.getHeader('Location');
      if (String.isBlank(loc)) {
        loc = res.getHeader('location');
      }
      String fromBody = extractAuthUrl(res.getBody());
      out.authUrl = String.isNotBlank(fromBody) ? fromBody : loc;
      // Some gateways return the login URL as plain text.
      if (String.isBlank(out.authUrl) && String.isNotBlank(res.getBody())) {
        String trimmed = res.getBody().trim();
        if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
          out.authUrl = trimmed.left(2000);
        }
      }
      if (String.isNotBlank(out.authUrl)) {
        out.success = true;
        out.message =
          'Open the Salesforce login URL, authenticate the Dev sandbox, '
          + 'then click Reconnect Org Intelligence.';
      } else {
        out.success = false;
        out.message =
          'Could not start Salesforce OAuth (HTTP '
          + res.getStatusCode()
          + '). Authenticate a Salesforce integration in Copado AI, then reconnect.';
      }
    } catch (Exception ex) {
      out.success = false;
      out.message = 'Salesforce OAuth start failed: ' + ex.getMessage();
    }
    return out;
  }

  @TestVisible
  private static String extractAuthUrl(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> row = (Map<String, Object>) parsed;
        String url = firstJsonString(row, new List<String>{
          'url', 'auth_url', 'authUrl', 'redirect_url', 'redirectUrl', 'login_url', 'loginUrl'
        });
        if (String.isNotBlank(url)) {
          return url;
        }
        // Nested data/url shapes
        if (row.get('data') instanceof Map<String, Object>) {
          return firstJsonString(
            (Map<String, Object>) row.get('data'),
            new List<String>{ 'url', 'auth_url', 'authUrl' }
          );
        }
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  @TestVisible
  private static List<Map<String, Object>> listIntegrationsByType(
    String listBody,
    String integrationType,
    String workspaceId,
    String orgCredentialId
  ) {
    List<Map<String, Object>> credentialMatches = new List<Map<String, Object>>();
    List<Map<String, Object>> workspaceMatches = new List<Map<String, Object>>();
    List<Map<String, Object>> others = new List<Map<String, Object>>();
    if (String.isBlank(listBody) || String.isBlank(integrationType)) {
      return credentialMatches;
    }
    Object parsed = JSON.deserializeUntyped(listBody);
    List<Object> items = new List<Object>();
    if (parsed instanceof List<Object>) {
      items = (List<Object>) parsed;
    } else if (parsed instanceof Map<String, Object>) {
      Map<String, Object> wrap = (Map<String, Object>) parsed;
      if (wrap.get('items') instanceof List<Object>) {
        items = (List<Object>) wrap.get('items');
      } else if (wrap.get('integrations') instanceof List<Object>) {
        items = (List<Object>) wrap.get('integrations');
      }
    }
    for (Object item : items) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> row = (Map<String, Object>) item;
      String typeVal = row.containsKey('type') ? String.valueOf(row.get('type')) : '';
      if (!integrationType.equalsIgnoreCase(typeVal)) {
        continue;
      }
      if (integrationMentionsCredential(row, orgCredentialId)) {
        credentialMatches.add(row);
      } else {
        String ws = firstJsonString(row, new List<String>{ 'workspaceId', 'workspace_id' });
        if (String.isNotBlank(workspaceId) && workspaceId.equals(ws)) {
          workspaceMatches.add(row);
        } else {
          others.add(row);
        }
      }
    }
    List<Map<String, Object>> ranked = new List<Map<String, Object>>();
    ranked.addAll(credentialMatches);
    ranked.addAll(workspaceMatches);
    ranked.addAll(others);
    return ranked;
  }

  @TestVisible
  private static Map<String, Object> findMatchingCicdIntegration(
    String listBody,
    String workspaceId,
    String orgCredentialId
  ) {
    List<Map<String, Object>> ranked = listCicdIntegrations(
      listBody,
      workspaceId,
      orgCredentialId
    );
    return ranked.isEmpty() ? null : ranked[0];
  }

  @TestVisible
  private static Boolean integrationMentionsCredential(
    Map<String, Object> row,
    String orgCredentialId
  ) {
    if (row == null || String.isBlank(orgCredentialId)) {
      return false;
    }
    String serialized = JSON.serialize(row);
    return serialized != null && serialized.contains(orgCredentialId);
  }

  @TestVisible
  private static String checkIntegrationStatus(
    String organizationId,
    String integrationId,
    OrgIntelligenceResult out
  ) {
    try {
      HttpResponse statusRes = sendRequest(
        'GET',
        '/organizations/' + organizationId
          + '/integrations/' + integrationId + '/check-status',
        null
      );
      out.rawCheckStatusJson = truncateJson(statusRes.getBody(), 2000);
      if (statusRes.getStatusCode() >= 200 && statusRes.getStatusCode() < 300) {
        Map<String, Object> statusBody =
          (Map<String, Object>) JSON.deserializeUntyped(statusRes.getBody());
        return statusBody.containsKey('status')
          ? String.valueOf(statusBody.get('status'))
          : 'unknown';
      }
      return 'error';
    } catch (Exception statusEx) {
      out.rawCheckStatusJson = '{"error":"' + String.valueOf(statusEx.getMessage()).left(300) + '"}';
      return 'error';
    }
  }

  /**
   * Ask Org Intelligence for live Layout fullNames for the given objects.
   * Returns names like Account-Formato de cuentas — never invents Object-Object Layout.
   */
  public static List<String> requestLiveLayoutFullNames(
    String dialogueId,
    String workspaceId,
    String integrationId,
    String orgCredentialId,
    String orgName,
    List<String> objectApis
  ) {
    List<MetadataListRequest> reqs = new List<MetadataListRequest>();
    if (objectApis != null) {
      for (String obj : objectApis) {
        if (String.isBlank(obj)) {
          continue;
        }
        MetadataListRequest req = new MetadataListRequest('Layout', obj.trim());
        req.namePrefix = obj.trim() + '-';
        reqs.add(req);
      }
    }
    if (reqs.isEmpty()) {
      reqs.add(new MetadataListRequest('Layout'));
    }
    Map<String, List<String>> byType = requestLiveMetadataFullNames(
      dialogueId,
      workspaceId,
      integrationId,
      orgCredentialId,
      orgName,
      reqs
    );
    List<String> out = byType != null && byType.containsKey('Layout')
      ? byType.get('Layout')
      : new List<String>();
    return out != null ? out : new List<String>();
  }

  /**
   * Ask Org Intelligence for live Metadata API fullNames for arbitrary types.
   * Uses natural-language listMetadata via the Build agent (Copado-confirmed path).
   * Never uses Hub session SOAP callouts against the Dev org.
   */
  public static Map<String, List<String>> requestLiveMetadataFullNames(
    String dialogueId,
    String workspaceId,
    String integrationId,
    String orgCredentialId,
    String orgName,
    List<MetadataListRequest> requests
  ) {
    Map<String, List<String>> out = new Map<String, List<String>>();
    List<MetadataListRequest> reqs = normalizeMetadataListRequests(requests);
    if (reqs.isEmpty()) {
      return out;
    }
    if (isMockMode()) {
      return mockLiveMetadataFullNames(reqs);
    }
    if (String.isBlank(dialogueId) || String.isBlank(integrationId)
      || String.isBlank(orgCredentialId)) {
      return out;
    }

    Boolean bound = syncIntegrationOrgCredential(integrationId, orgCredentialId, orgName);
    if (bound != true) {
      return out;
    }
    try {
      tryStartAgentWorker(
        ASSISTANT_BUILD,
        workspaceId,
        dialogueId,
        buildIntegrationsPayload(integrationId, null, orgCredentialId, orgName)
      );
    } catch (Exception ignore) {
    }

    String prompt = buildLiveMetadataListPrompt(reqs, orgCredentialId, orgName);
    DialogueResult reply = sendDialogueMessage(
      dialogueId,
      prompt,
      null,
      ASSISTANT_BUILD,
      workspaceId,
      'You list live Salesforce Metadata API fullNames via Org Intelligence. '
        + 'Reply ONLY with JSON keyed by metadata type. Never invent English default layout names.'
    );
    String raw = reply != null ? reply.message : null;
    if (String.isBlank(raw) && reply != null && reply.pending == true) {
      raw = waitBrieflyForPackageReply(dialogueId);
    }
    if (String.isBlank(raw) && reply != null && String.isNotBlank(reply.dialogueId)) {
      try {
        raw = pollAssistantText(
          reply.dialogueId,
          reply.requestId,
          reply.baselineMessageCount,
          reply.baselineAssistantText
        );
      } catch (Exception ignore) {
      }
    }
    return parseLiveMetadataFullNamesReply(raw, reqs);
  }

  @TestVisible
  private static List<MetadataListRequest> normalizeMetadataListRequests(
    List<MetadataListRequest> requests
  ) {
    List<MetadataListRequest> out = new List<MetadataListRequest>();
    if (requests == null) {
      return out;
    }
    Set<String> seen = new Set<String>();
    for (MetadataListRequest req : requests) {
      if (req == null || String.isBlank(req.metadataType)) {
        continue;
      }
      String t = req.metadataType.trim();
      MetadataListRequest n = new MetadataListRequest(t);
      n.objectApi = String.isNotBlank(req.objectApi) ? req.objectApi.trim() : null;
      n.folder = String.isNotBlank(req.folder) ? req.folder.trim() : null;
      n.namePrefix = String.isNotBlank(req.namePrefix) ? req.namePrefix.trim() : null;
      if ('Layout'.equals(t) && String.isNotBlank(n.objectApi) && String.isBlank(n.namePrefix)) {
        n.namePrefix = n.objectApi + '-';
      }
      String key = t + '|' + blankTo(n.objectApi, '') + '|' + blankTo(n.folder, '')
        + '|' + blankTo(n.namePrefix, '');
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      out.add(n);
    }
    return out;
  }

  @TestVisible
  private static Map<String, List<String>> mockLiveMetadataFullNames(
    List<MetadataListRequest> reqs
  ) {
    Map<String, List<String>> out = new Map<String, List<String>>();
    for (MetadataListRequest req : reqs) {
      String t = req.metadataType;
      if (!out.containsKey(t)) {
        out.put(t, new List<String>());
      }
      List<String> bucket = out.get(t);
      if ('Layout'.equals(t)) {
        String obj = String.isNotBlank(req.objectApi) ? req.objectApi : 'Account';
        String name = obj + '-Formato de ' + obj.toLowerCase();
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      } else if ('CustomField'.equals(t) && String.isNotBlank(req.objectApi)) {
        String name = req.objectApi + '.Name';
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      } else if ('RecordType'.equals(t) && String.isNotBlank(req.objectApi)) {
        String name = req.objectApi + '.Master';
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      } else if ('ValidationRule'.equals(t) && String.isNotBlank(req.objectApi)) {
        String name = req.objectApi + '.Sample_Rule';
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      } else if ('Flow'.equals(t)) {
        if (!bucket.contains('Sample_Flow')) {
          bucket.add('Sample_Flow');
        }
      } else if ('FlexiPage'.equals(t)) {
        if (!bucket.contains('Sample_FlexiPage')) {
          bucket.add('Sample_FlexiPage');
        }
      } else if ('Profile'.equals(t)) {
        if (!bucket.contains('Admin')) {
          bucket.add('Admin');
        }
      } else if ('PermissionSet'.equals(t)) {
        if (!bucket.contains('Sample_Permission_Set')) {
          bucket.add('Sample_Permission_Set');
        }
      } else if ('ApexClass'.equals(t)) {
        if (!bucket.contains('SampleClass')) {
          bucket.add('SampleClass');
        }
      } else if ('CustomObject'.equals(t)) {
        if (!bucket.contains('Account')) {
          bucket.add('Account');
        }
      } else if (String.isNotBlank(req.folder)) {
        String name = req.folder + '/Sample_Item';
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      } else {
        String name = 'Sample_' + t;
        if (!bucket.contains(name)) {
          bucket.add(name);
        }
      }
    }
    return out;
  }

  @TestVisible
  private static String buildLiveMetadataListPrompt(
    List<MetadataListRequest> reqs,
    String orgCredentialId,
    String orgName
  ) {
    List<String> lines = new List<String>();
    lines.add(
      'Before generating any package or metadata paths, list LIVE Salesforce Metadata API '
        + 'fullNames from the CURRENT User Level / Org Intelligence org only.'
    );
    lines.add('Use Org Intelligence / metadata tools. Do NOT invent, translate, or guess names.');
    lines.add(
      'Expected org credential Id: '
        + orgCredentialId
        + (String.isNotBlank(orgName) ? ' (' + orgName + ')' : '')
        + '.'
    );
    lines.add('Requests:');
    for (MetadataListRequest req : reqs) {
      String line = '- type=' + req.metadataType;
      if (String.isNotBlank(req.objectApi)) {
        line += ' object=' + req.objectApi;
      }
      if (String.isNotBlank(req.folder)) {
        line += ' folder=' + req.folder;
      }
      if (String.isNotBlank(req.namePrefix)) {
        line += ' prefix=' + req.namePrefix;
      }
      if (isChildMetadataType(req.metadataType) && String.isNotBlank(req.objectApi)) {
        line += ' (list fullNames for this object only)';
      }
      if (isFolderedMetadataType(req.metadataType) && String.isBlank(req.folder)) {
        line += ' (if foldered, include FolderName/ItemName fullNames)';
      }
      lines.add(line);
    }
    lines.add(
      'For Layout, do NOT return Object-Object Layout unless that exact fullName exists live.'
    );
    lines.add('Reply with ONLY JSON (no markdown), keyed by metadata type:');
    lines.add(
      '{"Layout":["Account-Formato de cuentas"],"Flow":["My_Flow"],'
        + '"CustomField":["Account.My_Field__c"],"Profile":["Admin"]}'
    );
    return String.join(lines, '\n');
  }

  private static Boolean isChildMetadataType(String metadataType) {
    return new Set<String>{
      'CustomField', 'RecordType', 'ValidationRule', 'FieldSet', 'ListView',
      'CompactLayout', 'WebLink'
    }.contains(metadataType);
  }

  private static Boolean isFolderedMetadataType(String metadataType) {
    return new Set<String>{
      'EmailTemplate', 'Report', 'Dashboard', 'Document'
    }.contains(metadataType);
  }

  @TestVisible
  private static Map<String, List<String>> parseLiveMetadataFullNamesReply(
    String raw,
    List<MetadataListRequest> reqs
  ) {
    Map<String, List<String>> out = new Map<String, List<String>>();
    if (String.isBlank(raw)) {
      return out;
    }
    Set<String> requestedTypes = new Set<String>();
    Map<String, List<String>> prefixesByType = new Map<String, List<String>>();
    Map<String, List<String>> objectsByType = new Map<String, List<String>>();
    if (reqs != null) {
      for (MetadataListRequest req : reqs) {
        if (req == null || String.isBlank(req.metadataType)) {
          continue;
        }
        requestedTypes.add(req.metadataType);
        if (String.isNotBlank(req.namePrefix)) {
          if (!prefixesByType.containsKey(req.metadataType)) {
            prefixesByType.put(req.metadataType, new List<String>());
          }
          prefixesByType.get(req.metadataType).add(req.namePrefix);
        }
        if (String.isNotBlank(req.objectApi)) {
          if (!objectsByType.containsKey(req.metadataType)) {
            objectsByType.put(req.metadataType, new List<String>());
          }
          objectsByType.get(req.metadataType).add(req.objectApi);
        }
      }
    }

    Map<String, Object> parsed = parseStoryJson(raw);
    if (parsed != null) {
      // Legacy Layout-only shape: {"layouts":[...]}
      if (parsed.get('layouts') instanceof List<Object> && !parsed.containsKey('Layout')) {
        parsed.put('Layout', parsed.get('layouts'));
      }
      for (String key : parsed.keySet()) {
        if (!(parsed.get(key) instanceof List<Object>)) {
          continue;
        }
        String typeName = normalizeLiveMetadataTypeKey(key);
        if (String.isBlank(typeName)) {
          continue;
        }
        if (!requestedTypes.isEmpty() && !requestedTypes.contains(typeName)) {
          continue;
        }
        for (Object row : (List<Object>) parsed.get(key)) {
          if (row == null) {
            continue;
          }
          addLiveMetadataFullName(
            out,
            typeName,
            String.valueOf(row).trim(),
            prefixesByType.get(typeName),
            objectsByType.get(typeName)
          );
        }
      }
    }

    // Fallback: scrape Layout fullNames from free text / AUTHORITATIVE blocks
    if (requestedTypes.isEmpty() || requestedTypes.contains('Layout')) {
      Map<String, List<String>> authByType =
        CopadoDevopsService.extractAuthoritativeLiveMetadata(raw);
      if (authByType != null) {
        for (String typeName : authByType.keySet()) {
          if (!requestedTypes.isEmpty() && !requestedTypes.contains(typeName)) {
            continue;
          }
          for (String name : authByType.get(typeName)) {
            addLiveMetadataFullName(
              out,
              typeName,
              name,
              prefixesByType.get(typeName),
              objectsByType.get(typeName)
            );
          }
        }
      }
      for (String layoutName : CopadoDevopsService.extractLiveLayoutFullNames(raw)) {
        addLiveMetadataFullName(
          out,
          'Layout',
          layoutName,
          prefixesByType.get('Layout'),
          objectsByType.get('Layout')
        );
      }
    }
    return out;
  }

  private static String normalizeLiveMetadataTypeKey(String key) {
    if (String.isBlank(key)) {
      return null;
    }
    String k = key.trim();
    if ('layouts'.equalsIgnoreCase(k)) {
      return 'Layout';
    }
    if ('flows'.equalsIgnoreCase(k)) {
      return 'Flow';
    }
    if ('profiles'.equalsIgnoreCase(k)) {
      return 'Profile';
    }
    if ('permissionSets'.equalsIgnoreCase(k) || 'permissionsets'.equalsIgnoreCase(k)) {
      return 'PermissionSet';
    }
    if ('customFields'.equalsIgnoreCase(k) || 'fields'.equalsIgnoreCase(k)) {
      return 'CustomField';
    }
    if ('customObjects'.equalsIgnoreCase(k) || 'objects'.equalsIgnoreCase(k)) {
      return 'CustomObject';
    }
    if ('apexClasses'.equalsIgnoreCase(k) || 'classes'.equalsIgnoreCase(k)) {
      return 'ApexClass';
    }
    if ('flexiPages'.equalsIgnoreCase(k) || 'flexipages'.equalsIgnoreCase(k)) {
      return 'FlexiPage';
    }
    if ('recordTypes'.equalsIgnoreCase(k)) {
      return 'RecordType';
    }
    if ('validationRules'.equalsIgnoreCase(k)) {
      return 'ValidationRule';
    }
    // Accept exact Metadata API type names
    if (k.length() > 0 && k.substring(0, 1).equals(k.substring(0, 1).toUpperCase())
      && !k.contains(' ')) {
      return k;
    }
    return null;
  }

  private static void addLiveMetadataFullName(
    Map<String, List<String>> out,
    String typeName,
    String name,
    List<String> prefixes,
    List<String> objectApis
  ) {
    if (String.isBlank(typeName) || String.isBlank(name)) {
      return;
    }
    if ('Layout'.equals(typeName) && isEnglishDefaultLayoutName(name)) {
      return;
    }
    if (prefixes != null && !prefixes.isEmpty()) {
      Boolean matched = false;
      for (String prefix : prefixes) {
        if (String.isNotBlank(prefix) && name.startsWith(prefix)) {
          matched = true;
          break;
        }
      }
      if (!matched) {
        return;
      }
    } else if ('Layout'.equals(typeName) && objectApis != null && !objectApis.isEmpty()) {
      if (!layoutMatchesObjects(name, objectApis)) {
        return;
      }
    } else if (isChildMetadataType(typeName) && objectApis != null && !objectApis.isEmpty()) {
      Boolean matched = false;
      for (String obj : objectApis) {
        if (String.isNotBlank(obj) && name.startsWith(obj + '.')) {
          matched = true;
          break;
        }
      }
      if (!matched) {
        return;
      }
    }
    if (!out.containsKey(typeName)) {
      out.put(typeName, new List<String>());
    }
    List<String> bucket = out.get(typeName);
    if (!bucket.contains(name)) {
      bucket.add(name);
    }
  }

  @TestVisible
  private static List<String> parseLiveLayoutFullNamesReply(
    String raw,
    List<String> objectApis
  ) {
    List<MetadataListRequest> reqs = new List<MetadataListRequest>();
    if (objectApis != null) {
      for (String obj : objectApis) {
        if (String.isBlank(obj)) {
          continue;
        }
        MetadataListRequest req = new MetadataListRequest('Layout', obj.trim());
        req.namePrefix = obj.trim() + '-';
        reqs.add(req);
      }
    }
    Map<String, List<String>> byType = parseLiveMetadataFullNamesReply(raw, reqs);
    List<String> out = byType != null && byType.containsKey('Layout')
      ? byType.get('Layout')
      : new List<String>();
    return out != null ? out : new List<String>();
  }

  private static Boolean isEnglishDefaultLayoutName(String member) {
    if (String.isBlank(member) || !member.contains('-')) {
      return false;
    }
    Integer dash = member.indexOf('-');
    if (dash <= 0 || dash >= member.length() - 1) {
      return false;
    }
    String objectApi = member.substring(0, dash);
    return (objectApi + ' Layout').equals(member.substring(dash + 1));
  }

  private static Boolean layoutMatchesObjects(String layoutName, List<String> objectApis) {
    if (String.isBlank(layoutName) || objectApis == null || objectApis.isEmpty()) {
      return true;
    }
    for (String obj : objectApis) {
      if (String.isNotBlank(obj) && layoutName.startsWith(obj + '-')) {
        return true;
      }
    }
    return false;
  }

  /**
   * Push a Dev/Int org credential onto an existing copado_cicd integration
   * (e.g. User Level) so Org Intelligence scopes to that org.
   */
  public static Boolean syncIntegrationOrgCredential(
    String integrationId,
    String orgCredentialId,
    String orgName
  ) {
    if (String.isBlank(integrationId) || String.isBlank(orgCredentialId)) {
      return false;
    }
    if (isMockMode()) {
      return true;
    }
    Settings settings = getSettings();
    requireOrgId(settings);
    OrgIntelligenceResult out = new OrgIntelligenceResult();
    // Always force-push — Org Context changes must update User Level every time.
    // No soft name-match fallback: that lied when User Level stayed on another org.
    return bindOrgToIntegration(
      settings.organizationId,
      integrationId,
      orgCredentialId,
      orgName,
      out,
      true
    );
  }

  /**
   * Currently selected Org Credential Id on a Copado AI integration (from configure).
   */
  public static String getIntegrationSelectedCredentialId(String integrationId) {
    if (String.isBlank(integrationId) || isMockMode()) {
      return null;
    }
    try {
      Settings settings = getSettings();
      requireOrgId(settings);
      HttpResponse cfgGet = sendRequest(
        'GET',
        '/organizations/'
          + settings.organizationId
          + '/integrations/'
          + integrationId
          + '/configure',
        null
      );
      if (cfgGet.getStatusCode() >= 200 && cfgGet.getStatusCode() < 300) {
        String fromCfg = extractSelectedCredentialId(cfgGet.getBody());
        if (String.isNotBlank(fromCfg)) {
          return fromCfg;
        }
      }
      HttpResponse integGet = sendRequest(
        'GET',
        '/organizations/'
          + settings.organizationId
          + '/integrations/'
          + integrationId,
        null
      );
      if (integGet.getStatusCode() >= 200 && integGet.getStatusCode() < 300) {
        return extractSelectedCredentialId(integGet.getBody());
      }
      return null;
    } catch (Exception ignore) {
      return null;
    }
  }

  /**
   * After Deploy-to-next advances the session env, update Copado AI integration
   * in a fresh transaction (callout after DML in refreshJobStatus is not allowed).
   */
  @future(callout=true)
  public static void syncIntegrationOrgCredentialFuture(
    String integrationId,
    String orgCredentialId,
    String orgName
  ) {
    try {
      syncIntegrationOrgCredential(integrationId, orgCredentialId, orgName);
    } catch (Exception ex) {
      System.debug(
        LoggingLevel.WARN,
        'syncIntegrationOrgCredentialFuture: ' + ex.getMessage()
      );
    }
  }

  /**
   * Discover the integration's configurable org list, then push the selected Dev
   * org credential into its config so Org Intelligence scopes metadata to that org.
   * forcePush=true always re-POSTs (Org Context change / Reconnect) so User Level
   * cannot stay on a prior org when configure parsing is ambiguous.
   */
  @TestVisible
  private static Boolean bindOrgToIntegration(
    String organizationId,
    String integrationId,
    String orgCredentialId,
    String orgName,
    OrgIntelligenceResult out
  ) {
    return bindOrgToIntegration(
      organizationId,
      integrationId,
      orgCredentialId,
      orgName,
      out,
      false
    );
  }

  @TestVisible
  private static Boolean bindOrgToIntegration(
    String organizationId,
    String integrationId,
    String orgCredentialId,
    String orgName,
    OrgIntelligenceResult out,
    Boolean forcePush
  ) {
    if (String.isBlank(organizationId) || String.isBlank(integrationId)
      || String.isBlank(orgCredentialId) || isMockMode()) {
      return isMockMode() && String.isNotBlank(orgCredentialId);
    }
    List<String> diag = new List<String>();
    String configureBody = null;
    String integrationBody = null;

    try {
      HttpResponse cfgGet = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/integrations/' + integrationId + '/configure',
        null
      );
      configureBody = cfgGet.getBody();
      diag.add('GET_CONFIGURE[' + cfgGet.getStatusCode() + ']=' + blankTo(configureBody, '(empty)'));
    } catch (Exception cfgEx) {
      diag.add('GET_CONFIGURE_ERROR=' + cfgEx.getMessage());
    }
    try {
      HttpResponse integGet = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/integrations/' + integrationId,
        null
      );
      integrationBody = integGet.getBody();
      diag.add(
        'GET_INTEGRATION[' + integGet.getStatusCode() + ']='
          + blankTo(integrationBody, '(empty)').left(2000)
      );
    } catch (Exception integEx) {
      diag.add('GET_INTEGRATION_ERROR=' + integEx.getMessage());
    }

    Boolean alreadySelected =
      isTargetCredentialSelected(configureBody, orgCredentialId, orgName)
      || isTargetCredentialSelected(integrationBody, orgCredentialId, orgName)
      || configScalarsMatchTarget(integrationBody, orgCredentialId, orgName)
      || configScalarsMatchTarget(configureBody, orgCredentialId, orgName);

    if (alreadySelected && forcePush != true) {
      diag.add('SELECT_ORG=already selected; skip update');
      out.rawConfigureJson = truncateJson(
        String.join(diag, '\n')
          + (String.isBlank(out.rawConfigureJson) ? '' : '\n' + out.rawConfigureJson),
        8000
      );
      return true;
    }
    if (alreadySelected && forcePush == true) {
      diag.add('SELECT_ORG=looks selected but forcePush — re-POST credential');
    } else {
      diag.add(
        'SELECTED_NOW='
          + blankTo(extractSelectedCredentialId(configureBody), '(none)')
          + '/'
          + blankTo(extractSelectedCredentialId(integrationBody), '(none)')
          + ' label='
          + blankTo(extractSelectedCredentialLabel(configureBody), '(none)')
          + '/'
          + blankTo(extractSelectedCredentialLabel(integrationBody), '(none)')
      );
    }

    List<Map<String, Object>> attempts = buildOrgSelectAttempts(orgCredentialId, orgName);
    attempts.addAll(buildCicdUpdateAttempts(orgCredentialId));
    Boolean postedOk = false;
    for (Map<String, Object> attempt : attempts) {
      try {
        HttpResponse upd = sendRequest(
          'POST',
          '/organizations/' + organizationId + '/integrations/' + integrationId,
          JSON.serialize(attempt)
        );
        Integer code = upd.getStatusCode();
        if (code >= 200 && code < 300) {
          postedOk = true;
          diag.add('SELECT_ORG_OK=' + JSON.serialize(attempt.get('config')));
          break;
        } else if (code != 404 && code != 405 && code != 500) {
          diag.add('SELECT_ORG[' + code + ']=' + blankTo(upd.getBody(), '').left(300));
        }
      } catch (Exception updEx) {
        diag.add('SELECT_ORG_ERROR=' + updEx.getMessage());
      }
    }
    if (!postedOk) {
      for (Map<String, Object> attempt : attempts) {
        try {
          Object payload = attempt.containsKey('config') ? attempt.get('config') : attempt;
          HttpResponse upd = sendRequest(
            'POST',
            '/organizations/' + organizationId + '/integrations/' + integrationId + '/configure',
            JSON.serialize(payload)
          );
          Integer code = upd.getStatusCode();
          if (code >= 200 && code < 300) {
            postedOk = true;
            diag.add('SELECT_ORG_CONFIGURE_OK');
            break;
          }
        } catch (Exception ignore) {
        }
      }
    }
    if (!postedOk) {
      diag.add('SELECT_ORG=no accepted update payload');
    }

    Boolean verified = false;
    String verifyConfigure = null;
    String verifyIntegration = null;
    try {
      HttpResponse cfgVerify = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/integrations/' + integrationId + '/configure',
        null
      );
      verifyConfigure = cfgVerify.getBody();
      diag.add(
        'GET_CONFIGURE_VERIFY[' + cfgVerify.getStatusCode() + ']='
          + blankTo(verifyConfigure, '(empty)').left(1200)
      );
    } catch (Exception verifyEx) {
      diag.add('GET_CONFIGURE_VERIFY_ERROR=' + verifyEx.getMessage());
    }
    try {
      HttpResponse integVerify = sendRequest(
        'GET',
        '/organizations/' + organizationId + '/integrations/' + integrationId,
        null
      );
      verifyIntegration = integVerify.getBody();
      diag.add(
        'GET_INTEGRATION_VERIFY[' + integVerify.getStatusCode() + ']='
          + blankTo(verifyIntegration, '(empty)').left(1200)
      );
    } catch (Exception verifyEx) {
      diag.add('GET_INTEGRATION_VERIFY_ERROR=' + verifyEx.getMessage());
    }

    verified =
      isTargetCredentialSelected(verifyConfigure, orgCredentialId, orgName)
      || isTargetCredentialSelected(verifyIntegration, orgCredentialId, orgName)
      || configScalarsMatchTarget(verifyIntegration, orgCredentialId, orgName)
      || configScalarsMatchTarget(verifyConfigure, orgCredentialId, orgName);

    if (!verified) {
      String selectedAfter = firstNonBlank(
        extractSelectedCredentialId(verifyIntegration),
        extractSelectedCredentialId(verifyConfigure)
      );
      if (selectedCredentialSalesforceNameMatches(selectedAfter, orgName)) {
        verified = true;
        diag.add('SELECT_ORG=matched via Salesforce credential name for selected Id');
      }
    }

    // Do not treat HTTP 200 / POST_OK as success without a GET verify match.
    // Copado AI User Level binds are often read-only after create; a silent
    // forcePush acceptance caused Builder to report Connected while the
    // integration stayed on the prior org.
    if (!verified) {
      diag.add(
        postedOk
          ? 'SELECT_ORG=POST accepted but GET verify did not match target credential'
          : 'SELECT_ORG=not verified as selected credential'
      );
    }

    out.rawConfigureJson = truncateJson(
      String.join(diag, '\n')
        + (String.isBlank(out.rawConfigureJson) ? '' : '\n' + out.rawConfigureJson),
      8000
    );
    return verified;
  }

  /**
   * Pull the currently selected Org Credential id from a configure JSON body.
   * Prefer config/credential nested values — root orgId/environmentId are often
   * Copado AI tenant fields, not the Development Org Credential dropdown.
   */
  @TestVisible
  private static String extractSelectedCredentialId(String configureBody) {
    if (String.isBlank(configureBody)) {
      return null;
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(configureBody);
    } catch (Exception ignore) {
      return null;
    }
    if (!(parsed instanceof Map<String, Object>)) {
      return null;
    }
    Map<String, Object> root = (Map<String, Object>) parsed;
    List<String> selectedKeys = new List<String>{
      'credentialId',
      'orgCredentialId',
      'selectedCredentialId',
      'selectedOrgId',
      'developmentOrgCredentialId',
      'developmentOrgCredential',
      'credential_id'
    };

    Object configObj = root.get('config');
    if (configObj instanceof Map<String, Object>) {
      Map<String, Object> config = (Map<String, Object>) configObj;
      String fromConfig = firstJsonString(config, selectedKeys);
      if (String.isNotBlank(fromConfig) && looksLikeSalesforceId(fromConfig)) {
        return fromConfig;
      }
      // Dropdown may store the credential *name* (e.g. "int") in developmentOrgCredential.
      if (String.isNotBlank(fromConfig)) {
        // Keep non-Id values only when no better Id is found below.
      }
      Object nestedCred = config.get('credential');
      if (nestedCred instanceof Map<String, Object>) {
        String nestedId = firstJsonString(
          (Map<String, Object>) nestedCred,
          new List<String>{ 'id', 'credentialId', 'orgCredentialId' }
        );
        if (String.isNotBlank(nestedId)) {
          return nestedId;
        }
      }
      // Selected row inside option lists under config
      String fromSelectedRow = extractSelectedIdFromOptionLists(config);
      if (String.isNotBlank(fromSelectedRow)) {
        return fromSelectedRow;
      }
      if (String.isNotBlank(fromConfig)) {
        return fromConfig;
      }
    }

    Object credentialObj = root.get('credential');
    if (credentialObj instanceof Map<String, Object>) {
      String fromCred = firstJsonString(
        (Map<String, Object>) credentialObj,
        new List<String>{ 'id', 'credentialId', 'orgCredentialId' }
      );
      if (String.isNotBlank(fromCred)) {
        return fromCred;
      }
    }

    String fromRoot = firstJsonString(root, selectedKeys);
    if (String.isNotBlank(fromRoot)) {
      return fromRoot;
    }

    String fromRootLists = extractSelectedIdFromOptionLists(root);
    if (String.isNotBlank(fromRootLists)) {
      return fromRootLists;
    }
    return null;
  }

  /** Display name / label for the currently selected Development Org Credential. */
  @TestVisible
  private static String extractSelectedCredentialLabel(String configureBody) {
    if (String.isBlank(configureBody)) {
      return null;
    }
    Object parsed;
    try {
      parsed = JSON.deserializeUntyped(configureBody);
    } catch (Exception ignore) {
      return null;
    }
    if (!(parsed instanceof Map<String, Object>)) {
      return null;
    }
    Map<String, Object> root = (Map<String, Object>) parsed;
    List<String> nameKeys = new List<String>{
      'credentialName',
      'orgCredentialName',
      'selectedCredentialName',
      'developmentOrgCredential',
      'developmentOrgCredentialName',
      'orgName',
      'name',
      'label',
      'value'
    };

    Object configObj = root.get('config');
    if (configObj instanceof Map<String, Object>) {
      Map<String, Object> config = (Map<String, Object>) configObj;
      String fromConfig = firstJsonString(config, nameKeys);
      // Prefer non-Id display names (e.g. "int") over accidental Id values.
      if (String.isNotBlank(fromConfig) && !looksLikeSalesforceId(fromConfig)) {
        return fromConfig;
      }
      Object nestedCred = config.get('credential');
      if (nestedCred instanceof Map<String, Object>) {
        String nestedName = firstJsonString(
          (Map<String, Object>) nestedCred,
          new List<String>{ 'name', 'label', 'orgName' }
        );
        if (String.isNotBlank(nestedName) && !looksLikeSalesforceId(nestedName)) {
          return nestedName;
        }
      }
      String fromRow = extractSelectedLabelFromOptionLists(config);
      if (String.isNotBlank(fromRow)) {
        return fromRow;
      }
    }

    Object credentialObj = root.get('credential');
    if (credentialObj instanceof Map<String, Object>) {
      String fromCred = firstJsonString(
        (Map<String, Object>) credentialObj,
        new List<String>{ 'name', 'label', 'orgName' }
      );
      if (String.isNotBlank(fromCred) && !looksLikeSalesforceId(fromCred)) {
        return fromCred;
      }
    }

    String fromRoot = firstJsonString(root, nameKeys);
    if (String.isNotBlank(fromRoot) && !looksLikeSalesforceId(fromRoot)) {
      return fromRoot;
    }
    return extractSelectedLabelFromOptionLists(root);
  }

  /**
   * True when configure JSON shows this org credential (by Id or display name)
   * as the selected Development Org Credential.
   */
  @TestVisible
  private static Boolean isTargetCredentialSelected(
    String configureBody,
    String orgCredentialId,
    String orgName
  ) {
    if (String.isBlank(configureBody) || String.isBlank(orgCredentialId)) {
      return false;
    }
    String selectedId = extractSelectedCredentialId(configureBody);
    if (credentialMatches(selectedId, orgCredentialId, orgName)) {
      return true;
    }
    if (selectedCredentialSalesforceNameMatches(selectedId, orgName)) {
      return true;
    }
    String selectedLabel = extractSelectedCredentialLabel(configureBody);
    if (credentialMatches(selectedLabel, orgCredentialId, orgName)) {
      return true;
    }
    // Walk option lists for an explicitly selected row matching Id or name.
    try {
      Object parsed = JSON.deserializeUntyped(configureBody);
      if (parsed instanceof Map<String, Object>) {
        Map<String, Object> root = (Map<String, Object>) parsed;
        if (optionListHasSelectedTarget(root, orgCredentialId, orgName)) {
          return true;
        }
        if (fieldsArrayHasSelectedTarget(root, orgCredentialId, orgName)) {
          return true;
        }
        Object configObj = root.get('config');
        if (configObj instanceof Map<String, Object>) {
          Map<String, Object> config = (Map<String, Object>) configObj;
          if (optionListHasSelectedTarget(config, orgCredentialId, orgName)) {
            return true;
          }
          if (fieldsArrayHasSelectedTarget(config, orgCredentialId, orgName)) {
            return true;
          }
        }
      }
    } catch (Exception ignore) {
    }
    return false;
  }

  /**
   * Match only scalar config values (not option lists). Avoids false positives from
   * available-org arrays that include every Dev/Int credential.
   */
  @TestVisible
  private static Boolean configScalarsMatchTarget(
    String jsonBody,
    String orgCredentialId,
    String orgName
  ) {
    if (String.isBlank(jsonBody) || String.isBlank(orgCredentialId)) {
      return false;
    }
    try {
      Object parsed = JSON.deserializeUntyped(jsonBody);
      if (!(parsed instanceof Map<String, Object>)) {
        return false;
      }
      Map<String, Object> root = (Map<String, Object>) parsed;
      List<Map<String, Object>> maps = new List<Map<String, Object>>{ root };
      Object configObj = root.get('config');
      if (configObj instanceof Map<String, Object>) {
        maps.add((Map<String, Object>) configObj);
      }
      Object credentialObj = root.get('credential');
      if (credentialObj instanceof Map<String, Object>) {
        maps.add((Map<String, Object>) credentialObj);
      }
      for (Map<String, Object> m : maps) {
        for (String key : m.keySet()) {
          Object val = m.get(key);
          if (val == null || val instanceof Map<String, Object> || val instanceof List<Object>) {
            continue;
          }
          String s = String.valueOf(val).trim();
          if (credentialMatches(s, orgCredentialId, orgName)) {
            return true;
          }
          if (selectedCredentialSalesforceNameMatches(s, orgName)) {
            return true;
          }
        }
      }
    } catch (Exception ignore) {
    }
    return false;
  }

  private static Boolean fieldsArrayHasSelectedTarget(
    Map<String, Object> container,
    String orgCredentialId,
    String orgName
  ) {
    if (container == null) {
      return false;
    }
    for (String listKey : new List<String>{ 'fields', 'properties', 'inputs', 'form' }) {
      Object listObj = container.get(listKey);
      if (!(listObj instanceof List<Object>)) {
        continue;
      }
      for (Object rowObj : (List<Object>) listObj) {
        if (!(rowObj instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> row = (Map<String, Object>) rowObj;
        String fieldName = firstJsonString(
          row,
          new List<String>{ 'name', 'key', 'id', 'field' }
        );
        String fieldVal = firstJsonString(
          row,
          new List<String>{ 'value', 'selected', 'defaultValue', 'default' }
        );
        if (String.isBlank(fieldVal)) {
          continue;
        }
        Boolean looksLikeCredField =
          String.isBlank(fieldName)
          || fieldName.toLowerCase().contains('credential')
          || fieldName.toLowerCase().contains('org')
          || fieldName.toLowerCase().contains('environment');
        if (!looksLikeCredField) {
          continue;
        }
        if (
          credentialMatches(fieldVal, orgCredentialId, orgName)
          || selectedCredentialSalesforceNameMatches(fieldVal, orgName)
        ) {
          return true;
        }
      }
    }
    return false;
  }

  private static Boolean selectedCredentialSalesforceNameMatches(
    String selectedIdOrName,
    String orgName
  ) {
    if (String.isBlank(selectedIdOrName) || String.isBlank(orgName)) {
      return false;
    }
    if (orgName.equalsIgnoreCase(selectedIdOrName)) {
      return true;
    }
    if (!looksLikeSalesforceId(selectedIdOrName)) {
      return false;
    }
    try {
      OrgInfo info = CopadoDevopsService.findOrgCredentialById(selectedIdOrName);
      return info != null
        && String.isNotBlank(info.orgName)
        && orgName.equalsIgnoreCase(info.orgName);
    } catch (Exception ignore) {
      return false;
    }
  }

  private static String firstNonBlank(String a, String b) {
    if (String.isNotBlank(a)) {
      return a;
    }
    return b;
  }

  private static Boolean optionListHasSelectedTarget(
    Map<String, Object> container,
    String orgCredentialId,
    String orgName
  ) {
    if (container == null) {
      return false;
    }
    for (String listKey : new List<String>{
      'credentialIds',
      'selectedOrgs',
      'selectedCredentials',
      'orgs',
      'credentials',
      'options',
      'availableOrgs',
      'orgCredentials'
    }) {
      Object listObj = container.get(listKey);
      if (!(listObj instanceof List<Object>)) {
        continue;
      }
      for (Object rowObj : (List<Object>) listObj) {
        if (!(rowObj instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> row = (Map<String, Object>) rowObj;
        Boolean marked =
          row.get('selected') == true
          || row.get('active') == true
          || row.get('isDefault') == true
          || row.get('default') == true
          || 'selected'.equalsIgnoreCase(String.valueOf(row.get('status')));
        if (!marked) {
          continue;
        }
        String id = firstJsonString(
          row,
          new List<String>{ 'id', 'credentialId', 'orgCredentialId', 'value' }
        );
        String name = firstJsonString(
          row,
          new List<String>{ 'name', 'label', 'orgName', 'title' }
        );
        if (credentialMatches(id, orgCredentialId, orgName)
          || credentialMatches(name, orgCredentialId, orgName)) {
          return true;
        }
      }
    }
    return false;
  }

  private static String extractSelectedIdFromOptionLists(Map<String, Object> container) {
    if (container == null) {
      return null;
    }
    for (String listKey : new List<String>{
      'credentialIds',
      'selectedOrgs',
      'selectedCredentials',
      'orgs',
      'credentials',
      'options',
      'availableOrgs',
      'orgCredentials'
    }) {
      Object listObj = container.get(listKey);
      if (!(listObj instanceof List<Object>)) {
        continue;
      }
      List<Object> rows = (List<Object>) listObj;
      if (rows.size() == 1 && rows[0] instanceof String) {
        return String.valueOf(rows[0]);
      }
      if (rows.size() == 1 && rows[0] instanceof Map<String, Object>) {
        String id = firstJsonString(
          (Map<String, Object>) rows[0],
          new List<String>{ 'id', 'credentialId', 'orgCredentialId', 'value' }
        );
        if (String.isNotBlank(id)) {
          return id;
        }
      }
      for (Object rowObj : rows) {
        if (!(rowObj instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> row = (Map<String, Object>) rowObj;
        if (row.get('selected') == true
          || row.get('active') == true
          || row.get('isDefault') == true
          || row.get('default') == true) {
          String id = firstJsonString(
            row,
            new List<String>{ 'id', 'credentialId', 'orgCredentialId', 'value' }
          );
          if (String.isNotBlank(id)) {
            return id;
          }
        }
      }
    }
    return null;
  }

  private static String extractSelectedLabelFromOptionLists(Map<String, Object> container) {
    if (container == null) {
      return null;
    }
    for (String listKey : new List<String>{
      'credentialIds',
      'selectedOrgs',
      'selectedCredentials',
      'orgs',
      'credentials',
      'options',
      'availableOrgs',
      'orgCredentials'
    }) {
      Object listObj = container.get(listKey);
      if (!(listObj instanceof List<Object>)) {
        continue;
      }
      for (Object rowObj : (List<Object>) listObj) {
        if (!(rowObj instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> row = (Map<String, Object>) rowObj;
        if (row.get('selected') == true
          || row.get('active') == true
          || row.get('isDefault') == true
          || row.get('default') == true) {
          String name = firstJsonString(
            row,
            new List<String>{ 'name', 'label', 'orgName', 'title' }
          );
          if (String.isNotBlank(name) && !looksLikeSalesforceId(name)) {
            return name;
          }
        }
      }
    }
    return null;
  }

  private static Boolean looksLikeSalesforceId(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    String v = value.trim();
    return (v.length() == 15 || v.length() == 18) && Pattern.compile('^[a-zA-Z0-9]+$').matcher(v).matches();
  }

  /**
   * True when configure's selected value is this org credential Id or its display name.
   */
  @TestVisible
  private static Boolean credentialMatches(
    String selectedValue,
    String orgCredentialId,
    String orgName
  ) {
    if (String.isBlank(selectedValue) || String.isBlank(orgCredentialId)) {
      return false;
    }
    if (orgCredentialId.equals(selectedValue)) {
      return true;
    }
    if (String.isNotBlank(orgName) && orgName.equalsIgnoreCase(selectedValue)) {
      return true;
    }
    // Environment Id vs Org Credential Id for the same org.
    try {
      String resolvedTarget = CopadoDevopsService.resolveOrgCredentialId(orgCredentialId);
      String resolvedSelected = CopadoDevopsService.resolveOrgCredentialId(selectedValue);
      if (
        String.isNotBlank(resolvedTarget)
        && String.isNotBlank(resolvedSelected)
        && resolvedTarget.equals(resolvedSelected)
      ) {
        return true;
      }
    } catch (Exception ignore) {
    }
    return false;
  }

  /**
   * Config payload shapes to select a specific org credential on a copado_cicd
   * integration. Copado leaves this free-form; GET_CONFIGURE reveals the real keys.
   */
  @TestVisible
  private static List<Map<String, Object>> buildOrgSelectAttempts(
    String orgCredentialId,
    String orgName
  ) {
    List<Map<String, Object>> attempts = new List<Map<String, Object>>();
    // Single-credential selection keys
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{ 'credentialId' => orgCredentialId }
    });
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{ 'orgCredentialId' => orgCredentialId }
    });
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{ 'orgId' => orgCredentialId }
    });
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{ 'environmentId' => orgCredentialId }
    });
    // List-of-credentials selection keys
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{
        'credentialIds' => new List<String>{ orgCredentialId }
      }
    });
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{
        'orgs' => new List<String>{ orgCredentialId }
      }
    });
    attempts.add(new Map<String, Object>{
      'config' => new Map<String, Object>{
        'selectedOrgs' => new List<String>{ orgCredentialId }
      }
    });
    // With credential block echoed too
    attempts.add(new Map<String, Object>{
      'credential' => new Map<String, Object>{ 'id' => orgCredentialId },
      'config' => new Map<String, Object>{
        'credentialId' => orgCredentialId,
        'orgCredentialId' => orgCredentialId,
        'name' => blankTo(orgName, orgCredentialId)
      }
    });
    // Copado AI UI stores the dropdown as a credential *name* (e.g. "int").
    if (String.isNotBlank(orgName)) {
      attempts.add(new Map<String, Object>{
        'config' => new Map<String, Object>{ 'developmentOrgCredential' => orgName }
      });
      attempts.add(new Map<String, Object>{
        'config' => new Map<String, Object>{
          'credentialId' => orgCredentialId,
          'developmentOrgCredential' => orgName,
          'name' => orgName
        }
      });
    }
    return attempts;
  }

  @TestVisible
  private static List<Map<String, Object>> buildCicdUpdateAttempts(String orgCredentialId) {
    List<Map<String, Object>> attempts = new List<Map<String, Object>>();
    attempts.add(new Map<String, Object>{
      'credential' => new Map<String, Object>{ 'id' => orgCredentialId },
      'config' => new Map<String, Object>{ 'credentialId' => orgCredentialId }
    });
    attempts.add(new Map<String, Object>{
      'credential' => new Map<String, Object>{ 'credentialId' => orgCredentialId },
      'config' => new Map<String, Object>{ 'orgCredentialId' => orgCredentialId }
    });
    attempts.add(new Map<String, Object>{
      'credential' => new Map<String, Object>{
        'id' => orgCredentialId,
        'credentialId' => orgCredentialId
      },
      'config' => new Map<String, Object>{
        'credentialId' => orgCredentialId,
        'credential_id' => orgCredentialId
      }
    });
    return attempts;
  }

  @TestVisible
  private static List<Map<String, Object>> buildCicdCreateAttempts(
    String workspaceId,
    String orgCredentialId,
    String orgName
  ) {
    // Match the connected "User Level" integration: USER scope, All Workspaces.
    String name = 'User Level';
    // Keep signature compatible; prefer All Workspaces (null) over Builder workspace.
    Object wsScope = null;
    if (String.isNotBlank(workspaceId) && String.isNotBlank(orgName)) {
      // no-op: documented that orgName is unused when reusing User Level naming
    }
    List<Map<String, Object>> attempts = new List<Map<String, Object>>();
    // Shape A: credential.id
    attempts.add(new Map<String, Object>{
      'name' => name,
      'workspaceId' => wsScope,
      'type' => 'copado_cicd',
      'level' => 'USER',
      'credential' => new Map<String, Object>{ 'id' => orgCredentialId },
      'config' => new Map<String, Object>{ 'credentialId' => orgCredentialId }
    });
    // Shape B: credential.credentialId
    attempts.add(new Map<String, Object>{
      'name' => name,
      'workspaceId' => wsScope,
      'type' => 'copado_cicd',
      'level' => 'USER',
      'credential' => new Map<String, Object>{ 'credentialId' => orgCredentialId },
      'config' => new Map<String, Object>{ 'orgCredentialId' => orgCredentialId }
    });
    // Shape C: MEMBER-level with config only
    attempts.add(new Map<String, Object>{
      'name' => name,
      'workspaceId' => wsScope,
      'type' => 'copado_cicd',
      'level' => 'MEMBER',
      'credential' => new Map<String, Object>{ 'id' => orgCredentialId },
      'config' => new Map<String, Object>{
        'credentialId' => orgCredentialId,
        'credential_id' => orgCredentialId
      }
    });
    return attempts;
  }

  private static String firstJsonString(Map<String, Object> row, List<String> keys) {
    if (row == null) {
      return null;
    }
    for (String key : keys) {
      if (row.containsKey(key) && row.get(key) != null) {
        String val = String.valueOf(row.get(key));
        if (String.isNotBlank(val) && val != 'null') {
          return val;
        }
      }
    }
    return null;
  }

  private static String truncateJson(String raw, Integer maxLen) {
    if (String.isBlank(raw)) {
      return raw;
    }
    Integer limitLen = maxLen == null || maxLen < 100 ? 2000 : maxLen;
    return raw.length() <= limitLen ? raw : raw.left(limitLen) + '…';
  }

  private static String blankTo(String value, String fallback) {
    return String.isNotBlank(value) ? value : fallback;
  }

  public static DocumentResult uploadDocument(String workspaceId, String fileName, String content) {
    return mockUploadDocument(workspaceId, fileName, content);
  }

  public static StoryResult createUserStory(String workspaceId, Map<String, Object> storyData) {
    if (isMockMode()) {
      return mockCreateUserStory(workspaceId, storyData);
    }
    return createCopadoUserStoryRecord(storyData);
  }

  /**
   * Ask Copado AI to turn the chat into structured Copado US field values.
   * Must run before any DML in the transaction.
   */
  public static Map<String, Object> enrichStoryDataWithAi(String dialogueId, Map<String, Object> storyData) {
    return enrichStoryDataWithAi(dialogueId, storyData, false);
  }

  /**
   * @param improveMode when true, prompt asks AI to refine from chat (including user
   *   improvement requests) for writing back onto an existing linked User Story.
   */
  public static Map<String, Object> enrichStoryDataWithAi(
    String dialogueId,
    Map<String, Object> storyData,
    Boolean improveMode
  ) {
    if (storyData == null) {
      storyData = new Map<String, Object>();
    }
    if (isMockMode() || String.isBlank(dialogueId)) {
      return storyData;
    }

    String prompt;
    if (improveMode == true) {
      prompt =
        'Improve and complete the Copado user story using our full conversation, '
        + 'including any refinement or "improve" requests from the user. '
        + 'Overwrite weak or incomplete fields with clearer values. '
        + 'Reply with ONLY valid JSON (no markdown fences, no commentary) using exactly these keys:\n'
        + '{"title":"","asA":"","wantTo":"","soThat":"","acceptanceCriteria":"","functionalSpecs":"","technicalSpecs":""}\n'
        + 'Rules:\n'
        + '- title: short clear story title (no questions)\n'
        + '- asA / wantTo / soThat: classic user-story persona lines\n'
        + '- acceptanceCriteria: testable bullets or Given/When/Then\n'
        + '- functionalSpecs: business behavior and requirements narrative\n'
        + '- technicalSpecs: Salesforce technical details (object, field label, API name, type, defaults, page layout, permissions)\n'
        + 'Use the actual field/object details we discussed. Do not ask questions.';
    } else {
      prompt =
        'Based on our full conversation, produce a complete Copado user story. '
        + 'Reply with ONLY valid JSON (no markdown fences, no commentary) using exactly these keys:\n'
        + '{"title":"","asA":"","wantTo":"","soThat":"","acceptanceCriteria":"","functionalSpecs":"","technicalSpecs":""}\n'
        + 'Rules:\n'
        + '- title: short clear story title (no questions)\n'
        + '- asA / wantTo / soThat: classic user-story persona lines\n'
        + '- acceptanceCriteria: testable bullets or Given/When/Then\n'
        + '- functionalSpecs: business behavior and requirements narrative\n'
        + '- technicalSpecs: Salesforce technical details (object, field label, API name, type, defaults, page layout, permissions)\n'
        + 'Use the actual field/object details we discussed. Do not ask questions.';
    }

    try {
      DialogueResult reply = sendDialogueMessage(dialogueId, prompt);
      Map<String, Object> parsed = parseStoryJson(reply != null ? reply.message : null);
      if (parsed != null && !parsed.isEmpty()) {
        for (String key : new List<String>{
          'title', 'asA', 'wantTo', 'soThat', 'acceptanceCriteria', 'functionalSpecs', 'technicalSpecs'
        }) {
          if (parsed.containsKey(key) && parsed.get(key) != null) {
            String value = String.valueOf(parsed.get(key)).trim();
            if (String.isNotBlank(value)) {
              storyData.put(key, value);
            }
          }
        }
      }
    } catch (Exception ignore) {
      // Keep locally parsed storyData
    }
    return storyData;
  }

  @TestVisible
  private static Map<String, Object> parseStoryJson(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String text = raw.trim();
    // Strip agent label prefixes from chat formatting
    if (text.startsWith('_') && text.contains('_\n')) {
      Integer labelEnd = text.indexOf('_\n');
      if (labelEnd > 0 && labelEnd < 40) {
        text = text.substring(labelEnd + 2).trim();
      }
    }
    // Strip markdown fences if present
    if (text.contains('```')) {
      text = text.replace('```json', '').replace('```JSON', '').replace('```', '').trim();
    }
    Integer start = text.indexOf('{');
    Integer endIdx = text.lastIndexOf('}');
    if (start < 0 || endIdx <= start) {
      return null;
    }
    text = text.substring(start, endIdx + 1);
    try {
      return (Map<String, Object>) JSON.deserializeUntyped(text);
    } catch (Exception ignore) {
      return null;
    }
  }

  /**
   * Turn raw package JSON / huge metadata dumps into a short chat-safe message.
   * Builder still uses the raw reply for Build recovery from the dialogue API.
   */
  public static String summarizeForChatDisplay(String reply) {
    if (String.isBlank(reply)) {
      return reply;
    }
    Map<String, Object> parsed = parseStoryJson(reply);
    if (parsed != null && parsed.containsKey('files') && parsed.get('files') instanceof List<Object>) {
      List<Object> rawFiles = (List<Object>) parsed.get('files');
      List<String> paths = new List<String>();
      for (Object item : rawFiles) {
        if (!(item instanceof Map<String, Object>)) {
          continue;
        }
        Object path = ((Map<String, Object>) item).get('path');
        if (path != null && String.isNotBlank(String.valueOf(path))) {
          paths.add(String.valueOf(path));
        }
      }
      if (!paths.isEmpty()) {
        String summary = parsed.get('summary') != null
          ? String.valueOf(parsed.get('summary')).trim()
          : '';
        String body = String.isNotBlank(summary)
          ? summary
          : ('Prepared a metadata package with ' + paths.size()
            + ' file' + (paths.size() == 1 ? '' : 's') + '.');
        body += '\n\n**Files**\n';
        Integer shown = 0;
        for (String p : paths) {
          if (shown >= 8) {
            body += '- …and ' + (paths.size() - shown) + ' more\n';
            break;
          }
          body += '- ' + p + '\n';
          shown++;
        }
        body += '\nClick **Build** when you are ready to capture this package in Builder.';
        return body.trim();
      }
    }

    // Huge XML / layout dumps without JSON wrapper
    String trimmed = reply.trim();
    Boolean looksLikeMetaXml =
      trimmed.contains('<CustomObject')
      || trimmed.contains('<Layout')
      || trimmed.contains('<fields>')
      || trimmed.contains('Favorite_Copado_Feature__c');
    if (looksLikeMetaXml && (trimmed.length() > 1200 || trimmed.contains('\\n'))) {
      return 'I prepared Salesforce metadata for this story (field/layout XML). '
        + 'Click **Build** to capture it as a Builder package — the raw XML is kept out of chat.';
    }

    // Literal \n sequences from JSON-escaped content pasted as chat text
    if (trimmed.contains('\\n') && !trimmed.contains('\n') && trimmed.length() > 400) {
      return 'I prepared a detailed metadata reply that is too dense for chat. '
        + 'Click **Build** to capture the package, or ask me to summarize the change in plain language.';
    }

    return reply;
  }

  /**
   * Creates or updates a real Copado User Story in Salesforce (copado__User_Story__c).
   * Maps Title, As a / Want to / So that, Acceptance Criteria, Functional & Technical Specs.
   */
  @TestVisible
  private static StoryResult createCopadoUserStoryRecord(Map<String, Object> storyData) {
    Schema.SObjectType usType = Schema.getGlobalDescribe().get('copado__User_Story__c');
    if (usType == null) {
      throw new ApiException(
        'Copado User Story object (copado__User_Story__c) is not installed or not visible in this org.'
      );
    }

    Map<String, Schema.SObjectField> fields = usType.getDescribe().fields.getMap();
    Map<String, String> byLabel = buildCreateableLabelMap(fields);

    String title = strVal(storyData, 'title', 'Builder Story');
    title = truncateText(title, 255);
    if (String.isBlank(title) || title.contains('?')) {
      title = 'Builder Story';
    }

    String asA = strVal(storyData, 'asA', '');
    String wantTo = strVal(storyData, 'wantTo', '');
    String soThat = strVal(storyData, 'soThat', '');
    String acceptance = strVal(storyData, 'acceptanceCriteria', '');
    String functional = strVal(storyData, 'functionalSpecs', '');
    String technical = strVal(storyData, 'technicalSpecs', '');
    String description = strVal(storyData, 'description', '');
    if (String.isBlank(functional)) {
      functional = description;
    }

    Id recordTypeId = resolveUserStoryRecordTypeId(usType);
    if (recordTypeId == null) {
      throw new ApiException(
        'Could not find the Copado "User Story" record type. '
        + 'Create the story manually once and confirm the User Story record type is active.'
      );
    }

    Id projectId = null;
    String requestedProjectId = strVal(storyData, 'projectId', '');
    if (String.isNotBlank(requestedProjectId)) {
      try {
        projectId = (Id) requestedProjectId;
      } catch (Exception ex) {
        throw new ApiException('Invalid Copado Project Id selected.');
      }
    } else {
      projectId = resolveCopadoProjectId(fields);
    }
    Id existingId = null;
    Boolean updateExisting = storyData != null && storyData.get('updateExisting') == true;
    String targetStoryId = strVal(storyData, 'targetStoryId', '');

    if (String.isNotBlank(targetStoryId)) {
      try {
        existingId = (Id) targetStoryId;
        updateExisting = true;
      } catch (Exception ex) {
        throw new ApiException('Invalid Copado User Story Id selected for update.');
      }
    } else if (updateExisting) {
      existingId = findExistingStoryId(strVal(storyData, 'existingStoryRef', ''));
      if (existingId == null) {
        throw new ApiException(
          'No Copado User Story selected. Pick a story to update, or use Create Copado Story.'
        );
      }
    } else {
      existingId = null;
    }

    SObject us = usType.newSObject();
    Boolean isUpdate = existingId != null;
    if (isUpdate) {
      us.put('Id', existingId);
    } else {
      us.put('RecordTypeId', recordTypeId);
      if (projectId != null) {
        putFieldSmart(us, fields, byLabel, new List<String>{'copado__Project__c', 'Project__c'}, new List<String>{'project'}, projectId);
      }
    }

    // Title
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__User_Story_Title__c', 'User_Story_Title__c'},
      new List<String>{'title', 'user story title'},
      title
    );

    // Persona fields (labels from Copado layout: As a..., Want to..., So that...)
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__As_a__c', 'As_a__c', 'copado__As_A__c'},
      new List<String>{'as a', 'as a...'},
      asA
    );
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__I_want_to__c', 'I_want_to__c', 'copado__Want_to__c', 'Want_to__c'},
      new List<String>{'want to', 'want to...', 'i want to'},
      wantTo
    );
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__So_that__c', 'So_that__c'},
      new List<String>{'so that', 'so that...'},
      soThat
    );

    // Specs
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__Acceptance_Criteria__c', 'Acceptance_Criteria__c'},
      new List<String>{'acceptance criteria', 'acceptance'},
      acceptance
    );
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__Functional_Specifications__c', 'Functional_Specifications__c'},
      new List<String>{'functional specifications', 'functional specs'},
      functional
    );
    putFieldSmart(
      us,
      fields,
      byLabel,
      new List<String>{'copado__Technical_Specifications__c', 'Technical_Specifications__c'},
      new List<String>{'technical specifications', 'technical specs'},
      technical
    );

    if (!isUpdate) {
      putFieldSmart(
        us,
        fields,
        byLabel,
        new List<String>{'copado__Status__c', 'Status__c'},
        new List<String>{'status'},
        'Draft'
      );
    }

    try {
      if (isUpdate) {
        update us;
      } else {
        insert us;
      }
    } catch (DmlException dml) {
      throw new ApiException(
        'Could not ' + (isUpdate ? 'update' : 'insert') + ' Copado User Story: ' + dml.getDmlMessage(0)
        + (projectId == null && fields.containsKey('copado__Project__c') && !isUpdate
          ? ' Tip: ensure at least one Copado Project exists, or Project may be required.'
          : '')
      );
    }

    Id storySalesforceId = isUpdate ? existingId : (Id) us.get('Id');
    String storyNumber = String.valueOf(storySalesforceId);
    String storyTitle = title;
    try {
      List<SObject> rows = Database.query(
        'SELECT Id, Name, copado__User_Story_Title__c FROM copado__User_Story__c WHERE Id = \''
        + String.escapeSingleQuotes(storySalesforceId)
        + '\' LIMIT 1'
      );
      if (!rows.isEmpty()) {
        if (rows[0].get('Name') != null) {
          storyNumber = String.valueOf(rows[0].get('Name'));
        }
        if (rows[0].get('copado__User_Story_Title__c') != null) {
          storyTitle = String.valueOf(rows[0].get('copado__User_Story_Title__c'));
        }
      }
    } catch (Exception ignore) {
      // best-effort
    }

    StoryResult result = new StoryResult();
    result.storyId = storyNumber;
    result.storyName = storyTitle;
    result.recordId = String.valueOf(storySalesforceId);
    result.summary =
      (isUpdate ? 'Updated' : 'Created') + ' Copado user story ' + storyNumber + ': "' + storyTitle + '". '
      + 'Title, persona fields, acceptance criteria, and specs were populated from the chat draft.';
    result.status = 'Draft';
    return result;
  }

  private static String strVal(Map<String, Object> data, String key, String fallback) {
    if (data == null || !data.containsKey(key) || data.get(key) == null) {
      return fallback;
    }
    String value = String.valueOf(data.get(key)).trim();
    return String.isBlank(value) ? fallback : value;
  }

  private static Id findExistingStoryId(String existingRef) {
    if (String.isBlank(existingRef)) {
      return null;
    }
    String ref = existingRef.trim();

    // Preferred format: recordId||US-Name||Title
    if (ref.contains('||')) {
      String idPart = ref.split('\\|\\|', 2)[0].trim();
      try {
        return (Id) idPart;
      } catch (Exception ignore) {
      }
    }

    // Legacy: "US-0000036 — Title" or "US-0000036 - Title"
    Matcher usName = System.Pattern.compile('(US-\\d+)').matcher(ref);
    String token = ref;
    if (usName.find()) {
      token = usName.group(1);
    } else if (ref.contains('—')) {
      token = ref.split('—')[0].trim();
    } else if (ref.contains(' - ')) {
      token = ref.split(' - ')[0].trim();
    }

    try {
      // Direct Id?
      if (token.length() >= 15 && token.length() <= 18) {
        return (Id) token;
      }
    } catch (Exception ignore) {
    }

    try {
      List<SObject> rows = Database.query(
        'SELECT Id FROM copado__User_Story__c WHERE Name = \''
        + String.escapeSingleQuotes(token)
        + '\' LIMIT 1'
      );
      return rows.isEmpty() ? null : (Id) rows[0].get('Id');
    } catch (Exception ignore) {
      return null;
    }
  }

  private static Map<String, String> buildCreateableLabelMap(Map<String, Schema.SObjectField> fields) {
    Map<String, String> byLabel = new Map<String, String>();
    for (String api : fields.keySet()) {
      Schema.DescribeFieldResult d = fields.get(api).getDescribe();
      if (!d.isUpdateable() && !d.isCreateable()) {
        continue;
      }
      if (String.isBlank(d.getLabel())) {
        continue;
      }
      byLabel.put(normalizeLabel(d.getLabel()), api);
    }
    return byLabel;
  }

  private static String normalizeLabel(String label) {
    if (label == null) return '';
    return label.toLowerCase().replace('...', '').replace('.', '').trim();
  }

  private static Boolean putFieldSmart(
    SObject record,
    Map<String, Schema.SObjectField> fields,
    Map<String, String> byLabel,
    List<String> apiCandidates,
    List<String> labelCandidates,
    Object value
  ) {
    if (value == null || String.isBlank(String.valueOf(value))) {
      return false;
    }
    for (String api : apiCandidates) {
      if (putIfWritable(record, fields, api, value)) {
        return true;
      }
    }
    for (String label : labelCandidates) {
      String api = byLabel.get(normalizeLabel(label));
      if (api != null && putIfWritable(record, fields, api, value)) {
        return true;
      }
    }
    return false;
  }

  private static Boolean putIfWritable(
    SObject record,
    Map<String, Schema.SObjectField> fields,
    String apiName,
    Object value
  ) {
    if (!fields.containsKey(apiName)) {
      return false;
    }
    Schema.DescribeFieldResult d = fields.get(apiName).getDescribe();
    Boolean hasId = record.get('Id') != null;
    if (hasId && !d.isUpdateable()) {
      return false;
    }
    if (!hasId && !d.isCreateable()) {
      return false;
    }
    // Truncate strings to field length when known
    if (value instanceof String && d.getLength() != null && d.getLength() > 0) {
      value = truncateText((String) value, d.getLength());
    }
    record.put(apiName, value);
    return true;
  }

  private static Id resolveUserStoryRecordTypeId(Schema.SObjectType usType) {
    Map<String, Schema.RecordTypeInfo> byDevName = usType.getDescribe().getRecordTypeInfosByDeveloperName();
    Map<String, Schema.RecordTypeInfo> byName = usType.getDescribe().getRecordTypeInfosByName();

    List<String> preferredDevNames = new List<String>{
      'User_Story',
      'UserStory',
      'copado__User_Story',
      'US'
    };
    for (String devName : preferredDevNames) {
      if (byDevName.containsKey(devName)) {
        Schema.RecordTypeInfo info = byDevName.get(devName);
        if (info.isAvailable()) {
          return info.getRecordTypeId();
        }
      }
    }

    List<String> preferredLabels = new List<String>{
      'User Story',
      'User story'
    };
    for (String label : preferredLabels) {
      if (byName.containsKey(label)) {
        Schema.RecordTypeInfo info = byName.get(label);
        if (info.isAvailable() && !info.isMaster()) {
          return info.getRecordTypeId();
        }
      }
    }

    // Last resort: first available non-master record type whose name contains "user story"
    for (Schema.RecordTypeInfo info : byName.values()) {
      if (info.isAvailable()
        && !info.isMaster()
        && info.getName() != null
        && info.getName().toLowerCase().contains('user story')) {
        return info.getRecordTypeId();
      }
    }
    return null;
  }

  private static Id resolveCopadoProjectId(Map<String, Schema.SObjectField> usFields) {
    Boolean hasProject =
      usFields.containsKey('copado__Project__c') || usFields.containsKey('Project__c');
    if (!hasProject) {
      return null;
    }
    if (Schema.getGlobalDescribe().get('copado__Project__c') == null) {
      return null;
    }
    List<SObject> projects = Database.query(
      'SELECT Id FROM copado__Project__c ORDER BY LastModifiedDate DESC LIMIT 1'
    );
    return projects.isEmpty() ? null : (Id) projects[0].get('Id');
  }

  private static Boolean putIfCreateable(
    SObject record,
    Map<String, Schema.SObjectField> fields,
    String apiName,
    Object value
  ) {
    if (value == null || String.isBlank(String.valueOf(value))) {
      return false;
    }
    if (!fields.containsKey(apiName)) {
      return false;
    }
    Schema.DescribeFieldResult d = fields.get(apiName).getDescribe();
    if (!d.isCreateable()) {
      return false;
    }
    record.put(apiName, value);
    return true;
  }

  private static String truncateText(String value, Integer maxLen) {
    if (String.isBlank(value) || maxLen == null || maxLen <= 0) {
      return value;
    }
    String clean = value.trim();
    return clean.length() <= maxLen ? clean : clean.substring(0, maxLen);
  }

  public static BuildResult buildCode(String storyId, String requirements) {
    return buildCode(null, storyId, requirements, null);
  }

  /**
   * Generate a Salesforce metadata package for the linked user story via Copado AI.
   * Callouts only — no DML.
   */
  public static BuildResult buildCode(
    String dialogueId,
    String storyLabel,
    String requirements,
    String storyContext
  ) {
    if (isMockMode()) {
      return mockBuildCode(storyLabel, requirements);
    }
    return generatePackageWithAi(dialogueId, storyLabel, requirements, storyContext);
  }

  public static BuildResult reviewCode(String storyId, String buildId) {
    return reviewCode(null, storyId, buildId, null);
  }

  public static BuildResult reviewCode(
    String dialogueId,
    String storyLabel,
    String buildId,
    String packageJson
  ) {
    if (isMockMode()) {
      return mockReviewCode(storyLabel, buildId);
    }
    return reviewPackageWithAi(dialogueId, storyLabel, buildId, packageJson);
  }

  public static TestResult createTests(String storyId, String buildId) {
    return createTests(null, storyId, buildId, null);
  }

  public static TestResult createTests(
    String dialogueId,
    String storyLabel,
    String buildId,
    String packageJson
  ) {
    if (isMockMode()) {
      return mockCreateTests(storyLabel, buildId);
    }
    return createTestsWithAi(dialogueId, storyLabel, buildId, packageJson);
  }

  public static DeployResult deployToOrg(String storyId, String orgId, String orgName) {
    // Deploy is handled by CopadoDevopsService; keep mock for legacy callers/tests.
    return mockDeployToOrg(storyId, orgId, orgName);
  }

  public static List<OrgInfo> listPipelineOrgs() {
    return CopadoDevopsService.listPipelineOrgs();
  }

  /** Exposed for CopadoDevopsService fallback / tests. */
  public static List<OrgInfo> mockListPipelineOrgsPublic() {
    return mockListPipelineOrgs();
  }

  @TestVisible
  private static BuildResult generatePackageWithAi(
    String dialogueId,
    String storyLabel,
    String requirements,
    String storyContext
  ) {
    if (String.isBlank(dialogueId)) {
      throw new ApiException('Dialogue is required to generate code. Continue chatting first.');
    }

    // Keep enough room for long picklist value lists (30+ values) in the prompt.
    String contextBlock = truncateText(
      String.isNotBlank(storyContext) ? storyContext : requirements,
      12000
    );
    if (String.isBlank(contextBlock) || contextBlock.trim().length() < 12) {
      throw new ApiException(
        'Build needs story specs (field/object details). Improve Story or paste requirements, then Build again.'
      );
    }
    String prompt =
      'Generate Salesforce metadata for this Copado user story: '
      + storyLabel + '.\n'
      + 'Use the specs below (prefer these over re-reading the whole chat):\n'
      + contextBlock + '\n\n'
      + 'Reply with ONLY valid JSON (no markdown, no questions):\n'
      + '{"summary":"one sentence","files":[{"path":"force-app/main/default/...","content":"..."}]}\n'
      + 'Rules: smallest package (1-6 files); paths start with force-app/; complete deployable '
      + 'XML/Apex; escape newlines in content as \\n; follow FLS exactly as specified; '
      + 'include EVERY picklist value from the specs (do not truncate the list); '
      + 'when the story says add the field to a page layout, include field + profile + layout '
      + 'ONLY with the exact live Layout fullName already known from Org Intelligence in this chat '
      + '(never invent Account-Account Layout / Object-Object Layout); '
      + 'if the live layout fullName is unknown, omit layout and note that in summary; '
      + 'layout XML must contain required Name plus the new custom field.';

    DialogueResult packageReply = requestPackageReplyResult(dialogueId, prompt);
    String rawReply = packageReply != null ? packageReply.message : null;
    Map<String, Object> parsed = parseStoryJson(rawReply);

    // Prefer recovering a package already on the dialogue over firing a second
    // generation while the first reply may still be streaming.
    if (parsed == null || !parsed.containsKey('files')) {
      String recovered = findLatestPackageJsonInDialogue(dialogueId);
      if (String.isNotBlank(recovered)) {
        rawReply = recovered;
        parsed = parseStoryJson(rawReply);
      }
    }

    if (parsed == null || !parsed.containsKey('files')) {
      // Only retry with a STOP prompt when we got prose (not empty/timeout).
      if (String.isNotBlank(rawReply)) {
        String retryPrompt =
          'STOP. Return ONLY package JSON now (no questions):\n'
          + '{"summary":"one sentence","files":[{"path":"force-app/main/default/...","content":"..."}]}\n'
          + 'Include every picklist value from the specs. Implement from these specs:\n'
          + truncateText(contextBlock, 8000);
        packageReply = requestPackageReplyResult(dialogueId, retryPrompt);
        rawReply = packageReply != null ? packageReply.message : null;
        parsed = parseStoryJson(rawReply);
        if (parsed == null || !parsed.containsKey('files')) {
          String recovered = findLatestPackageJsonInDialogue(dialogueId);
          if (String.isNotBlank(recovered)) {
            rawReply = recovered;
            parsed = parseStoryJson(rawReply);
          }
        }
      } else {
        // Still empty — brief wait, then soft-pending so LWC can poll + nudge.
        // Do not burn the whole Apex transaction here (that caused silent stalls).
        rawReply = waitBrieflyForPackageReply(dialogueId);
        parsed = parseStoryJson(rawReply);
        if (parsed == null || !parsed.containsKey('files')) {
          String recovered = findLatestPackageJsonInDialogue(dialogueId);
          if (String.isNotBlank(recovered)) {
            rawReply = recovered;
            parsed = parseStoryJson(rawReply);
          }
        }
      }
    }

    if (parsed == null || !parsed.containsKey('files')) {
      // Soft-pending: let Builder poll across transactions instead of failing hard.
      BuildResult pending = new BuildResult();
      pending.pending = true;
      pending.status = 'pending';
      pending.buildId = 'pending-build';
      pending.summary = 'Copado AI is still generating the metadata package.';
      pending.artifacts = new List<String>();
      pending.dialogueId = packageReply != null && String.isNotBlank(packageReply.dialogueId)
        ? packageReply.dialogueId
        : dialogueId;
      pending.requestId = packageReply != null ? packageReply.requestId : null;
      pending.baselineMessageCount = packageReply != null ? packageReply.baselineMessageCount : null;
      pending.baselineAssistantText = packageReply != null ? packageReply.baselineAssistantText : null;
      return pending;
    }

    List<Object> rawFiles = (List<Object>) parsed.get('files');
    if (rawFiles == null || rawFiles.isEmpty()) {
      throw new ApiException('Copado AI returned an empty metadata package.');
    }

    List<Map<String, Object>> files = new List<Map<String, Object>>();
    List<String> artifacts = new List<String>();
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = (Map<String, Object>) item;
      String path = fileMap.get('path') != null ? String.valueOf(fileMap.get('path')).trim() : '';
      String content = fileMap.get('content') != null ? String.valueOf(fileMap.get('content')) : '';
      if (String.isBlank(path) || !path.startsWith('force-app/') || String.isBlank(content)) {
        continue;
      }
      // Reject path traversal
      if (path.contains('..')) {
        continue;
      }
      content = sanitizePackageFileContent(path, content);
      if (String.isBlank(content)) {
        continue;
      }
      files.add(new Map<String, Object>{ 'path' => path, 'content' => content });
      artifacts.add(path);
    }
    if (files.isEmpty()) {
      throw new ApiException('No valid force-app/ files in the AI package.');
    }

    Map<String, Object> packageBody = new Map<String, Object>{
      'summary' => parsed.get('summary') != null
        ? String.valueOf(parsed.get('summary'))
        : 'Generated metadata package for ' + storyLabel,
      'story' => storyLabel,
      'files' => files,
      'generatedAt' => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
    };

    // Deterministic gate: never persist invented English default layout names;
    // drop other gated types missing from AUTHORITATIVE LIVE METADATA.
    String packageJson = CopadoDevopsService.normalizePackageMetadataWithContext(
      JSON.serialize(packageBody),
      contextBlock
    );
    try {
      Map<String, Object> normalized =
        (Map<String, Object>) JSON.deserializeUntyped(packageJson);
      if (normalized != null && normalized.get('files') instanceof List<Object>) {
        packageBody = normalized;
        artifacts = new List<String>();
        for (Object item : (List<Object>) normalized.get('files')) {
          if (item instanceof Map<String, Object>) {
            Object p = ((Map<String, Object>) item).get('path');
            if (p != null) {
              artifacts.add(String.valueOf(p));
            }
          }
        }
        packageJson = JSON.serialize(packageBody);
      }
    } catch (Exception ignore) {
      packageJson = JSON.serialize(packageBody);
    }

    BuildResult result = new BuildResult();
    result.buildId = 'bld-' + EncodingUtil.convertToHex(Crypto.generateAESKey(128)).substring(0, 12);
    result.status = 'success';
    result.artifacts = artifacts;
    result.packageJson = packageJson;
    result.summary = String.valueOf(packageBody.get('summary'))
      + ' Artifacts: ' + String.join(artifacts, ', ') + '.';
    return result;
  }

  /**
   * Ask Build agent for a metadata package reply (JSON). Polls longer than chat.
   */
  private static String requestPackageReply(String dialogueId, String prompt) {
    DialogueResult reply = requestPackageReplyResult(dialogueId, prompt);
    return reply != null ? reply.message : null;
  }

  private static DialogueResult requestPackageReplyResult(String dialogueId, String prompt) {
    DialogueResult reply = sendDialogueMessage(
      dialogueId,
      prompt,
      null,
      ASSISTANT_BUILD,
      null,
      PACKAGE_BUILD_SYSTEM_PROMPT
    );
    if (reply == null) {
      reply = new DialogueResult();
      reply.dialogueId = dialogueId;
      reply.pending = true;
      reply.message = '';
      return reply;
    }
    if (String.isNotBlank(reply.message)) {
      return reply;
    }
    // Package generation often outlives the first poll window — keep waiting briefly.
    // Longer waits belong in LWC pollBuildPackage (with mid-poll nudges).
    if (String.isNotBlank(reply.dialogueId)) {
      try {
        Settings settings = getSettings();
        DialogueSnapshot before = new DialogueSnapshot();
        before.messageCount = reply.baselineMessageCount != null ? reply.baselineMessageCount : 0;
        before.lastAssistantText = reply.baselineAssistantText;
        String waited = waitForAssistantReply(
          settings.organizationId,
          reply.dialogueId,
          reply.requestId,
          6,
          before
        );
        if (String.isNotBlank(waited)) {
          reply.message = waited;
          reply.pending = false;
          return reply;
        }
        String latest = pollAssistantText(
          reply.dialogueId,
          reply.requestId,
          reply.baselineMessageCount,
          reply.baselineAssistantText
        );
        if (String.isNotBlank(latest)) {
          reply.message = latest;
          reply.pending = false;
          return reply;
        }
      } catch (Exception ignore) {
      }
    }
    reply.pending = true;
    return reply;
  }

  /**
   * Public recover helper for Builder pollBuildPackage.
   * Keep this cheap — LWC polls across transactions; do not run the long
   * waitLongerForPackageReply loop on every poll (governor / timeout risk).
   */
  public static String tryRecoverPackageJson(String dialogueId) {
    if (String.isBlank(dialogueId)) {
      return null;
    }
    String found = findLatestPackageJsonInDialogue(dialogueId);
    if (String.isNotBlank(found)) {
      return found;
    }
    // Brief extra wait in case the reply landed mid-request.
    String waited = waitBrieflyForPackageReply(dialogueId);
    Map<String, Object> parsed = parseStoryJson(waited);
    if (parsed != null && parsed.containsKey('files')) {
      return waited;
    }
    return findLatestPackageJsonInDialogue(dialogueId);
  }

  /**
   * Mid-poll nudge: Copado AI often returns prose / empty on the first Build turn.
   * Re-prompt with a hard STOP so simple CustomField packages do not sit until timeout.
   */
  public static String nudgePackageGeneration(
    String dialogueId,
    String storyLabel,
    String storyContext
  ) {
    if (String.isBlank(dialogueId) || isMockMode()) {
      return null;
    }
    String contextBlock = truncateText(blankTo(storyContext, ''), 8000);
    String prompt =
      'STOP. Your previous reply was not usable package JSON. '
      + 'Return ONLY valid JSON now (no markdown, no questions, no tools):\n'
      + '{"summary":"one sentence","files":[{"path":"force-app/main/default/...","content":"..."}]}\n'
      + 'Story: ' + blankTo(storyLabel, 'user story') + '\n'
      + 'Specs:\n' + contextBlock + '\n'
      + 'Rules: 1-6 force-app files; complete deployable XML; escape newlines as \\n; '
      + 'include every picklist value listed in the specs; '
      + 'if specs require a page layout, include field + profile + layout only with the exact '
      + 'live Layout fullName from Org Intelligence (never invent Account-Account Layout).';
    DialogueResult reply = requestPackageReplyResult(dialogueId, prompt);
    String raw = reply != null ? reply.message : null;
    Map<String, Object> parsed = parseStoryJson(raw);
    if (parsed != null && parsed.containsKey('files')) {
      return raw;
    }
    return findLatestPackageJsonInDialogue(dialogueId);
  }

  /**
   * Harden AI package files before persist/deploy.
   * Layout stubs missing required fields fail Salesforce deploy. Inject common
   * required-on-layout fields (Name, and ParentId for Account) so the artifact
   * stays in the package. Deploy Function must still retrieve-merge the live org
   * layout — stubs must never replace the real page layout as-is.
   */
  @TestVisible
  private static String sanitizePackageFileContent(String path, String content) {
    if (String.isBlank(path) || String.isBlank(content)) {
      return content;
    }
    String lowerPath = path.toLowerCase();
    if (!lowerPath.endsWith('.layout-meta.xml') && !lowerPath.endsWith('.layout')) {
      return content;
    }
    content = ensureLayoutHasField(content, 'Name', true);
    // Account layouts in many orgs treat ParentId as required-on-layout.
    if (lowerPath.contains('account-') || lowerPath.contains('/account')) {
      content = ensureLayoutHasField(content, 'ParentId', false);
    }
    return content;
  }

  /**
   * Ensure Layout XML includes a layoutItems entry for the given field API name.
   */
  @TestVisible
  private static String ensureLayoutHasField(String content, String fieldApiName, Boolean required) {
    if (String.isBlank(content) || String.isBlank(fieldApiName)) {
      return content;
    }
    String compact = content.replace(' ', '').replace('\n', '').replace('\r', '').replace('\t', '');
    String needle = '<field>' + fieldApiName.toLowerCase() + '</field>';
    if (compact.toLowerCase().contains(needle)) {
      return content;
    }
    String behavior = required == true ? 'Required' : 'Edit';
    String item =
      '<layoutItems>'
      + '<behavior>' + behavior + '</behavior>'
      + '<field>' + fieldApiName + '</field>'
      + '</layoutItems>';
    Integer colsIdx = content.indexOf('<layoutColumns>');
    if (colsIdx < 0) {
      colsIdx = content.toLowerCase().indexOf('<layoutcolumns>');
    }
    if (colsIdx >= 0) {
      Integer gt = content.indexOf('>', colsIdx);
      if (gt > colsIdx) {
        return content.substring(0, gt + 1) + item + content.substring(gt + 1);
      }
    }
    Integer rootClose = content.toLowerCase().lastIndexOf('</layout>');
    if (rootClose > 0) {
      String section =
        '<layoutSections>'
        + '<customLabel>false</customLabel>'
        + '<detailHeading>false</detailHeading>'
        + '<editHeading>true</editHeading>'
        + '<label>Information</label>'
        + '<layoutColumns>'
        + item
        + '</layoutColumns>'
        + '<layoutColumns/>'
        + '<style>TwoColumnsTopToBottom</style>'
        + '</layoutSections>';
      return content.substring(0, rootClose) + section + content.substring(rootClose);
    }
    return content;
  }

  /** @deprecated Use ensureLayoutHasField — kept name for older call sites. */
  @TestVisible
  private static String ensureLayoutHasRequiredName(String content) {
    return ensureLayoutHasField(content, 'Name', true);
  }

  /** Short poll (few GETs) — for use inside pollBuildPackage. */
  private static String waitBrieflyForPackageReply(String dialogueId) {
    if (String.isBlank(dialogueId)) {
      return null;
    }
    try {
      Settings settings = getSettings();
      DialogueSnapshot before = readDialogueSnapshot(settings.organizationId, dialogueId);
      return waitForAssistantReply(
        settings.organizationId,
        dialogueId,
        null,
        3,
        before
      );
    } catch (Exception ignore) {
      return null;
    }
  }

  /** Build a completed BuildResult from raw package JSON text. */
  public static BuildResult buildResultFromPackageJson(String rawReply, String storyLabel) {
    Map<String, Object> parsed = parseStoryJson(rawReply);
    if (parsed == null || !parsed.containsKey('files')) {
      return null;
    }
    List<Object> rawFiles = (List<Object>) parsed.get('files');
    if (rawFiles == null || rawFiles.isEmpty()) {
      return null;
    }
    List<Map<String, Object>> files = new List<Map<String, Object>>();
    List<String> artifacts = new List<String>();
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = (Map<String, Object>) item;
      String path = fileMap.get('path') != null ? String.valueOf(fileMap.get('path')).trim() : '';
      String content = fileMap.get('content') != null ? String.valueOf(fileMap.get('content')) : '';
      if (String.isBlank(path) || !path.startsWith('force-app/') || String.isBlank(content)) {
        continue;
      }
      if (path.contains('..')) {
        continue;
      }
      content = sanitizePackageFileContent(path, content);
      if (String.isBlank(content)) {
        continue;
      }
      files.add(new Map<String, Object>{ 'path' => path, 'content' => content });
      artifacts.add(path);
    }
    if (files.isEmpty()) {
      return null;
    }
    BuildResult result = new BuildResult();
    result.pending = false;
    result.buildId = 'build-' + String.valueOf(Datetime.now().getTime());
    result.status = 'success';
    result.artifacts = artifacts;
    result.packageJson = JSON.serialize(
      new Map<String, Object>{
        'summary' => parsed.get('summary') != null
          ? String.valueOf(parsed.get('summary'))
          : ('Package for ' + blankTo(storyLabel, 'story')),
        'files' => files
      }
    );
    result.summary =
      'Generated '
      + files.size()
      + ' metadata file'
      + (files.size() == 1 ? '' : 's')
      + ' for '
      + blankTo(storyLabel, 'story')
      + '. Artifacts: '
      + String.join(artifacts, ', ')
      + '.';
    return result;
  }

  /** Extended wait without sending another prompt (avoids stacking generations). */
  private static String waitLongerForPackageReply(String dialogueId) {
    if (String.isBlank(dialogueId)) {
      return null;
    }
    try {
      Settings settings = getSettings();
      DialogueSnapshot before = readDialogueSnapshot(settings.organizationId, dialogueId);
      return waitForAssistantReply(
        settings.organizationId,
        dialogueId,
        null,
        20,
        before
      );
    } catch (Exception ignore) {
      return null;
    }
  }

  /**
   * Scan recent dialogue messages for a parseable package JSON ({"files":[...]}).
   * Uses raw content (not only "usable" assistant text) so we still recover when
   * Copado AI wraps JSON or leaves tool/thinking noise in the same turn.
   */
  @TestVisible
  private static String findLatestPackageJsonInDialogue(String dialogueId) {
    if (String.isBlank(dialogueId) || isMockMode()) {
      return null;
    }
    try {
      Settings settings = getSettings();
      requireOrgId(settings);
      HttpResponse res = sendRequest(
        'GET',
        '/organizations/' + settings.organizationId + '/dialogues/' + dialogueId,
        null,
        20000
      );
      if (res.getStatusCode() < 200 || res.getStatusCode() >= 300 || String.isBlank(res.getBody())) {
        return null;
      }
      Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
      List<Object> messages = asObjectList(data.get('messages'));
      if (messages == null) {
        messages = asObjectList(data.get('Messages'));
      }
      if (messages == null || messages.isEmpty()) {
        return null;
      }
      Integer scanned = 0;
      for (Integer i = messages.size() - 1; i >= 0 && scanned < 20; i--) {
        if (!(messages[i] instanceof Map<String, Object>)) {
          continue;
        }
        Map<String, Object> msg = (Map<String, Object>) messages[i];
        String role = msg.containsKey('role') ? String.valueOf(msg.get('role')) : '';
        if (
          String.isNotBlank(role)
          && !'assistant'.equalsIgnoreCase(role)
          && !'ai'.equalsIgnoreCase(role)
        ) {
          continue;
        }
        scanned++;
        // Prefer clean usable text, then raw extract (includes non-text parts).
        List<String> candidates = new List<String>();
        String usable = usableAssistantContent(messages[i]);
        if (String.isNotBlank(usable)) {
          candidates.add(usable);
        }
        String raw = extractMessageContent(msg, false);
        if (String.isNotBlank(raw) && (usable == null || !raw.equals(usable))) {
          candidates.add(raw);
        }
        // Last resort: serialize message JSON and hunt for {"files":
        String messageJson = JSON.serialize(msg);
        if (String.isNotBlank(messageJson) && messageJson.contains('"files"')) {
          candidates.add(messageJson);
        }
        for (String candidate : candidates) {
          Map<String, Object> parsed = parseStoryJson(candidate);
          if (parsed != null && parsed.containsKey('files')) {
            List<Object> files = (List<Object>) parsed.get('files');
            if (files != null && !files.isEmpty()) {
              return candidate;
            }
          }
        }
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  @TestVisible
  private static BuildResult reviewPackageWithAi(
    String dialogueId,
    String storyLabel,
    String buildId,
    String packageJson
  ) {
    if (String.isBlank(dialogueId)) {
      return mockReviewCode(storyLabel, buildId);
    }
    String prompt =
      'Review this Salesforce metadata package for user story ' + storyLabel
      + ' (build ' + buildId + '). '
      + 'Reply with ONLY JSON: {"summary":"","status":"success|warning|failed","artifacts":["finding1","finding2"]}\n'
      + 'Package:\n' + truncateText(packageJson, 6000);

    DialogueResult reply = sendDialogueMessage(dialogueId, prompt);
    Map<String, Object> parsed = parseStoryJson(reply != null ? reply.message : null);
    BuildResult result = new BuildResult();
    result.buildId = buildId;
    result.status = 'success';
    result.artifacts = new List<String>();
    if (parsed != null) {
      if (parsed.get('summary') != null) {
        result.summary = String.valueOf(parsed.get('summary'));
      }
      if (parsed.get('status') != null) {
        result.status = String.valueOf(parsed.get('status'));
      }
      if (parsed.get('artifacts') instanceof List<Object>) {
        for (Object a : (List<Object>) parsed.get('artifacts')) {
          result.artifacts.add(String.valueOf(a));
        }
      }
    }
    if (String.isBlank(result.summary)) {
      result.summary = 'Code review complete for build ' + buildId + '.';
    }
    return result;
  }

  @TestVisible
  private static TestResult createTestsWithAi(
    String dialogueId,
    String storyLabel,
    String buildId,
    String packageJson
  ) {
    if (String.isBlank(dialogueId)) {
      return mockCreateTests(storyLabel, buildId);
    }
    String prompt =
      'Propose Apex unit tests for user story ' + storyLabel
      + ' (build ' + buildId + '). '
      + 'Reply with ONLY JSON: {"summary":"","testCount":0,"status":"success","artifacts":["TestClass.cls"]}\n'
      + 'Also include a "files" array with force-app test class paths/content when possible.\n'
      + 'Package under test:\n' + truncateText(packageJson, 5000);

    DialogueResult reply = sendDialogueMessage(dialogueId, prompt);
    Map<String, Object> parsed = parseStoryJson(reply != null ? reply.message : null);
    TestResult result = new TestResult();
    result.testSuiteId = 'tst-' + EncodingUtil.convertToHex(Crypto.generateAESKey(128)).substring(0, 12);
    result.status = 'success';
    result.testCount = 0;
    result.summary = 'Test suite drafted for build ' + buildId + '.';
    if (parsed != null) {
      if (parsed.get('summary') != null) {
        result.summary = String.valueOf(parsed.get('summary'));
      }
      if (parsed.get('testCount') != null) {
        try {
          result.testCount = Integer.valueOf(String.valueOf(parsed.get('testCount')));
        } catch (Exception ignore) {
        }
      }
      if (parsed.get('status') != null) {
        result.status = String.valueOf(parsed.get('status'));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  @TestVisible
  private static HttpResponse sendRequest(String method, String path, String body) {
    return sendRequest(method, path, body, 30000);
  }

  @TestVisible
  private static HttpResponse sendRequest(
    String method,
    String path,
    String body,
    Integer timeoutMs
  ) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint(calloutUrl(path));
    req.setMethod(method);
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('Accept', 'application/json');
    // Per-user PAT (literal headers). Must use absolute URL — not NC+EC —
    // or Salesforce may omit Apex auth headers and Copado returns 401.
    applyCopadoAiAuthHeaders(req);
    req.setHeader('x-client', 'copado-builder');
    // Keep polls snappy — a 120s GET during Org Intelligence made each LWC poll hang.
    Integer ms = timeoutMs == null || timeoutMs < 5000 ? 30000 : timeoutMs;
    req.setTimeout(ms);
    if (String.isNotBlank(body)) {
      req.setBody(body);
    }
    return new Http().send(req);
  }

  /** Copado AI requires request_id to be a UUID (e.g. 8-4-4-4-12 hex). */
  @TestVisible
  private static String newRequestId() {
    String hex = EncodingUtil.convertToHex(Crypto.generateAESKey(128));
    return hex.substring(0, 8) + '-'
      + hex.substring(8, 12) + '-'
      + hex.substring(12, 16) + '-'
      + hex.substring(16, 20) + '-'
      + hex.substring(20, 32);
  }

  private static void requireOrgId(Settings settings) {
    if (String.isBlank(settings.organizationId)) {
      throw new ApiException(
        'Copado AI Organization Id is missing. Set it on Copado Builder Settings (Default).'
      );
    }
  }

  private static void assertOk(HttpResponse res, String action) {
    Integer code = res.getStatusCode();
    if (code < 200 || code >= 300) {
      String body = res.getBody();
      String snippet = String.isBlank(body)
        ? res.getStatus()
        : body.left(Math.min(400, body.length()));
      String message = action + ' failed (' + code + '): ' + snippet;
      if (code == 401 || code == 403) {
        message +=
          ' Your Copado AI Personal Access Token was rejected. '
          + 'Open Builder → Update Copado AI token, paste a fresh PAT from the same '
          + 'Copado AI organization as Organization Id in Copado Builder Settings, then retry.';
      }
      throw new ApiException(message);
    }
  }

  @TestVisible
  private static String parseStreamedMessage(String rawBody) {
    if (String.isBlank(rawBody)) {
      return '';
    }

    String trimmed = rawBody.trim();
    List<String> tokens = new List<String>();
    String finalMessage;

    // JSON array response (OpenAPI: array of string / event objects)
    if (trimmed.startsWith('[')) {
      try {
        List<Object> items = (List<Object>) JSON.deserializeUntyped(trimmed);
        for (Object item : items) {
          if (item instanceof String) {
            collectStreamEvent((String) item, tokens);
            if (finalMessage == null) {
              finalMessage = extractFinalMessage((String) item);
            }
          } else if (item instanceof Map<String, Object>) {
            collectStreamEventMap((Map<String, Object>) item, tokens);
            if (finalMessage == null) {
              finalMessage = extractFinalMessageMap((Map<String, Object>) item);
            }
          }
        }
      } catch (Exception ignore) {
        // fall through to line parsing
      }
    }

    // Single JSON object — only use as final reply if it's a message payload, not a version/status event
    if (tokens.isEmpty() && String.isBlank(finalMessage) && trimmed.startsWith('{')) {
      try {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
        collectStreamEventMap(data, tokens);
        finalMessage = extractFinalMessageMap(data);
      } catch (Exception ignore) {
        // NDJSON / multi-value body — parse line by line below
      }
    }

    // NDJSON / SSE lines — also used when a streamed body starts with '{' but is multi-event
    if (tokens.isEmpty() && String.isBlank(finalMessage)) {
      for (String line : rawBody.split('\n')) {
        String clean = line != null ? line.trim() : '';
        if (String.isBlank(clean) || clean == '[DONE]') {
          continue;
        }
        if (clean.startsWith('data:')) {
          clean = clean.substring(5).trim();
        }
        collectStreamEvent(clean, tokens);
        if (finalMessage == null) {
          finalMessage = extractFinalMessage(clean);
        }
      }
    } else if (!trimmed.startsWith('[')) {
      // Body may be NDJSON even if first event was parseable alone — accumulate all token lines
      List<String> lineTokens = new List<String>();
      for (String line : rawBody.split('\n')) {
        String clean = line != null ? line.trim() : '';
        if (String.isBlank(clean) || clean == '[DONE]') {
          continue;
        }
        if (clean.startsWith('data:')) {
          clean = clean.substring(5).trim();
        }
        if (clean.startsWith('{')) {
          collectStreamEvent(clean, lineTokens);
          if (finalMessage == null) {
            finalMessage = extractFinalMessage(clean);
          }
        }
      }
      if (!lineTokens.isEmpty()) {
        tokens = lineTokens;
      }
    }

    if (String.isNotBlank(finalMessage) && !isNoiseContent(finalMessage)) {
      return finalMessage;
    }

    String joined = String.join(tokens, '');
    if (isNoiseContent(joined)) {
      return '';
    }
    return joined;
  }

  private static void collectStreamEvent(String rawJson, List<String> tokens) {
    if (String.isBlank(rawJson) || !rawJson.startsWith('{')) {
      // Plain text chunk
      if (String.isNotBlank(rawJson) && !isNoiseContent(rawJson) && !rawJson.startsWith('[')) {
        tokens.add(rawJson);
      }
      return;
    }
    try {
      Map<String, Object> evt = (Map<String, Object>) JSON.deserializeUntyped(rawJson);
      collectStreamEventMap(evt, tokens);
    } catch (Exception ignore) {
      // ignore non-JSON lines
    }
  }

  private static void collectStreamEventMap(Map<String, Object> evt, List<String> tokens) {
    if (evt == null || evt.isEmpty()) {
      return;
    }
    String typeName = evt.containsKey('type') ? String.valueOf(evt.get('type')).toLowerCase() : '';
    // Skip protocol/meta events (this is what produced the "0.6.27" replies)
    if (typeName == 'version' || typeName == 'status' || typeName == 'ping' || typeName == 'heartbeat') {
      return;
    }

    if (typeName == 'token' || typeName == 'delta' || typeName == 'chunk') {
      String piece = extractTextContent(evt);
      if (String.isNotBlank(piece)) {
        tokens.add(piece);
      }
      return;
    }

    // Untyped events: only take content when it looks like a text token, not metadata
    if (String.isBlank(typeName)) {
      String piece = extractTextContent(evt);
      if (String.isNotBlank(piece) && !isNoiseContent(piece)) {
        tokens.add(piece);
      }
    }
  }

  private static String extractFinalMessage(String rawJson) {
    if (String.isBlank(rawJson) || !rawJson.startsWith('{')) {
      return null;
    }
    try {
      return extractFinalMessageMap((Map<String, Object>) JSON.deserializeUntyped(rawJson));
    } catch (Exception ignore) {
      return null;
    }
  }

  private static String extractFinalMessageMap(Map<String, Object> evt) {
    if (evt == null) {
      return null;
    }
    String typeName = evt.containsKey('type') ? String.valueOf(evt.get('type')).toLowerCase() : '';
    if (typeName == 'message' || typeName == 'answer' || typeName == 'final' || typeName == 'done' || typeName == 'complete') {
      String text = extractTextContent(evt);
      return isNoiseContent(text) ? null : text;
    }
    if (evt.containsKey('message') && evt.get('message') instanceof String) {
      String text = (String) evt.get('message');
      return isNoiseContent(text) ? null : text;
    }
    if (evt.containsKey('response') && evt.get('response') instanceof String) {
      String text = (String) evt.get('response');
      return isNoiseContent(text) ? null : text;
    }
    return null;
  }

  private static String extractTextContent(Map<String, Object> evt) {
    if (evt.containsKey('content')) {
      Object content = evt.get('content');
      if (content instanceof String) {
        return (String) content;
      }
      if (content instanceof Map<String, Object>) {
        Map<String, Object> nested = (Map<String, Object>) content;
        if (nested.containsKey('text')) {
          return String.valueOf(nested.get('text'));
        }
        if (nested.containsKey('content')) {
          return String.valueOf(nested.get('content'));
        }
      }
    }
    if (evt.containsKey('delta')) {
      return String.valueOf(evt.get('delta'));
    }
    if (evt.containsKey('token')) {
      return String.valueOf(evt.get('token'));
    }
    if (evt.containsKey('text')) {
      return String.valueOf(evt.get('text'));
    }
    return null;
  }

  private static Boolean isNoiseContent(String value) {
    if (String.isBlank(value)) {
      return true;
    }
    String v = value.trim();
    // Protocol version strings like "0.6.27"
    if (System.Pattern.matches('^\\d+\\.\\d+(\\.\\d+)?$', v)) {
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Mock implementations
  // ---------------------------------------------------------------------------

  private static WorkspaceResult mockCreateWorkspace(String name) {
    WorkspaceResult result = new WorkspaceResult();
    result.workspaceId = 'ws-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.workspaceName = name;
    result.status = 'active';
    return result;
  }

  private static WorkspaceResult mockGetWorkspace(String workspaceId) {
    WorkspaceResult result = new WorkspaceResult();
    result.workspaceId = workspaceId;
    result.workspaceName = 'Copado Builder Workspace';
    result.status = 'active';
    return result;
  }

  private static DialogueResult mockCreateDialogue(String workspaceId, String initialPrompt) {
    DialogueResult result = new DialogueResult();
    result.dialogueId = 'dlg-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.message = 'What are you trying to fix or build? Describe the problem or paste a transcript and I will help shape it into a Copado user story.';
    result.status = 'active';
    return result;
  }

  private static DialogueResult mockSendDialogueMessage(String dialogueId, String message) {
    DialogueResult result = new DialogueResult();
    result.dialogueId = dialogueId;
    Integer turnCount = message != null ? message.length() : 0;
    result.message = buildAssistantReply(message, turnCount);
    result.status = 'active';
    return result;
  }

  private static DocumentResult mockUploadDocument(String workspaceId, String fileName, String content) {
    DocumentResult result = new DocumentResult();
    result.documentId = 'doc-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.fileName = fileName;
    result.status = 'uploaded';
    return result;
  }

  private static StoryResult mockCreateUserStory(String workspaceId, Map<String, Object> storyData) {
    StoryResult result = new StoryResult();
    Boolean isUpdate = storyData != null
      && (storyData.get('updateExisting') == true
        || String.isNotBlank(strVal(storyData, 'targetStoryId', '')));
    String title = storyData != null && storyData.containsKey('title')
      ? String.valueOf(storyData.get('title'))
      : 'Builder Story';
    result.storyName = title;
    result.status = 'Draft';
    if (isUpdate) {
      String targetId = strVal(storyData, 'targetStoryId', '');
      result.recordId = String.isNotBlank(targetId) ? targetId : null;
      String existingRef = strVal(storyData, 'existingStoryRef', '');
      Matcher usName = System.Pattern.compile('(US-\\d+)').matcher(
        String.isNotBlank(existingRef) ? existingRef : ''
      );
      result.storyId = usName.find()
        ? usName.group(1)
        : 'US-' + String.valueOf(1000 + Math.mod(Math.abs(Crypto.getRandomInteger()), 9000));
      result.summary =
        'Updated Copado user story ' + result.storyId + ': "' + title + '". '
        + 'Title, persona fields, acceptance criteria, and specs were populated from the chat draft.';
    } else {
      result.storyId = 'US-' + String.valueOf(1000 + Math.mod(Math.abs(Crypto.getRandomInteger()), 9000));
      result.recordId = null;
      result.summary =
        'Created Copado user story "' + title + '" with requirements gathered from the chat session.';
    }
    return result;
  }

  private static BuildResult mockBuildCode(String storyId, String requirements) {
    BuildResult result = new BuildResult();
    result.buildId = 'bld-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.summary =
      'Generated a Salesforce metadata package for your story '
      + '(for example: custom fields, objects, validation rules, Apex, triggers, LWC, layouts, or permission sets as needed).';
    result.status = 'success';
    result.artifacts = new List<String>{
      'force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml',
      'force-app/main/default/classes/AccountFavoriteColorService.cls',
      'force-app/main/default/classes/AccountFavoriteColorService.cls-meta.xml'
    };
    Map<String, Object> packageBody = new Map<String, Object>{
      'summary' => result.summary,
      'story' => storyId,
      'files' => new List<Object>{
        new Map<String, Object>{
          'path' => result.artifacts[0],
          'content' => '<?xml version="1.0" encoding="UTF-8"?>\n'
            + '<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">\n'
            + '  <fullName>Favorite_Color__c</fullName>\n'
            + '  <label>Favorite Color</label>\n'
            + '  <type>Text</type>\n'
            + '  <length>40</length>\n'
            + '</CustomField>'
        }
      }
    };
    result.packageJson = JSON.serialize(packageBody);
    return result;
  }

  private static BuildResult mockReviewCode(String storyId, String buildId) {
    BuildResult result = new BuildResult();
    result.buildId = buildId;
    result.summary = 'Code review complete. No critical issues found. 2 minor suggestions for naming consistency.';
    result.status = 'success';
    result.artifacts = new List<String>{
      'Review passed',
      '2 minor suggestions'
    };
    return result;
  }

  private static TestResult mockCreateTests(String storyId, String buildId) {
    TestResult result = new TestResult();
    result.testSuiteId = 'tst-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.summary = 'Created 8 unit tests covering happy path, edge cases, and bulk scenarios.';
    result.status = 'success';
    result.testCount = 8;
    return result;
  }

  private static DeployResult mockDeployToOrg(String storyId, String orgId, String orgName) {
    DeployResult result = new DeployResult();
    result.deploymentId = 'dep-' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    result.summary = 'Successfully deployed story ' + storyId + ' to ' + orgName + '.';
    result.status = 'success';
    result.targetOrg = orgName;
    return result;
  }

  private static List<OrgInfo> mockListPipelineOrgs() {
    List<OrgInfo> orgs = new List<OrgInfo>();

    OrgInfo dev = new OrgInfo();
    dev.orgId = 'org-dev-001';
    dev.orgName = 'Dev Sandbox';
    dev.orgType = 'Sandbox';
    dev.isProduction = false;
    dev.pipelineOrder = 1;
    orgs.add(dev);

    OrgInfo qa = new OrgInfo();
    qa.orgId = 'org-qa-002';
    qa.orgName = 'QA Sandbox';
    qa.orgType = 'Sandbox';
    qa.isProduction = false;
    qa.pipelineOrder = 2;
    orgs.add(qa);

    OrgInfo uat = new OrgInfo();
    uat.orgId = 'org-uat-003';
    uat.orgName = 'UAT Sandbox';
    uat.orgType = 'Sandbox';
    uat.isProduction = false;
    uat.pipelineOrder = 3;
    orgs.add(uat);

    return orgs;
  }

  private static String buildAssistantReply(String userMessage, Integer turnCount) {
    if (String.isBlank(userMessage)) {
      return 'What are you trying to fix or build? Describe the problem or paste a transcript and I will help shape it into a Copado user story.';
    }

    if (turnCount < 80) {
      return 'Thanks for sharing that. A few clarifying questions:\n\n'
        + '1. Who is the primary user affected?\n'
        + '2. What should happen when they complete this workflow?\n'
        + '3. Are there any acceptance criteria or edge cases I should know about?\n\n'
        + 'Once I have enough detail, I will draft a user story and score it for readiness.';
    }

    return 'I have enough context to draft a user story. Review the score on the right panel, then click Create Copado Story when you are ready.';
  }
}
