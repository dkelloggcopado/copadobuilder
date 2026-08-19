public with sharing class CopadoBuilderController {

  /** Set when advancePipelineAfterDeployNext rebinds the session org — one-shot for LWC. */
  @TestVisible
  private static Boolean suggestOrgIntelligenceSync = false;

  public class SessionState {
    @AuraEnabled public Id sessionId;
    @AuraEnabled public String status;
    @AuraEnabled public String currentStep;
    @AuraEnabled public String copadoUserStory;
    @AuraEnabled public String storyRecordId;
    @AuraEnabled public String storyName;
    @AuraEnabled public String storyTitle;
    @AuraEnabled public String lastBuildId;
    @AuraEnabled public String lastJobId;
    @AuraEnabled public String lastJobStatus;
    @AuraEnabled public String lastJobSummary;
    @AuraEnabled public Boolean lastJobFailed;
    @AuraEnabled public Boolean lastJobComplete;
    @AuraEnabled public String lastDeployJobId;
    @AuraEnabled public String lastCommitJobId;
    @AuraEnabled public String lastJobAction;
    @AuraEnabled public String lastPromotionId;
    /** Deployed Apex build marker — e.g. BuilderValidate/v4. */
    @AuraEnabled public String builderCodeVersion;
    @AuraEnabled public Boolean deploySucceeded;
    @AuraEnabled public Boolean commitSucceeded;
    @AuraEnabled public Boolean canValidate;
    @AuraEnabled public String nextEnvironmentId;
    @AuraEnabled public String nextEnvironmentName;
    @AuraEnabled public List<String> buildArtifacts;
    @AuraEnabled public String selectedOrg;
    @AuraEnabled public String selectedOrgId;
    /** Org Context label — only the last *verified* Org Intelligence bind. */
    @AuraEnabled public String connectedOrgId;
    @AuraEnabled public String connectedOrgName;
    @AuraEnabled public String projectId;
    @AuraEnabled public Integer score;
    @AuraEnabled public String riskLevel;
    @AuraEnabled public String summary;
    @AuraEnabled public List<String> missingInfo;
    @AuraEnabled public String orgContextStatus;
    @AuraEnabled public String orgIntelligenceIntegrationId;
    @AuraEnabled public String buildStatus;
    @AuraEnabled public String testStatus;
    @AuraEnabled public String deployStatus;
    /** Pipeline step labels for Status panel (latest per step). */
    @AuraEnabled public String buildStepStatus;
    @AuraEnabled public String deployStepStatus;
    @AuraEnabled public String commitStepStatus;
    @AuraEnabled public String validateStepStatus;
    /** Real deploy to Next Env after successful Validate. */
    @AuraEnabled public String nextDeployStepStatus;
    @AuraEnabled public Boolean canDeployNext;
    /** True when story + org + artifacts exist — verify metadata in current env. */
    @AuraEnabled public Boolean canCheckDeployment;
    /**
     * True once after Deploy-to-next advances the session env — LWC should
     * re-bind Copado AI User Level Org Intelligence to the new credential.
     */
    @AuraEnabled public Boolean syncOrgIntelligenceSuggested;
    /** Populated only when the latest relevant job failed — keeps the panel quiet on success. */
    @AuraEnabled public String pipelineErrorDetail;
    @AuraEnabled public String pipelineErrorJobId;
    @AuraEnabled public String pipelineErrorAction;
    @AuraEnabled public List<MessageDto> messages;
    /** LWC should keep polling when the message stream returned empty. */
    @AuraEnabled public Boolean awaitingAiReply;
    @AuraEnabled public String aiRequestId;
    @AuraEnabled public String dialogueId;
    @AuraEnabled public String workspaceId;
    @AuraEnabled public Integer aiBaselineMessageCount;
    @AuraEnabled public String aiBaselineAssistantText;
  }

  public class StoryRef {
    public Id recordId;
    public String name;
    public String title;
  }

  public class MessageDto {
    @AuraEnabled public String role;
    @AuraEnabled public String message;
    @AuraEnabled public String step;
    @AuraEnabled public Datetime createdDate;
  }

  public class StoryHistoryDto {
    @AuraEnabled public Id sessionId;
    @AuraEnabled public String name;
    @AuraEnabled public String status;
    @AuraEnabled public Integer score;
    @AuraEnabled public String copadoUserStory;
    @AuraEnabled public Datetime createdDate;
    @AuraEnabled public Datetime lastModifiedDate;
    @AuraEnabled public String summary;
    @AuraEnabled public String preview;
  }

  public class ActionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public SessionState session;
    @AuraEnabled public CopadoAiApiService.OrgIntelligenceResult orgIntelligence;
    /** True when Build started but Copado AI package JSON is still generating. */
    @AuraEnabled public Boolean awaitingBuild;
  }

  @AuraEnabled(cacheable=true)
  public static String getBuilderCodeVersion() {
    return CopadoDevopsService.BUILDER_CODE_VERSION;
  }

  /**
   * Opens the current user's most recently modified chat, or starts a new one
   * if they have none yet. Used when the app loads so reopening does not spawn
   * empty sessions.
   */
  @AuraEnabled
  public static SessionState resumeOrStartSession() {
    Id userId = UserInfo.getUserId();
    List<AI_Builder_Session__c> recent = [
      SELECT Id
      FROM AI_Builder_Session__c
      WHERE OwnerId = :userId
      ORDER BY LastModifiedDate DESC
      LIMIT 1
    ];
    if (!recent.isEmpty()) {
      return getSessionState(recent[0].Id);
    }
    return startSession();
  }

  @AuraEnabled
  public static SessionState startSession() {
    // Callouts must run before any DML in the same transaction.
    String sessionName = 'Session ' + Datetime.now().format('yyyy-MM-dd HH:mm');
    String greeting = 'What are you trying to fix or build? Describe the problem, feature, or paste a transcript.';
    String workspaceId;
    String dialogueId;

    try {
      CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
      CopadoAiApiService.DialogueResult dialogue = CopadoAiApiService.createDialogue(
        workspace.workspaceId,
        sessionName
      );
      workspaceId = workspace.workspaceId;
      dialogueId = dialogue.dialogueId;
      if (String.isNotBlank(dialogue.message)) {
        greeting = dialogue.message;
      }
    } catch (Exception ex) {
      greeting = 'I could not connect to Copado AI yet (' + formatException(ex)
        + '). You can still type requirements, or fix settings and start a new session.';
    }

    AI_Builder_Session__c session = new AI_Builder_Session__c(
      Name = sessionName,
      Status__c = 'New',
      Current_Step__c = 'Discovery',
      Score__c = 0,
      Risk_Level__c = 'Low',
      Summary__c = 'New builder session started.',
      Workspace_Id__c = workspaceId,
      Dialogue_Id__c = dialogueId
    );
    // Prefill last-used Dev credential + integration as defaults only — never
    // mark Connected until this user explicitly Connects Org Intelligence.
    applyLastOrgIntelligenceDefaults(session);
    insert session;
    insertMessage(session.Id, 'Assistant', greeting, 'Discovery');
    return getSessionState(session.Id);
  }

  /**
   * Copy the user's last Dev Org Credential + Copado AI integration onto a new
   * session as the default selection. Does NOT set Org Context to Connected.
   */
  private static void applyLastOrgIntelligenceDefaults(AI_Builder_Session__c session) {
    if (session == null) {
      return;
    }
    List<AI_Builder_Session__c> prior = [
      SELECT
        Org_Intelligence_Integration_Id__c,
        Org_Credential_Id__c,
        Selected_Org__c
      FROM AI_Builder_Session__c
      WHERE OwnerId = :UserInfo.getUserId()
        AND Org_Credential_Id__c != null
      ORDER BY LastModifiedDate DESC
      LIMIT 1
    ];
    if (prior.isEmpty()) {
      // Fall back to remembered preference (even if no prior session rows).
      String preferredCred = CopadoDevopsService.getPreferredEnvironmentId(null);
      if (
        String.isNotBlank(preferredCred)
        && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(preferredCred)
      ) {
        session.Org_Credential_Id__c = preferredCred;
        CopadoAiApiService.OrgInfo org =
          CopadoDevopsService.findOrgCredentialById(preferredCred);
        if (org != null) {
          session.Selected_Org__c = org.orgName;
        }
      }
      String preferredInt = CopadoDevopsService.getPreferredIntegrationId();
      if (String.isNotBlank(preferredInt)) {
        session.Org_Intelligence_Integration_Id__c = preferredInt;
      }
      return;
    }
    AI_Builder_Session__c src = prior[0];
    if (
      String.isNotBlank(src.Org_Credential_Id__c)
      && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(src.Org_Credential_Id__c)
    ) {
      session.Org_Credential_Id__c = src.Org_Credential_Id__c;
      if (String.isNotBlank(src.Selected_Org__c)) {
        session.Selected_Org__c = src.Selected_Org__c;
      }
    }
    if (String.isNotBlank(src.Org_Intelligence_Integration_Id__c)) {
      session.Org_Intelligence_Integration_Id__c = src.Org_Intelligence_Integration_Id__c;
    }
    // Intentionally leave Org_Context_Status__c unset / Not connected.
  }

  @AuraEnabled
  public static SessionState sendMessage(
    Id sessionId,
    String message,
    String orgIntelligenceIntegrationId,
    String orgCredentialId
  ) {
    validateSessionId(sessionId);
    if (String.isBlank(message)) {
      throw new AuraHandledException('Please enter a message.');
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    String currentStep = session.Current_Step__c;
    String workspaceId = session.Workspace_Id__c;
    String dialogueId = session.Dialogue_Id__c;
    String assistantReply;
    String calloutError;
    Boolean pendingAi = false;
    String pendingRequestId = null;
    Integer pendingBaselineCount = null;
    String pendingBaselineText = null;

    // Authoritative org = session Status panel selection (not a sticky Worker default).
    String sessionCred = String.isNotBlank(session.Org_Credential_Id__c)
      ? session.Org_Credential_Id__c
      : orgCredentialId;
    String sessionOrgLabel = String.isNotBlank(session.Selected_Org__c)
      ? session.Selected_Org__c
      : sessionCred;
    String integrationId = String.isNotBlank(orgIntelligenceIntegrationId)
      ? orgIntelligenceIntegrationId
      : session.Org_Intelligence_Integration_Id__c;
    if (String.isNotBlank(sessionCred)) {
      String resolved = CopadoDevopsService.resolveOrgCredentialId(sessionCred);
      if (String.isNotBlank(resolved)) {
        sessionCred = resolved;
      }
      CopadoAiApiService.OrgInfo orgInfo = CopadoDevopsService.findOrgCredentialById(sessionCred);
      if (orgInfo != null && String.isNotBlank(orgInfo.orgName)) {
        sessionOrgLabel = orgInfo.orgName;
      }
    }

    // "Pull the actual layout name / update artifacts" → resolve live Layout + rewrite package.
    if (isLayoutResolveQuestion(message)) {
      List<String> liveLayouts = new List<String>();
      String updatedPkg = session.Build_Package_Json__c;
      String err = null;
      String authBlock = '';
      try {
        Map<String, List<String>> liveByType = resolveLiveMetadataViaOrgIntelligence(
          session,
          workspaceId,
          dialogueId,
          session.Summary__c,
          updatedPkg
        );
        liveLayouts = liveByType != null && liveByType.containsKey('Layout')
          ? liveByType.get('Layout')
          : new List<String>();
        authBlock = CopadoDevopsService.formatAuthoritativeLiveMetadataBlock(liveByType);
        if (liveLayouts.isEmpty()) {
          err =
            'Org Intelligence did not return a live Layout fullName for this org. '
            + 'Confirm Development Org Credential = '
            + blankTo(sessionOrgLabel, 'dev1')
            + ' in Copado AI Integrations, click Reconnect Org Intelligence, then ask again.';
        } else {
          if (String.isBlank(updatedPkg) || updatedPkg.contains('_pendingBuild')) {
            err =
              'Live layouts found: '
              + String.join(liveLayouts, ', ')
              + '. No Build package on this chat yet — click **Build** to capture artifacts with these names.';
          } else {
            updatedPkg = CopadoDevopsService.normalizePackageMetadataWithContext(
              updatedPkg,
              authBlock
            );
            // If package had no layout file, inject one using the preferred live name + field.
            updatedPkg = ensurePackageHasLiveLayouts(updatedPkg, liveLayouts);
          }
        }
      } catch (Exception ex) {
        err = formatException(ex);
      }
      insertMessage(sessionId, 'User', message, currentStep);
      if (String.isNotBlank(err) && (liveLayouts == null || liveLayouts.isEmpty())) {
        insertMessage(
          sessionId,
          'Assistant',
          '_Build Agent_\n\n' + err,
          currentStep
        );
        return getSessionState(sessionId);
      }
      if (String.isNotBlank(updatedPkg)
        && !updatedPkg.contains('_pendingBuild')
        && (session.Build_Package_Json__c == null
          || !updatedPkg.equals(session.Build_Package_Json__c))) {
        session.Build_Package_Json__c = truncateForLongText(updatedPkg, 131072);
        update session;
        StoryRef storyForStamp = resolveStoryRef(session);
        if (storyForStamp.recordId != null) {
          try {
            CopadoDevopsService.stampUserStoryBuildArtifacts(
              storyForStamp.recordId,
              updatedPkg,
              extractArtifactPaths(updatedPkg)
            );
          } catch (Exception ignore) {
          }
        }
      }
      List<String> paths = extractArtifactPaths(updatedPkg);
      String assistantBody = '_Build Agent_\n\n';
      if (String.isNotBlank(authBlock)) {
        assistantBody += authBlock + '\n\n';
      } else {
        assistantBody +=
          'Live layout'
          + (liveLayouts.size() == 1 ? '' : 's')
          + ' from '
          + blankTo(sessionOrgLabel, 'selected Dev org')
          + ':\n- '
          + String.join(liveLayouts, '\n- ')
          + '\n\n';
      }
      assistantBody +=
        'Artifacts now:\n- '
        + (paths == null || paths.isEmpty()
          ? '(none — run Build)'
          : String.join(paths, '\n- '))
        + (String.isNotBlank(err) ? '\n\nNote: ' + err : '');
      insertMessage(sessionId, 'Assistant', assistantBody, currentStep);
      return getSessionState(sessionId);
    }

    // Deploy / "are the components in the org?" → Builder job facts, not OI guessing.
    if (CopadoAiApiService.isDeployVerificationQuestion(message)) {
      // Callouts before DML.
      if (String.isNotBlank(integrationId)
        && String.isNotBlank(sessionCred)
        && !CopadoAiApiService.isMockMode()) {
        try {
          CopadoAiApiService.syncIntegrationOrgCredential(
            integrationId,
            sessionCred,
            sessionOrgLabel
          );
        } catch (Exception ignore) {
        }
      }
      insertMessage(sessionId, 'User', message, currentStep);
      String facts = buildDeployVerificationAnswer(session, sessionCred, sessionOrgLabel);
      insertMessage(
        sessionId,
        'Assistant',
        '_Build Agent_\n\n' + facts,
        currentStep
      );
      return getSessionState(sessionId);
    }

    // Route this turn to the best specialist agent (build/plan/test/release/operate).
    String routedAssistant = CopadoAiApiService.routeAssistant(message);

    String messageForAi = message;

    StoryRef storyRef = resolveStoryRef(session);
    Boolean orgIntelligenceConnected = String.isNotBlank(integrationId)
      || 'Connected'.equalsIgnoreCase(session.Org_Context_Status__c);
    Boolean needsOi = CopadoAiApiService.needsOrgIntelligence(message);

    // User Story backlog / counts live in THIS Copado governance org (SOQL), not in
    // Dev-sandbox Org Intelligence. Always inject when the question is about backlog.
    if (CopadoAiApiService.isGovernanceBacklogQuestion(message)) {
      String backlog = CopadoDevopsService.buildGovernanceBacklogSummary(
        sessionCred,
        sessionOrgLabel
      );
      if (String.isNotBlank(backlog)) {
        messageForAi = backlog + '\n\n' + messageForAi;
      }
    } else if (
      !orgIntelligenceConnected
      && storyRef.recordId != null
      && CopadoAiApiService.ASSISTANT_BUILD.equals(routedAssistant)
    ) {
      String orgCtx = CopadoDevopsService.buildOrgContextSummary(
        storyRef.recordId,
        sessionCred
      );
      if (String.isNotBlank(orgCtx)) {
        messageForAi = orgCtx + '\n\n' + messageForAi;
      }
    }

    if (CopadoAiApiService.isGovernanceBacklogQuestion(message)) {
      messageForAi =
        '[TOOL GUIDE] Org Intelligence = live METADATA in the selected Dev sandbox only. '
          + 'Copado User Stories / backlog / dependencies = records in THIS Copado '
          + 'governance org (see COPADO GOVERNANCE DATA above). Answer User Story '
          + 'counts from governance data, not Org Intelligence.\n\n'
          + messageForAi;
    }

    // Force every live-metadata turn onto the session Dev credential (dev1), never a
    // sticky prior Worker org (e.g. int). Do not ask the user for Credential Ids.
    if (needsOi) {
      routedAssistant = CopadoAiApiService.ASSISTANT_BUILD;
      messageForAi =
        '[BUILDER ORG — authoritative]\n'
        + 'Selected Dev org: '
        + blankTo(sessionOrgLabel, '(unknown)')
        + '\n'
        + 'Org Credential Id: '
        + blankTo(sessionCred, '(none)')
        + '\n'
        + 'Use this org only. Do NOT query int / other sandboxes. '
        + 'Do NOT ask for a Credential Id or User Id. '
        + 'If tools are not bound to this credential, say so and stop.\n\n'
        + messageForAi;
    }

    Map<String, Object> integrations = null;

    // All HTTP callouts first — no DML above this point (except deploy-verify early return).
    try {
      if (String.isBlank(workspaceId)) {
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
      }
      if (String.isBlank(dialogueId)) {
        CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
          workspaceId,
          session.Name
        );
        dialogueId = created.dialogueId;
      }

      if (needsOi
        && String.isNotBlank(integrationId)
        && String.isNotBlank(sessionCred)
        && !CopadoAiApiService.isMockMode()) {
        Boolean bound = CopadoAiApiService.syncIntegrationOrgCredential(
          integrationId,
          sessionCred,
          sessionOrgLabel
        );
        String selectedAfter =
          CopadoAiApiService.getIntegrationSelectedCredentialId(integrationId);
        Boolean selectedMatches =
          String.isBlank(selectedAfter)
          || sessionCred.equals(selectedAfter)
          || (String.isNotBlank(sessionOrgLabel)
            && sessionOrgLabel.equalsIgnoreCase(selectedAfter));
        if (bound != true || selectedMatches != true) {
          insertMessage(sessionId, 'User', message, currentStep);
          insertMessage(
            sessionId,
            'Assistant',
            '_Build Agent_\n\n'
              + 'Org Intelligence is not bound to '
              + sessionOrgLabel
              + ' (credential '
              + sessionCred
              + ').'
              + (String.isNotBlank(selectedAfter)
                ? ' Currently selected: ' + selectedAfter + '.'
                : '')
              + ' Open Copado AI → Integrations, set Development Org Credential to '
              + sessionOrgLabel
              + ', Save, then click Reconnect Org Intelligence in Builder.\n\n'
              + buildDeployVerificationAnswer(session, sessionCred, sessionOrgLabel),
            currentStep
          );
          return getSessionState(sessionId);
        }
        try {
          CopadoAiApiService.tryStartAgentWorker(
            CopadoAiApiService.ASSISTANT_BUILD,
            workspaceId,
            dialogueId,
            CopadoAiApiService.buildIntegrationsPayload(
              integrationId,
              null,
              sessionCred,
              sessionOrgLabel
            )
          );
        } catch (Exception ignore) {
        }
      }

      CopadoAiApiService.DialogueResult dialogue = CopadoAiApiService.sendDialogueMessage(
        dialogueId,
        messageForAi,
        integrations,
        routedAssistant,
        workspaceId
      );
      assistantReply = dialogue.message;
      if (String.isNotBlank(dialogue.dialogueId)) {
        dialogueId = dialogue.dialogueId;
      }
      if (String.isNotBlank(dialogue.assistantId)) {
        routedAssistant = dialogue.assistantId;
      }
      if (dialogue.pending == true) {
        pendingAi = true;
        pendingRequestId = dialogue.requestId;
        pendingBaselineCount = dialogue.baselineMessageCount;
        pendingBaselineText = dialogue.baselineAssistantText;
      }
    } catch (Exception ex) {
      calloutError = formatException(ex);
    }

    insertMessage(sessionId, 'User', message, currentStep);

    if (String.isNotBlank(calloutError)) {
      insertMessage(
        sessionId,
        'Assistant',
        'I could not reach Copado AI: ' + calloutError,
        'Discovery'
      );
      return getSessionState(sessionId);
    }

    if (pendingAi == true) {
      session = loadSession(sessionId);
      session.Workspace_Id__c = workspaceId;
      session.Dialogue_Id__c = dialogueId;
      session.Status__c = 'In Progress';
      session.Current_Step__c = 'Discovery';
      update session;
      SessionState pendingState = getSessionState(sessionId);
      pendingState.awaitingAiReply = true;
      pendingState.aiRequestId = pendingRequestId;
      pendingState.dialogueId = dialogueId;
      pendingState.workspaceId = workspaceId;
      pendingState.aiBaselineMessageCount = pendingBaselineCount;
      pendingState.aiBaselineAssistantText = pendingBaselineText;
      return pendingState;
    }

    String displayReply = CopadoAiApiService.summarizeForChatDisplay(assistantReply);
    String labeled = String.isNotBlank(routedAssistant)
      ? '_' + agentLabel(routedAssistant) + '_\n\n' + displayReply
      : displayReply;
    insertMessage(sessionId, 'Assistant', labeled, 'Discovery');

    session = loadSession(sessionId);
    StoryScore score = scoreStory(sessionId);
    session.Workspace_Id__c = workspaceId;
    session.Dialogue_Id__c = dialogueId;
    session.Score__c = score.totalScore;
    session.Risk_Level__c = score.riskLevel;
    applyChatDraftToSession(session, score, assistantReply);
    session.Status__c = 'In Progress';
    session.Current_Step__c = 'Discovery';
    update session;

    return getSessionState(sessionId);
  }

  /**
   * Deterministic answer for "were the components deployed?" using Builder session
   * job state — never invent Credential Ids or query the wrong sandbox.
   */
  private static String buildDeployVerificationAnswer(
    AI_Builder_Session__c session,
    String orgCred,
    String orgLabel
  ) {
    List<String> lines = new List<String>();
    lines.add('Builder status for **' + blankTo(orgLabel, 'selected Dev org') + '**');
    if (String.isNotBlank(orgCred)) {
      lines.add('Org Credential Id: `' + orgCred + '`');
    }
    lines.add('');

    String deployJobId = session != null ? session.Last_Deploy_Job_Id__c : null;
    Boolean deployOk = false;
    String deployDetail = 'Not run yet on this chat.';
    if (String.isNotBlank(deployJobId)) {
      try {
        CopadoDevopsService.JobStatus st =
          CopadoDevopsService.getJobExecutionStatus(deployJobId, false);
        deployOk = st != null && st.isComplete == true && st.isFailed != true;
        if (st == null) {
          deployDetail = 'Job ' + deployJobId + ' — status unknown.';
        } else if (st.isFailed == true) {
          deployDetail =
            'Failed. Job `'
            + deployJobId
            + '`.'
            + (String.isNotBlank(st.errorMessage) ? ' ' + st.errorMessage : '')
            + (String.isNotBlank(st.summary) ? ' ' + st.summary : '');
        } else if (st.isComplete == true) {
          deployDetail = 'Succeeded. Job `' + deployJobId + '`.';
        } else {
          deployDetail =
            'Still running. Job `'
            + deployJobId
            + '`.'
            + (String.isNotBlank(st.summary) ? ' ' + st.summary : '');
        }
      } catch (Exception ex) {
        deployDetail =
          'Job `' + deployJobId + '` — could not read status (' + ex.getMessage() + ').';
      }
    }
    lines.add('**Deploy to Dev:** ' + deployDetail);

    String commitJobId = session != null ? session.Last_Commit_Job_Id__c : null;
    if (String.isNotBlank(commitJobId)) {
      try {
        CopadoDevopsService.JobStatus cst =
          CopadoDevopsService.getJobExecutionStatus(commitJobId, false);
        if (cst != null && cst.isFailed == true) {
          lines.add(
            '**Commit:** Failed. Job `'
              + commitJobId
              + '`.'
              + (String.isNotBlank(cst.errorMessage) ? ' ' + cst.errorMessage : '')
          );
        } else if (cst != null && cst.isComplete == true) {
          lines.add('**Commit:** Succeeded. Job `' + commitJobId + '`.');
        } else if (cst != null) {
          lines.add('**Commit:** In progress. Job `' + commitJobId + '`.');
        }
      } catch (Exception ignore) {
        lines.add('**Commit:** Job `' + commitJobId + '` (status unread).');
      }
    } else {
      lines.add('**Commit:** Not run yet on this chat.');
    }

    List<String> artifacts = extractArtifactPaths(
      session != null ? session.Build_Package_Json__c : null
    );
    lines.add('');
    if (artifacts == null || artifacts.isEmpty()) {
      lines.add('**Package artifacts:** none on this chat (run Build first).');
    } else {
      lines.add('**Package artifacts** (' + artifacts.size() + '):');
      for (String path : artifacts) {
        String note = '';
        if (path != null && path.contains('/layouts/')) {
          String base = path.substring(path.lastIndexOf('/') + 1);
          if (base.endsWith('.layout-meta.xml')) {
            base = base.substring(0, base.length() - '.layout-meta.xml'.length());
          } else if (base.endsWith('.layout')) {
            base = base.substring(0, base.length() - '.layout'.length());
          }
          Integer dash = base.indexOf('-');
          if (dash > 0) {
            String objectApi = base.substring(0, dash);
            String label = base.substring(dash + 1);
            if ((objectApi + ' Layout').equals(label)) {
              note =
                ' _(invented English default — Deploy remaps to the live org layout)_';
            }
          }
        }
        lines.add('- `' + path + '`' + note);
      }
    }

    lines.add('');
    if (deployOk) {
      lines.add(
        '**Verdict:** Deploy to '
          + blankTo(orgLabel, 'Dev')
          + ' succeeded for this chat. Components from the package were deployed to that org '
          + '(layout may use the live fullName, e.g. Account-Formato de cuentas, even if '
          + 'Artifacts still list an invented name).'
      );
    } else if (String.isNotBlank(deployJobId)) {
      lines.add(
        '**Verdict:** Deploy has not succeeded yet — do not treat components as deployed in '
          + blankTo(orgLabel, 'Dev')
          + '.'
      );
    } else {
      lines.add(
        '**Verdict:** No Deploy job on this chat yet. Run **Deploy** to '
          + blankTo(orgLabel, 'Dev')
          + ' before expecting components in the org.'
      );
    }
    lines.add('');
    lines.add(
      'This answer is from Builder job status for the selected org above — not from a sticky '
        + 'int connection. For a live metadata scan of the same org, click **Check deployment** '
        + '(after Reconnect Org Intelligence if needed).'
    );
    return String.join(lines, '\n');
  }

  private static String blankTo(String value, String fallback) {
    return String.isNotBlank(value) ? value : fallback;
  }

  /**
   * LWC poll after sendMessage returns awaitingAiReply=true (empty stream body).
   * Pass timedOut=true on the final attempt to persist a clear assistant note.
   */
  @AuraEnabled
  public static SessionState pollAiReply(
    Id sessionId,
    String dialogueId,
    String requestId,
    String assistantId,
    Boolean timedOut,
    Integer baselineMessageCount,
    String baselineAssistantText
  ) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    String dlg = String.isNotBlank(dialogueId) ? dialogueId : session.Dialogue_Id__c;
    if (String.isBlank(dlg)) {
      SessionState empty = getSessionState(sessionId);
      empty.awaitingAiReply = false;
      return empty;
    }

    String reply;
    try {
      reply = CopadoAiApiService.pollAssistantText(
        dlg,
        requestId,
        baselineMessageCount,
        baselineAssistantText
      );
    } catch (Exception ex) {
      // Callout timeouts while Org Intelligence is still running are expected —
      // keep polling instead of ending the turn with an error bubble.
      String msg = formatException(ex);
      if (
        timedOut != true
        && (
          msg.toLowerCase().contains('timeout')
          || msg.toLowerCase().contains('timed out')
          || msg.toLowerCase().contains('exceeded')
          || msg.toLowerCase().contains('read timed out')
        )
      ) {
        SessionState waiting = getSessionState(sessionId);
        waiting.awaitingAiReply = true;
        waiting.aiRequestId = requestId;
        waiting.dialogueId = dlg;
        waiting.aiBaselineMessageCount = baselineMessageCount;
        waiting.aiBaselineAssistantText = baselineAssistantText;
        return waiting;
      }
      SessionState err = getSessionState(sessionId);
      err.awaitingAiReply = false;
      insertMessage(
        sessionId,
        'Assistant',
        'I could not finish reading the Copado AI reply: ' + msg,
        'Discovery'
      );
      return getSessionState(sessionId);
    }

    if (String.isBlank(reply)) {
      if (timedOut == true) {
        insertMessage(
          sessionId,
          'Assistant',
          '_Build Agent_\n\n'
            + 'Copado AI did not return a reply in time (Org Intelligence can take a while). '
            + 'Ask the same question once more — the connection is fine if Connect succeeded.',
          'Discovery'
        );
        SessionState done = getSessionState(sessionId);
        done.awaitingAiReply = false;
        return done;
      }
      SessionState waiting = getSessionState(sessionId);
      waiting.awaitingAiReply = true;
      waiting.aiRequestId = requestId;
      waiting.dialogueId = dlg;
      waiting.aiBaselineMessageCount = baselineMessageCount;
      waiting.aiBaselineAssistantText = baselineAssistantText;
      return waiting;
    }

    String routed = String.isNotBlank(assistantId) ? assistantId : CopadoAiApiService.ASSISTANT_BUILD;
    String displayReply = CopadoAiApiService.summarizeForChatDisplay(reply);
    String labeled = '_' + agentLabel(routed) + '_\n\n' + displayReply;
    insertMessage(sessionId, 'Assistant', labeled, 'Discovery');

    StoryScore score = scoreStory(sessionId);
    session = loadSession(sessionId);
    session.Score__c = score.totalScore;
    session.Risk_Level__c = score.riskLevel;
    applyChatDraftToSession(session, score, reply);
    update session;

    SessionState done = getSessionState(sessionId);
    done.awaitingAiReply = false;
    return done;
  }

  @AuraEnabled
  public static SessionState saveSessionOrgCredential(Id sessionId, String orgCredentialId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    String previousCred = session.Org_Credential_Id__c;

    if (String.isBlank(orgCredentialId)) {
      return getSessionState(sessionId);
    }

    CopadoAiApiService.OrgInfo org = CopadoDevopsService.findNonProductionOrg(orgCredentialId);
    if (org == null) {
      org = CopadoDevopsService.findOrgCredentialById(orgCredentialId);
    }

    session.Org_Credential_Id__c = orgCredentialId;
    session.Selected_Org__c = org != null ? org.orgName : orgCredentialId;
    // Keep existing integration id; ensureOrgIntelligenceReady / Connect re-binds.
    // Do not wipe Connected status on every org change — that forced a Connect click.
    if (!orgCredentialId.equals(previousCred)) {
      // Status refreshed by ensureOrgIntelligenceReady after this save.
    }
    update session;
    return getSessionState(sessionId);
  }

  /**
   * List Copado AI integrations the user can bind for Org Intelligence.
   */
  @AuraEnabled
  public static List<CopadoAiApiService.IntegrationInfo> listOrgIntelligenceIntegrations(
    Id sessionId
  ) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    String workspaceId = session.Workspace_Id__c;
    try {
      // New users often have no Workspace_Id yet. Resolve via callout first,
      // list integrations next, then persist — never DML before the list callout
      // (Salesforce: "uncommitted work pending … before calling out").
      Boolean persistWorkspace = false;
      if (String.isBlank(workspaceId) && !CopadoAiApiService.isMockMode()) {
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
        persistWorkspace = String.isNotBlank(workspaceId);
      }
      List<CopadoAiApiService.IntegrationInfo> rows =
        CopadoAiApiService.listActiveCopadoIntegrations(workspaceId);
      if (persistWorkspace) {
        session = loadSession(sessionId);
        if (session.Workspace_Id__c != workspaceId) {
          session.Workspace_Id__c = workspaceId;
          update session;
        }
      }
      return rows;
    } catch (Exception ex) {
      throw new AuraHandledException(
        'Could not list Copado AI integrations: ' + formatException(ex)
      );
    }
  }

  /**
   * Auto-attach a healthy Copado AI connection to this Builder chat.
   *
   * bindCredential=false (page load / hard refresh): discover a connected Copado AI
   * integration, GET-verify its bound Org Credential, and mark Org Context Connected
   * when that credential is one this user owns. Does NOT force-push a new bind.
   *
   * bindCredential=true (Update OI): push the selected Dev org onto the integration
   * and require verify before marking Connected.
   */
  @AuraEnabled
  public static SessionState ensureOrgIntelligenceReady(
    Id sessionId,
    String orgCredentialId,
    String preferredIntegrationId,
    Boolean bindCredential
  ) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    String workspaceId = session.Workspace_Id__c;
    String dialogueId = session.Dialogue_Id__c;
    String credId = String.isNotBlank(orgCredentialId)
      ? orgCredentialId
      : session.Org_Credential_Id__c;
    if (String.isNotBlank(credId)) {
      String resolved = CopadoDevopsService.resolveOrgCredentialId(credId);
      if (String.isNotBlank(resolved)) {
        credId = resolved;
      }
    }
    Boolean doBind = bindCredential == true;
    if (String.isBlank(preferredIntegrationId)) {
      preferredIntegrationId = CopadoDevopsService.getPreferredIntegrationId();
    }
    if (String.isBlank(preferredIntegrationId)) {
      preferredIntegrationId = session.Org_Intelligence_Integration_Id__c;
    }

    CopadoAiApiService.OrgInfo org = null;
    if (String.isNotBlank(credId)) {
      org = CopadoDevopsService.findNonProductionOrg(credId);
      if (org == null) {
        org = CopadoDevopsService.findOrgCredentialById(credId);
      }
    }

    CopadoAiApiService.OrgIntelligenceResult probe;
    CopadoAiApiService.OrgInfo verifiedOrg = null;
    try {
      if (String.isBlank(workspaceId)) {
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
      }
      // Never create a new Copado dialogue here — that orphaned chats on refresh.
      // Chat create/send owns dialogue lifecycle.

      if (doBind && String.isNotBlank(credId) && org != null) {
        probe = CopadoAiApiService.ensureOrgIntelligence(
          workspaceId,
          org.orgId,
          org.orgName,
          dialogueId,
          false,
          preferredIntegrationId
        );
        if (probe != null && probe.success == true && probe.credentialBound != false) {
          verifiedOrg = org;
        }
      } else {
        // Light path: find connected integration, then confirm its bound credential.
        probe = new CopadoAiApiService.OrgIntelligenceResult();
        List<CopadoAiApiService.IntegrationInfo> rows =
          CopadoAiApiService.listActiveCopadoIntegrations(workspaceId);
        CopadoAiApiService.IntegrationInfo pick = pickConnectedIntegration(
          rows,
          preferredIntegrationId
        );
        if (pick == null && String.isNotBlank(session.Org_Intelligence_Integration_Id__c)) {
          // Keep whatever this session already had if still in the list.
          for (CopadoAiApiService.IntegrationInfo row : rows) {
            if (session.Org_Intelligence_Integration_Id__c.equals(row.id)
              && row.connected == true) {
              pick = row;
              break;
            }
          }
        }
        if (pick != null) {
          probe.success = true;
          probe.status = 'connected';
          probe.integrationId = pick.id;
          probe.message = 'Using existing Copado connection: ' + pick.name;
          verifiedOrg = resolveOrgFromConnectedIntegration(pick.id, credId, org);
          probe.credentialBound = verifiedOrg != null;
          if (verifiedOrg != null) {
            probe.orgCredentialId = verifiedOrg.orgId;
            probe.orgName = verifiedOrg.orgName;
            probe.message =
              'Org Intelligence already bound to '
              + verifiedOrg.orgName
              + ' via '
              + pick.name
              + '.';
          } else {
            probe.message =
              'Copado AI integration "'
              + pick.name
              + '" is connected, but its Org Credential does not match a Dev credential you own. '
              + 'Select your credential and click Update OI, or reconnect in Copado AI Settings.';
          }
        } else {
          probe.success = false;
          probe.status = 'Not connected';
          probe.message = 'No connected Copado AI integration found.';
        }
      }
    } catch (Exception ex) {
      return getSessionState(sessionId);
    }

    session = loadSession(sessionId);
    session.Workspace_Id__c = workspaceId;
    if (String.isNotBlank(dialogueId)) {
      session.Dialogue_Id__c = dialogueId;
    }
    if (doBind) {
      Boolean boundOk = probe != null
        && probe.success == true
        && probe.credentialBound != false
        && String.isNotBlank(probe.integrationId);
      if (boundOk && org != null) {
        session.Selected_Org__c = org.orgName;
        session.Org_Credential_Id__c = org.orgId;
        session.Org_Intelligence_Integration_Id__c = probe.integrationId;
        session.Org_Context_Status__c = 'Connected';
        insertMessage(
          sessionId,
          'System',
          formatOrgIntelligenceChatMessage(org.orgName, 'Connected', probe),
          'Org Intelligence'
        );
      } else if (probe != null) {
        insertMessage(
          sessionId,
          'System',
          formatOrgIntelligenceChatMessage(
            org != null ? org.orgName : null,
            formatOrgContextStatus(probe),
            probe
          ),
          'Org Intelligence'
        );
      }
    } else if (probe != null && probe.success == true && String.isNotBlank(probe.integrationId)) {
      session.Org_Intelligence_Integration_Id__c = probe.integrationId;
      // Adopt Connected when GET verify shows the integration is already good to go.
      if (
        probe.credentialBound == true
        && verifiedOrg != null
        && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(verifiedOrg.orgId)
      ) {
        session.Selected_Org__c = verifiedOrg.orgName;
        session.Org_Credential_Id__c = verifiedOrg.orgId;
        session.Org_Context_Status__c = 'Connected';
        try {
          CopadoDevopsService.savePreferredIntegration(probe.integrationId);
          String projectId = CopadoDevopsService.getPreferredProjectId();
          CopadoDevopsService.saveUserPreference(verifiedOrg.orgId, projectId);
        } catch (Exception prefEx) {
          System.debug(LoggingLevel.WARN, 'OI ready preference save: ' + prefEx.getMessage());
        }
      }
    }
    update session;
    return getSessionState(sessionId);
  }

  /**
   * Map a connected Copado AI integration to an owned Dev Org Credential.
   * Prefers an exact match to the session/preferred credential; otherwise adopts
   * whatever credential the integration is already bound to (when the user owns it).
   */
  private static CopadoAiApiService.OrgInfo resolveOrgFromConnectedIntegration(
    String integrationId,
    String preferredCredId,
    CopadoAiApiService.OrgInfo preferredOrg
  ) {
    if (String.isBlank(integrationId)) {
      return null;
    }
    if (CopadoAiApiService.isMockMode()) {
      if (
        preferredOrg != null
        && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(preferredOrg.orgId)
      ) {
        return preferredOrg;
      }
      return null;
    }

    String boundCredId = CopadoAiApiService.getIntegrationSelectedCredentialId(integrationId);
    if (String.isBlank(boundCredId)) {
      return null;
    }
    String resolvedBound = CopadoDevopsService.resolveOrgCredentialId(boundCredId);
    if (String.isBlank(resolvedBound)) {
      resolvedBound = boundCredId;
    }

    if (String.isNotBlank(preferredCredId) && preferredOrg != null) {
      String resolvedPref = CopadoDevopsService.resolveOrgCredentialId(preferredCredId);
      Boolean idMatch =
        preferredCredId.equals(boundCredId)
        || preferredCredId.equals(resolvedBound)
        || (String.isNotBlank(resolvedPref)
          && (resolvedPref.equals(boundCredId) || resolvedPref.equals(resolvedBound)));
      Boolean nameMatch =
        String.isNotBlank(preferredOrg.orgName)
        && preferredOrg.orgName.equalsIgnoreCase(boundCredId);
      if (
        (idMatch || nameMatch)
        && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(preferredOrg.orgId)
      ) {
        return preferredOrg;
      }
    }

    if (!CopadoDevopsService.isOrgCredentialOwnedByRunningUser(resolvedBound)) {
      // Name-only bind echoes sometimes return the Salesforce org label.
      if (
        preferredOrg != null
        && String.isNotBlank(preferredOrg.orgName)
        && preferredOrg.orgName.equalsIgnoreCase(boundCredId)
        && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(preferredOrg.orgId)
      ) {
        return preferredOrg;
      }
      return null;
    }

    CopadoAiApiService.OrgInfo found = CopadoDevopsService.findNonProductionOrg(resolvedBound);
    if (found == null) {
      found = CopadoDevopsService.findOrgCredentialById(resolvedBound);
    }
    if (found != null && found.isProduction != true) {
      return found;
    }
    return null;
  }

  private static CopadoAiApiService.IntegrationInfo pickConnectedIntegration(
    List<CopadoAiApiService.IntegrationInfo> rows,
    String preferredIntegrationId
  ) {
    return CopadoAiApiService.pickBestIntegrationForCurrentUser(rows, preferredIntegrationId);
  }

  /**
   * Discover/bind Copado Org Intelligence for the selected Dev Org Credential
   * and optionally ask a live smoke-test question.
   * preferredIntegrationId — when set, reuse that Copado connection (e.g. User Level
   * or a custom-named integration the user created) and update its credential.
   */
  @AuraEnabled
  public static ActionResult connectOrgIntelligence(
    Id sessionId,
    String environmentId,
    Boolean askProbeQuestion,
    String preferredIntegrationId
  ) {
    validateSessionId(sessionId);
    ActionResult result = new ActionResult();
    if (String.isBlank(environmentId)) {
      result.success = false;
      result.message = 'Select a Dev environment first.';
      result.session = getSessionState(sessionId);
      return result;
    }
    if (String.isBlank(preferredIntegrationId)) {
      preferredIntegrationId = CopadoDevopsService.getPreferredIntegrationId();
    }

    CopadoAiApiService.OrgInfo org = CopadoDevopsService.findNonProductionOrg(environmentId);
    if (org == null) {
      result.success = false;
      result.message = 'That environment is not a safe non-production Dev org credential.';
      result.session = getSessionState(sessionId);
      return result;
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    String workspaceId = session.Workspace_Id__c;
    String dialogueId = session.Dialogue_Id__c;
    CopadoAiApiService.OrgIntelligenceResult probe;
    String bindCredId = CopadoDevopsService.resolveOrgCredentialId(environmentId);
    if (String.isBlank(bindCredId)) {
      bindCredId = org.orgId;
    } else if (bindCredId != org.orgId) {
      // Prefer resolved Org Credential Id over Environment Id for Copado AI binds.
      org.orgId = bindCredId;
    }

    try {
      if (String.isBlank(workspaceId)) {
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
      }
      if (String.isBlank(dialogueId)) {
        CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
          workspaceId,
          session.Name
        );
        dialogueId = created.dialogueId;
      }

      probe = CopadoAiApiService.ensureOrgIntelligence(
        workspaceId,
        bindCredId,
        org.orgName,
        dialogueId,
        askProbeQuestion == true,
        preferredIntegrationId
      );
    } catch (Exception ex) {
      result.success = false;
      result.message = 'Org Intelligence probe failed: ' + formatException(ex);
      result.session = getSessionState(sessionId);
      return result;
    }

    session = loadSession(sessionId);
    session.Workspace_Id__c = workspaceId;
    if (probe != null && String.isNotBlank(probe.chatDialogueId)) {
      session.Dialogue_Id__c = probe.chatDialogueId;
    } else if (String.isNotBlank(dialogueId)) {
      session.Dialogue_Id__c = dialogueId;
    }
    // Only stamp Selected_Org / Org_Credential after a verified bind.
    // Failed switches leave the previous Org Context untouched.
    Boolean boundOk = probe != null
      && probe.success == true
      && probe.credentialBound != false;
    if (boundOk && org != null) {
      session.Selected_Org__c = org.orgName;
      session.Org_Credential_Id__c = bindCredId;
      session.Org_Intelligence_Integration_Id__c = probe.integrationId;
      session.Org_Context_Status__c = 'Connected';
      // Remember as this user's default Dev credential for new chats / picker.
      try {
        String projectId = CopadoDevopsService.getPreferredProjectId();
        CopadoDevopsService.saveUserPreference(bindCredId, projectId);
        if (String.isNotBlank(probe.integrationId)) {
          CopadoDevopsService.savePreferredIntegration(probe.integrationId);
        }
      } catch (Exception prefEx) {
        System.debug(LoggingLevel.WARN, 'OI connect preference save: ' + prefEx.getMessage());
      }
    } else if (probe != null && probe.success != true) {
      // Keep prior Connected credential; surface failure in chat only.
      if (String.isBlank(session.Org_Context_Status__c)) {
        session.Org_Context_Status__c = formatOrgContextStatus(probe);
      }
    }
    update session;

    String statusLine = formatOrgIntelligenceChatMessage(
      org != null ? org.orgName : null,
      boundOk ? 'Connected' : formatOrgContextStatus(probe),
      probe
    );
    insertMessage(sessionId, 'System', statusLine, 'Org Intelligence');

    // Connect success = healthy Copado cicd link for this credential.
    // Live metadata is verified when the user asks a normal chat question (no throwaway probes).
    result.success = boundOk;
    result.message = statusLine;
    result.orgIntelligence = probe;
    result.session = getSessionState(sessionId);
    if (result.session != null && boundOk && org != null) {
      // getSessionState must not undo a verified bind (owned-credential check).
      result.session.orgContextStatus = 'Connected';
      result.session.selectedOrg = org.orgName;
      result.session.selectedOrgId = bindCredId;
      result.session.connectedOrgId = bindCredId;
      result.session.connectedOrgName = org.orgName;
      if (String.isNotBlank(probe.integrationId)) {
        result.session.orgIntelligenceIntegrationId = probe.integrationId;
      }
    }
    return result;
  }

  /**
   * Start Copado AI Salesforce OAuth for live Org Intelligence metadata.
   * Caller opens authUrl in a new browser tab, then reconnects.
   */
  @AuraEnabled
  public static CopadoAiApiService.SalesforceAuthResult startSalesforceMetadataAuth(
    Id sessionId,
    String redirectUri,
    String orgType
  ) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    String workspaceId = session.Workspace_Id__c;
    try {
      if (String.isBlank(workspaceId)) {
        // Callout only — persist workspace Id on the next Connect / sendMessage.
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
      }
    } catch (Exception ex) {
      CopadoAiApiService.SalesforceAuthResult fail = new CopadoAiApiService.SalesforceAuthResult();
      fail.success = false;
      fail.message = 'Could not resolve Builder workspace: ' + formatException(ex);
      return fail;
    }
    String name = 'Builder '
      + (String.isNotBlank(session.Selected_Org__c) ? session.Selected_Org__c : 'Dev');
    return CopadoAiApiService.beginSalesforceOrgAuth(
      workspaceId,
      name,
      String.isNotBlank(orgType) ? orgType : 'SANDBOX',
      redirectUri
    );
  }

  private static String formatOrgIntelligenceChatMessage(
    String orgName,
    String status,
    CopadoAiApiService.OrgIntelligenceResult probe
  ) {
    String orgLabel = String.isNotBlank(orgName) ? orgName : 'Dev org';
    if ('Connected'.equalsIgnoreCase(status)) {
      return 'Org Intelligence connected for ' + orgLabel + '.';
    }
    String detail = probe != null && String.isNotBlank(probe.message)
      ? probe.message
      : 'Could not connect.';
    // Keep chat readable — strip raw JSON / long diagnostics from user-facing text.
    Integer cut = detail.indexOf('{');
    if (cut > 20) {
      detail = detail.substring(0, cut).trim();
    }
    if (detail.length() > 180) {
      detail = detail.substring(0, 177) + '...';
    }
    return 'Org Intelligence: ' + (String.isNotBlank(status) ? status : 'Not connected')
      + ' for ' + orgLabel + '. ' + detail;
  }

  public class UserStoryOption {
    @AuraEnabled public Id id;
    @AuraEnabled public String name;
    @AuraEnabled public String title;
    @AuraEnabled public String label;
  }

  @AuraEnabled
  public static List<UserStoryOption> listCopadoUserStories(String searchTerm) {
    List<UserStoryOption> options = new List<UserStoryOption>();
    if (Schema.getGlobalDescribe().get('copado__User_Story__c') == null) {
      return options;
    }

    String likeTerm = String.isBlank(searchTerm) ? '%' : '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
    String soql =
      'SELECT Id, Name, copado__User_Story_Title__c '
      + 'FROM copado__User_Story__c '
      + 'WHERE Name LIKE \'' + likeTerm + '\' '
      + 'OR copado__User_Story_Title__c LIKE \'' + likeTerm + '\' '
      + 'ORDER BY LastModifiedDate DESC LIMIT 50';

    try {
      for (SObject row : Database.query(soql)) {
        UserStoryOption opt = new UserStoryOption();
        opt.id = (Id) row.get('Id');
        opt.name = String.valueOf(row.get('Name'));
        opt.title = row.get('copado__User_Story_Title__c') != null
          ? String.valueOf(row.get('copado__User_Story_Title__c'))
          : '';
        opt.label = String.isBlank(opt.title) ? opt.name : opt.name + ' — ' + opt.title;
        options.add(opt);
      }
    } catch (Exception ex) {
      // Fallback without title field
      try {
        for (SObject row : Database.query(
          'SELECT Id, Name FROM copado__User_Story__c ORDER BY LastModifiedDate DESC LIMIT 50'
        )) {
          UserStoryOption opt = new UserStoryOption();
          opt.id = (Id) row.get('Id');
          opt.name = String.valueOf(row.get('Name'));
          opt.title = '';
          opt.label = opt.name;
          options.add(opt);
        }
      } catch (Exception ignore) {
      }
    }
    return options;
  }

  /**
   * Link an existing Copado User Story into this Builder session without updating
   * the story fields. Loads requirements into Summary so Build Code can run.
   * UX: New Chat → Find Existing Story → Use Story → Build Code.
   */
  @AuraEnabled
  public static ActionResult openCopadoUserStory(Id sessionId, Id userStoryId) {
    validateSessionId(sessionId);
    if (userStoryId == null) {
      return failure('Select a Copado User Story to open.');
    }

    CopadoDevopsService.UserStoryContext storyCtx =
      CopadoDevopsService.getUserStoryContext(userStoryId);
    if (storyCtx == null || String.isBlank(storyCtx.name)) {
      return failure(
        'Could not load that User Story. Check access to Copado User Story fields, then retry.'
      );
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    String workspaceId = session.Workspace_Id__c;
    String dialogueId = session.Dialogue_Id__c;

    // Ensure AI dialogue exists (callouts before DML).
    try {
      if (String.isBlank(workspaceId) || String.isBlank(dialogueId)) {
        CopadoAiApiService.WorkspaceResult workspace = CopadoAiApiService.ensureBuilderWorkspace();
        workspaceId = workspace.workspaceId;
      }
      if (String.isBlank(dialogueId)) {
        CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
          workspaceId,
          'Existing story ' + storyCtx.name
        );
        dialogueId = created.dialogueId;
      }
      // Seed dialogue with story context so later Build / Improve use it.
      if (String.isNotBlank(dialogueId) && String.isNotBlank(storyCtx.summaryText)) {
        try {
          CopadoAiApiService.DialogueResult seeded = CopadoAiApiService.sendDialogueMessage(
            dialogueId,
            'I am loading an existing Copado User Story into this Builder session. '
              + 'Use these requirements as the source of truth unless I ask to change them:\n\n'
              + storyCtx.summaryText,
            null,
            null,
            workspaceId
          );
          if (seeded != null && String.isNotBlank(seeded.dialogueId)) {
            dialogueId = seeded.dialogueId;
          }
        } catch (Exception ignore) {
        }
      }
    } catch (Exception ex) {
      // Still link the story locally even if AI is unavailable.
      System.debug(LoggingLevel.WARN, 'openCopadoUserStory dialogue: ' + formatException(ex));
    }

    session = loadSession(sessionId);
    Boolean switchedStory = storyRecordChanged(session, storyCtx.recordId);
    applyStoryLink(session, storyCtx.recordId, storyCtx.name, storyCtx.title);
    if (switchedStory) {
      resetPipelineForStoryChange(session, storyCtx.recordId, false);
    }
    session.Workspace_Id__c = workspaceId;
    session.Dialogue_Id__c = dialogueId;
    session.Summary__c = truncateForLongText(storyCtx.summaryText, 131072);
    // Status__c is a restricted picklist — "Story Linked" is not a valid value.
    session.Status__c = 'Story Created';
    if (!switchedStory && String.isBlank(session.Current_Step__c)) {
      session.Current_Step__c = 'Story Linked';
    }
    if (String.isNotBlank(storyCtx.projectId)) {
      CopadoDevopsService.savePreferredProject(storyCtx.projectId);
    }
    String resolvedCredId = CopadoDevopsService.resolveOrgCredentialId(storyCtx.environmentId);
    if (String.isNotBlank(resolvedCredId)) {
      CopadoAiApiService.OrgInfo storyOrg = CopadoDevopsService.findOrgCredentialById(resolvedCredId);
      if (storyOrg != null) {
        session.Selected_Org__c = storyOrg.orgName;
      }
      session.Org_Credential_Id__c = resolvedCredId;
    }
    update session;

    String linkMsg = 'Linked ' + storyCtx.name
      + (String.isNotBlank(storyCtx.title) ? ' — ' + storyCtx.title : '');
    if (switchedStory) {
      linkMsg += '. Pipeline status reset for this story'
        + ('Committed'.equalsIgnoreCase(session.Current_Step__c)
          ? ' (User Story Commit found — Validate is Ready).'
          : ' (ready to Build).');
    } else {
      linkMsg += '.';
    }
    insertMessage(sessionId, 'System', linkMsg, session.Current_Step__c);
    if (String.isNotBlank(storyCtx.summaryText)) {
      insertMessage(sessionId, 'Assistant', storyCtx.summaryText, 'Story Linked');
    }

    // Score from linked story body (Summary + Assistant draft), not User chat alone.
    StoryScore linkedScore = scoreStory(sessionId);
    session = loadSession(sessionId);
    Integer linkedTotal = linkedScore.totalScore != null ? linkedScore.totalScore : 0;
    session.Score__c = Math.max(70, linkedTotal);
    session.Risk_Level__c = linkedScore.riskLevel;
    update session;

    ActionResult result = new ActionResult();
    result.success = true;
    result.message = 'Opened ' + storyCtx.name + '. '
      + (String.isNotBlank(resolvedCredId)
        ? 'Dev environment pre-selected from the story.'
        : 'Select a Dev environment from the project pipeline below.');
    result.session = getSessionState(sessionId);
    return result;
  }

  @AuraEnabled
  public static ActionResult createCopadoStory(
    Id sessionId,
    Boolean updateExisting,
    Id targetStoryId,
    String projectId
  ) {
    validateSessionId(sessionId);
    AI_Builder_Action__c action;

    try {
      AI_Builder_Session__c session = loadSession(sessionId);

      StoryScore score = scoreStory(sessionId);
      if (score.totalScore < 40) {
        return failure(
          'Story needs more detail before creating a Copado story. Use Improve Story or continue chatting.'
        );
      }

      if (updateExisting == true && targetStoryId == null && String.isBlank(session.Copado_User_Story__c)) {
        return failure('Select a Copado User Story to update, or create a new one.');
      }

      if (updateExisting != true && targetStoryId == null && String.isBlank(projectId)
        && !CopadoAiApiService.isMockMode()) {
        return failure(
          'Select a Copado Project in the Status panel before creating a user story. '
          + 'This must match the pipeline that contains your Dev environment (for example Dev1).'
        );
      }

      // Callouts first (no DML yet)
      Map<String, Object> storyData = buildStoryData(sessionId);
      storyData.put('updateExisting', updateExisting == true);
      if (String.isNotBlank(projectId)) {
        storyData.put('projectId', projectId);
      }
      if (targetStoryId != null) {
        storyData.put('targetStoryId', String.valueOf(targetStoryId));
        storyData.put('updateExisting', true);
      }
      if (updateExisting != true && targetStoryId == null) {
        storyData.put('existingStoryRef', null);
        storyData.put('updateExisting', false);
      }

      try {
        storyData = CopadoAiApiService.enrichStoryDataWithAi(session.Dialogue_Id__c, storyData);
      } catch (Exception enrichEx) {
        // Continue with locally parsed fields if AI structuring fails
        storyData.put('enrichError', formatException(enrichEx));
      }

      String requestJson = JSON.serialize(storyData);
      action = logAction(
        sessionId,
        (updateExisting == true || targetStoryId != null) ? 'Update Story' : 'Create Story',
        'In Progress',
        requestJson,
        null,
        null
      );

      CopadoAiApiService.StoryResult story = CopadoAiApiService.createUserStory(
        String.valueOf(sessionId),
        storyData
      );

      // Stamp the Org Intelligence / Status-panel Dev org onto the new User Story
      // (same credential used for live metadata). Best-effort — create still succeeds.
      String oiOrgCred = session.Org_Credential_Id__c;
      String envStampMsg = null;
      if (String.isNotBlank(oiOrgCred) && String.isNotBlank(story.recordId)) {
        try {
          envStampMsg = CopadoDevopsService.assignEnvironmentToUserStory(
            (Id) story.recordId,
            oiOrgCred
          );
        } catch (Exception envEx) {
          envStampMsg = 'Story created, but could not set Dev org on the User Story: '
            + formatException(envEx);
        }
      }

      if (action != null) {
        action.Status__c = 'Success';
        action.Response__c = JSON.serialize(story);
        update action;
      }

      if (String.isNotBlank(projectId) && updateExisting != true) {
        try {
          CopadoDevopsService.savePreferredProject(projectId);
        } catch (Exception ignore) {
        }
      }

      Boolean didUpdate = updateExisting == true || targetStoryId != null;
      Id previousStoryId = null;
      if (String.isNotBlank(session.Story_Record_Id__c)) {
        try {
          previousStoryId = (Id) session.Story_Record_Id__c;
        } catch (Exception ignore) {
        }
      }
      Id newStoryId = null;
      if (String.isNotBlank(story.recordId)) {
        try {
          newStoryId = (Id) story.recordId;
        } catch (Exception ignore) {
        }
      }
      Boolean isBrandNewStory = !didUpdate;
      Boolean switchedToDifferentStory =
        didUpdate
        && newStoryId != null
        && previousStoryId != null
        && previousStoryId != newStoryId;

      applyStoryLink(session, story.recordId, story.storyId, story.storyName);
      if (isBrandNewStory || switchedToDifferentStory) {
        resetPipelineForStoryChange(session, newStoryId, isBrandNewStory);
      } else {
        session.Status__c = 'Story Created';
        session.Current_Step__c = 'Story Created';
      }
      session.Summary__c = story.summary;
      update session;

      String storyLabel = story.storyId
        + (String.isNotBlank(story.storyName) ? ' — ' + story.storyName : '');
      insertMessage(
        sessionId,
        'System',
        (didUpdate ? 'Updated' : 'Created') + ' Copado user story: ' + storyLabel
          + (String.isNotBlank(envStampMsg) && !didUpdate ? '. ' + envStampMsg : '')
          + (isBrandNewStory
            ? ' Pipeline status reset — ready to Build.'
            : (switchedToDifferentStory ? ' Pipeline status reset for the new story link.' : '')),
        session.Current_Step__c
      );

      ActionResult result = new ActionResult();
      result.success = true;
      result.message = (didUpdate ? 'Updated' : 'Created') + ' ' + storyLabel
        + (String.isNotBlank(envStampMsg) && !didUpdate ? '. ' + envStampMsg : '');
      result.session = getSessionState(sessionId);
      return result;
    } catch (Exception ex) {
      if (action != null && action.Id != null) {
        try {
          action.Status__c = 'Failed';
          action.Error__c = formatException(ex);
          update action;
        } catch (Exception ignore) {
        }
      }
      return failure(
        'Could not '
        + (updateExisting == true ? 'update' : 'create')
        + ' Copado story: '
        + formatException(ex)
      );
    }
  }

  @AuraEnabled
  public static ActionResult buildCode(Id sessionId, String environmentId, Boolean rememberPreference) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    if (story.recordId == null && String.isBlank(story.name)) {
      return failure('Create or select a Copado user story before building.');
    }
    Id storyId = story.recordId;
    if (storyId == null) {
      if (CopadoAiApiService.isMockMode()) {
        storyId = sessionId;
      } else {
        return failure(
          'This chat is linked to '
          + story.name
          + ' without a Salesforce record Id. Create a Copado story or Use Story first.'
        );
      }
    }

    // Mark rebuild in progress before the AI callout so Status panel leaves Successful.
    // Status__c is a restricted picklist — use In Progress (not "Building").
    session.Current_Step__c = 'Building';
    session.Status__c = 'In Progress';
    session.Last_Job_Action__c = 'Build';
    // Invalidate prior Deploy / Commit / Validate while a new package is generating.
    session.Last_Deploy_Job_Id__c = null;
    session.Last_Commit_Job_Id__c = null;
    session.Last_Promotion_Id__c = null;
    session.Last_Job_Id__c = null;
    update session;

    // Build only needs AI + story specs. A missing/invalid Dev credential must not
    // block package generation (Deploy will still require a validated org).
    String safeEnvironmentId = null;
    if (String.isNotBlank(environmentId)) {
      if (CopadoAiApiService.isMockMode()
        || CopadoDevopsService.findNonProductionOrg(environmentId) != null) {
        safeEnvironmentId = environmentId;
      }
    }

    // Callouts first — package generation uses a FRESH Build dialogue.
    // Do not reuse the chat dialogue (long "Yes 1." / layout prose threads often
    // leave the Build agent still generating → empty reply timeouts).
    // Do not pre-seed a second generate prompt before generatePackageWithAi.
    String workspaceId = session.Workspace_Id__c;
    String chatDialogueId = session.Dialogue_Id__c;
    String buildDialogueId = null;
    String requirements = session.Summary__c;
    String storyLabel = formatStoryRef(story);
    String storyContext = buildLeanBuildContext(sessionId, session);
    String projectId = CopadoDevopsService.getProjectIdFromUserStory(storyId);

    if (!CopadoAiApiService.isMockMode()) {
      try {
        if (String.isBlank(workspaceId)) {
          CopadoAiApiService.WorkspaceResult workspace =
            CopadoAiApiService.ensureBuilderWorkspace();
          if (workspace != null && String.isNotBlank(workspace.workspaceId)) {
            workspaceId = workspace.workspaceId;
          }
        }
        if (String.isNotBlank(workspaceId)) {
          CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
            workspaceId,
            'Build ' + storyLabel + ' ' + String.valueOf(Datetime.now().getTime())
          );
          if (created != null && String.isNotBlank(created.dialogueId)) {
            buildDialogueId = created.dialogueId;
          }
        }
      } catch (Exception setupEx) {
        System.debug(LoggingLevel.WARN, 'buildCode dialogue setup: ' + formatException(setupEx));
      }
    }

    // Prefer a dedicated Build dialogue so package generation is not blocked by a
    // long chat / validate thread that may still be streaming. Fall back to chat
    // dialogue only when Build dialogue creation failed.
    String packageDialogueId = String.isNotBlank(buildDialogueId) ? buildDialogueId : chatDialogueId;

    if (!CopadoAiApiService.isMockMode() && String.isBlank(packageDialogueId)) {
      return failBuildInProgress(
        sessionId,
        'Build needs a Copado AI dialogue. Send a chat message first, or reconnect Org Intelligence, then try Build again.'
      );
    }

    // Resolve live Metadata API fullNames from Org Intelligence BEFORE package gen
    // so we never invent Account-Account Layout / wrong Flow/Profile names.
    try {
      Map<String, List<String>> liveByType = resolveLiveMetadataViaOrgIntelligence(
        session,
        workspaceId,
        chatDialogueId,
        storyContext,
        null
      );
      // Reuse any AUTHORITATIVE block already scraped from this chat session.
      if (liveByType == null || liveByType.isEmpty()) {
        liveByType = extractLiveMetadataFromSession(sessionId, session);
      }
      String authBlock =
        CopadoDevopsService.formatAuthoritativeLiveMetadataBlock(liveByType);
      if (String.isNotBlank(authBlock)) {
        storyContext =
          (String.isNotBlank(storyContext) ? storyContext + '\n\n' : '')
          + authBlock;
        System.debug(LoggingLevel.INFO, 'Build live metadata:\n' + authBlock);
      }
    } catch (Exception liveEx) {
      System.debug(
        LoggingLevel.WARN,
        'resolveLiveMetadataViaOrgIntelligence: ' + formatException(liveEx)
      );
    }

    CopadoAiApiService.BuildResult build;
    try {
      build = CopadoAiApiService.buildCode(
        packageDialogueId,
        storyLabel,
        requirements,
        storyContext
      );
    } catch (Exception ex) {
      return failBuildInProgress(sessionId, 'Build failed: ' + formatException(ex));
    }
    if (build != null && build.pending == true) {
      return markBuildPending(sessionId, build, workspaceId, safeEnvironmentId, projectId, story);
    }
    if (build == null || String.isBlank(build.packageJson)) {
      return failBuildInProgress(
        sessionId,
        'Build finished without a metadata package. Try Improve Story, then Build again.'
      );
    }

    return finalizeSuccessfulBuild(
      sessionId,
      build,
      workspaceId,
      safeEnvironmentId,
      projectId,
      story,
      storyId
    );
  }

  /**
   * Copado AI still generating — stash poll keys and let LWC pollBuildPackage.
   */
  private static ActionResult markBuildPending(
    Id sessionId,
    CopadoAiApiService.BuildResult build,
    String workspaceId,
    String safeEnvironmentId,
    String projectId,
    StoryRef story
  ) {
    AI_Builder_Session__c session = loadSession(sessionId);
    if (String.isNotBlank(workspaceId)) {
      session.Workspace_Id__c = workspaceId;
    }
    applyStoryLink(session, story.recordId, story.name, story.title);
    Map<String, Object> pending = new Map<String, Object>{
      '_pendingBuild' => true,
      'dialogueId' => build.dialogueId,
      'requestId' => build.requestId,
      'baselineMessageCount' => build.baselineMessageCount,
      'baselineAssistantText' => build.baselineAssistantText,
      'startedAt' => Datetime.now().getTime(),
      'nudgeCount' => 0,
      'storyLabel' => formatStoryRef(story)
    };
    session.Build_Package_Json__c = JSON.serialize(pending);
    session.Last_Build_Id__c = 'pending-build';
    session.Last_Job_Action__c = 'Build';
    session.Current_Step__c = 'Building';
    session.Status__c = 'In Progress';
    if (String.isNotBlank(safeEnvironmentId)) {
      CopadoAiApiService.OrgInfo selected = CopadoDevopsService.findNonProductionOrg(safeEnvironmentId);
      session.Selected_Org__c = selected != null ? selected.orgName : safeEnvironmentId;
      session.Org_Credential_Id__c = safeEnvironmentId;
    }
    update session;
    if (String.isNotBlank(safeEnvironmentId) && String.isNotBlank(projectId)) {
      try {
        CopadoDevopsService.saveUserPreference(safeEnvironmentId, projectId);
      } catch (Exception ignore) {
      }
    }

    ActionResult result = new ActionResult();
    result.success = true;
    result.awaitingBuild = true;
    result.message =
      'Copado AI is still generating the metadata package. Builder will keep waiting…';
    result.session = getSessionState(sessionId);
    return result;
  }

  private static ActionResult finalizeSuccessfulBuild(
    Id sessionId,
    CopadoAiApiService.BuildResult build,
    String workspaceId,
    String safeEnvironmentId,
    String projectId,
    StoryRef story,
    Id storyId
  ) {
    // Final gate: remap invented layout names / drop gated members not in live lists.
    if (build != null && String.isNotBlank(build.packageJson)) {
      try {
        AI_Builder_Session__c ctxSession = loadSession(sessionId);
        String ctx = buildLeanBuildContext(sessionId, ctxSession);
        String normalized = CopadoDevopsService.normalizePackageMetadataWithContext(
          build.packageJson,
          ctx
        );
        if (String.isNotBlank(normalized) && !normalized.equals(build.packageJson)) {
          build.packageJson = normalized;
          build.artifacts = extractArtifactPaths(normalized);
        }
      } catch (Exception layoutNormEx) {
        System.debug(
          LoggingLevel.WARN,
          'normalizePackageMetadataWithContext: ' + formatException(layoutNormEx)
        );
      }
    }

    // Optional: stamp selected Dev env on the story for the later Commit step.
    if (String.isNotBlank(safeEnvironmentId)) {
      try {
        CopadoDevopsService.assignEnvironmentToUserStory(storyId, safeEnvironmentId);
      } catch (Exception ignore) {
      }
      try {
        CopadoDevopsService.saveUserPreference(safeEnvironmentId, projectId);
      } catch (Exception ignore) {
      }
    }

    Id contentDocId = storePackageArtifact(sessionId, build.buildId, build.packageJson);
    Integer stamped = 0;
    if (String.isNotBlank(build.packageJson)) {
      try {
        stamped = CopadoDevopsService.stampUserStoryBuildArtifacts(
          storyId,
          build.packageJson,
          build.artifacts
        );
      } catch (Exception stampEx) {
        System.debug(
          LoggingLevel.WARN,
          'stampUserStoryBuildArtifacts: ' + formatException(stampEx)
        );
      }
    }

    logAction(
      sessionId,
      'Build',
      'Success',
      JSON.serialize(new Map<String, Object>{
        'storyRecordId' => String.valueOf(story.recordId),
        'storyName' => story.name,
        'environmentId' => safeEnvironmentId,
        'replacedArtifacts' => true,
        'metadataCount' => stamped
      }),
      JSON.serialize(build),
      null
    );

    AI_Builder_Session__c session = loadSession(sessionId);
    if (String.isNotBlank(workspaceId)) {
      session.Workspace_Id__c = workspaceId;
    }
    applyStoryLink(session, story.recordId, story.name, story.title);
    session.Last_Build_Id__c = build.buildId;
    session.Artifact_Content_Document_Id__c = contentDocId != null ? String.valueOf(contentDocId) : null;
    session.Build_Package_Json__c = truncateForLongText(build.packageJson, 131072);
    session.Last_Deploy_Job_Id__c = null;
    session.Last_Commit_Job_Id__c = null;
    session.Last_Job_Action__c = null;
    session.Last_Promotion_Id__c = null;
    session.Last_Job_Id__c = null;
    if (String.isNotBlank(safeEnvironmentId)) {
      CopadoAiApiService.OrgInfo selected = CopadoDevopsService.findNonProductionOrg(safeEnvironmentId);
      session.Selected_Org__c = selected != null ? selected.orgName : safeEnvironmentId;
      session.Org_Credential_Id__c = safeEnvironmentId;
    }
    session.Current_Step__c = 'Code Built';
    session.Status__c = 'Code Built';
    update session;

    List<String> newPaths = extractArtifactPaths(build.packageJson);
    String msg = shortenBuildSummary(build.summary);
    if (newPaths != null && !newPaths.isEmpty()) {
      msg += ' Replaced artifacts with: ' + String.join(newPaths, ', ') + '.';
    }
    if (!msg.toLowerCase().contains('ready to deploy')
      && !msg.toLowerCase().contains('ready to commit')) {
      msg += ' Ready to Deploy.';
    }
    insertMessage(sessionId, 'System', msg, 'Code Built');

    ActionResult result = new ActionResult();
    result.success = true;
    result.awaitingBuild = false;
    result.message = msg;
    result.session = getSessionState(sessionId);
    return result;
  }

  @AuraEnabled
  public static ActionResult pollBuildPackage(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    Map<String, Object> pending = parsePendingBuildMarker(session.Build_Package_Json__c);
    if (pending == null) {
      // Already completed or never pending.
      if (String.isNotBlank(session.Build_Package_Json__c)
        && !session.Build_Package_Json__c.contains('_pendingBuild')) {
        ActionResult done = new ActionResult();
        done.success = true;
        done.awaitingBuild = false;
        done.message = 'Build package is ready.';
        done.session = getSessionState(sessionId);
        return done;
      }
      return failBuildInProgress(sessionId, 'No pending Build to poll. Click Build again.');
    }

    String dialogueId = pending.get('dialogueId') != null
      ? String.valueOf(pending.get('dialogueId'))
      : null;
    Long startedAt = null;
    try {
      if (pending.get('startedAt') != null) {
        startedAt = Long.valueOf(String.valueOf(pending.get('startedAt')));
      }
    } catch (Exception ignore) {
    }
    // Large packages can take several minutes; simple fields should finish via nudge sooner.
    if (startedAt != null && (Datetime.now().getTime() - startedAt) > 480000) {
      return failBuildInProgress(
        sessionId,
        'Build timed out waiting for Copado AI package JSON. Wait a moment, then click Build once more.'
      );
    }

    String raw = null;
    try {
      raw = CopadoAiApiService.tryRecoverPackageJson(dialogueId);
    } catch (Exception ex) {
      ActionResult still = new ActionResult();
      still.success = true;
      still.awaitingBuild = true;
      still.message = 'Still waiting for Copado AI package…';
      still.session = getSessionState(sessionId);
      return still;
    }

    // If Copado AI returned prose/empty on the first turn, re-prompt mid-poll.
    // Without this, simple CustomField builds sat until the hard timeout.
    Integer nudgeCount = 0;
    try {
      if (pending.get('nudgeCount') != null) {
        nudgeCount = Integer.valueOf(String.valueOf(pending.get('nudgeCount')));
      }
    } catch (Exception ignore) {
    }
    Long elapsedMs = startedAt != null ? (Datetime.now().getTime() - startedAt) : 0;
    Boolean shouldNudge =
      String.isBlank(raw)
      && nudgeCount < 2
      && (
        (nudgeCount == 0 && elapsedMs >= 25000)
        || (nudgeCount == 1 && elapsedMs >= 70000)
      );
    if (shouldNudge) {
      String storyLabel = pending.get('storyLabel') != null
        ? String.valueOf(pending.get('storyLabel'))
        : formatStoryRef(resolveStoryRef(session));
      String storyContext = buildLeanBuildContext(sessionId, session);
      try {
        raw = CopadoAiApiService.nudgePackageGeneration(dialogueId, storyLabel, storyContext);
      } catch (Exception nudgeEx) {
        System.debug(LoggingLevel.WARN, 'Build nudge failed: ' + formatException(nudgeEx));
      }
      pending.put('nudgeCount', nudgeCount + 1);
      pending.put('lastNudgeAt', Datetime.now().getTime());
      session.Build_Package_Json__c = JSON.serialize(pending);
      update session;
    }

    StoryRef story = resolveStoryRef(session);
    Id storyId = story.recordId != null ? story.recordId : sessionId;
    CopadoAiApiService.BuildResult build =
      CopadoAiApiService.buildResultFromPackageJson(raw, formatStoryRef(story));
    if (build == null || String.isBlank(build.packageJson)) {
      ActionResult still = new ActionResult();
      still.success = true;
      still.awaitingBuild = true;
      still.message = shouldNudge
        ? 'Re-prompted Copado AI for package JSON…'
        : 'Still waiting for Copado AI package…';
      still.session = getSessionState(sessionId);
      return still;
    }

    String projectId = CopadoDevopsService.getProjectIdFromUserStory(storyId);
    return finalizeSuccessfulBuild(
      sessionId,
      build,
      session.Workspace_Id__c,
      session.Org_Credential_Id__c,
      projectId,
      story,
      storyId
    );
  }

  private static Map<String, Object> parsePendingBuildMarker(String packageJson) {
    if (String.isBlank(packageJson) || !packageJson.contains('_pendingBuild')) {
      return null;
    }
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(packageJson);
      if (parsed != null && parsed.get('_pendingBuild') == true) {
        return parsed;
      }
    } catch (Exception ignore) {
    }
    return null;
  }

  private static String shortenBuildSummary(String summary) {
    if (String.isBlank(summary)) {
      return 'Build complete.';
    }
    String s = summary.trim();
    // Prefer first sentence / artifact line without dumping full package narrative.
    Integer artifactAt = s.indexOf('Artifacts:');
    if (artifactAt > 0) {
      String head = s.substring(0, artifactAt).trim();
      String artifacts = s.substring(artifactAt);
      Integer period = artifacts.indexOf('. ');
      if (period > 0) {
        artifacts = artifacts.substring(0, period + 1);
      } else if (artifacts.length() > 120) {
        artifacts = artifacts.substring(0, 117) + '...';
      }
      s = head + ' ' + artifacts;
    }
    if (s.length() > 280) {
      s = s.substring(0, 277) + '...';
    }
    return s;
  }

  /**
   * Refresh Copado Job Execution status for the session's last deploy/commit/validate job.
   * Surfaces failures as System chat messages.
   */
  @AuraEnabled
  public static ActionResult refreshJobStatus(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);

    // Validate/Deploy-next often leave Last_Job_Id as validate-queued (or blank after the
    // queueable finishes without finding a JE). Adopt the Promotion's Job Execution so
    // Refresh does not say "No Copado job / Run Build Code first."
    session = resolveLastJobIdForRefresh(session);

    if (String.isBlank(session.Last_Job_Id__c)) {
      Boolean validateLike =
        'Validating'.equalsIgnoreCase(session.Current_Step__c)
        || 'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
        || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c);
      if (validateLike) {
        Boolean wasDeployNext =
          'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
          || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c);
        session.Current_Step__c = wasDeployNext ? 'Validated' : 'Committed';
        // Do not overwrite story Summary__c with job diagnostics (destabilizes Story Score).
        update session;
        String healMsg = wasDeployNext
          ? 'Deploy to next did not start a Job Execution. Check Promotion / Job Templates.'
          : 'Validate did not start a Job Execution. Check Promotion Pipeline and '
            + 'Validate Promote/Deploy Job Template API names.';
        ActionResult healed = new ActionResult();
        healed.success = false;
        healed.message = healMsg;
        healed.session = getSessionState(sessionId);
        return healed;
      }
      return failure('No Copado job on this chat yet. Run Deploy or Commit first.');
    }

    if (isValidateQueuedJobId(session.Last_Job_Id__c)
      || isDeployNextQueuedJobId(session.Last_Job_Id__c)) {
      ActionResult waiting = new ActionResult();
      waiting.success = true;
      waiting.message =
        isDeployNextQueuedJobId(session.Last_Job_Id__c)
          ? 'Deploy to next is still starting. Try Refresh again in a few seconds.'
          : 'Validate is still starting. Try Refresh again in a few seconds.';
      waiting.session = getSessionState(sessionId);
      return waiting;
    }

    CopadoDevopsService.JobStatus job;
    Boolean validateOrNext =
      'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
      || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
      || 'Validated'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c);
    Id promotionForStatus = null;
    if (validateOrNext && String.isNotBlank(session.Last_Promotion_Id__c)) {
      try {
        promotionForStatus = (Id) session.Last_Promotion_Id__c;
      } catch (Exception ignore) {
      }
    }
    if (promotionForStatus != null) {
      // Authoritative: Promotion Status (Promote JE can succeed while Deploy validate fails).
      job = CopadoDevopsService.resolveValidateOrDeployNextStatus(
        session.Last_Job_Id__c,
        promotionForStatus,
        true
      );
    } else {
      job = CopadoDevopsService.getJobExecutionStatus(session.Last_Job_Id__c, true);
    }

    if (job.isComplete == true && job.isFailed != true
      && String.isNotBlank(job.summary)
      && (job.summary.contains('Linked User Story Commit')
        || job.summary.contains('USC link failed')
        || job.summary.contains('Skip USC link'))) {
      Boolean alreadyLogged = false;
      for (AI_Builder_Message__c existing : [
        SELECT Message__c
        FROM AI_Builder_Message__c
        WHERE Session__c = :sessionId AND Role__c = 'System'
        ORDER BY CreatedDate DESC
        LIMIT 8
      ]) {
        if (String.isNotBlank(existing.Message__c)
          && existing.Message__c.contains(session.Last_Job_Id__c)
          && (existing.Message__c.contains('Linked User Story Commit')
            || existing.Message__c.contains('USC link'))) {
          alreadyLogged = true;
          break;
        }
      }
      if (!alreadyLogged) {
        insertMessage(
          sessionId,
          'System',
          job.summary + ' (Job ' + session.Last_Job_Id__c + ')',
          session.Current_Step__c
        );
      }
    }

    if (job.isFailed == true && String.isNotBlank(job.summary)) {
      String failKey = 'Validate failed:';
      if ('DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)) {
        failKey = 'Deploy to next failed:';
      } else if (
        !'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        && !'Validating'.equalsIgnoreCase(session.Current_Step__c)
        && !'Validated'.equalsIgnoreCase(session.Current_Step__c)
      ) {
        failKey = 'Job failed:';
      }
      Boolean alreadyLogged = false;
      for (AI_Builder_Message__c existing : [
        SELECT Message__c
        FROM AI_Builder_Message__c
        WHERE Session__c = :sessionId AND Role__c = 'System'
        ORDER BY CreatedDate DESC
        LIMIT 8
      ]) {
        if (String.isNotBlank(existing.Message__c)
          && existing.Message__c.contains(failKey)
          && (
            (String.isNotBlank(session.Last_Promotion_Id__c)
              && existing.Message__c.contains(session.Last_Promotion_Id__c))
            || (String.isNotBlank(session.Last_Job_Id__c)
              && existing.Message__c.contains(session.Last_Job_Id__c))
            || existing.Message__c.contains(job.summary)
          )) {
          alreadyLogged = true;
          break;
        }
      }
      if (!alreadyLogged) {
        String detail = job.summary;
        if (String.isNotBlank(session.Last_Promotion_Id__c)) {
          detail += ' (Promotion ' + session.Last_Promotion_Id__c + ')';
        } else if (String.isNotBlank(session.Last_Job_Id__c)) {
          detail += ' (Job ' + session.Last_Job_Id__c + ')';
        }
        insertMessage(sessionId, 'System', failKey + ' ' + detail, session.Current_Step__c);
      }
      // Validate dry-run failed — do not leave Status as Successful.
      if ('Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
        || 'Validated'.equalsIgnoreCase(session.Current_Step__c)) {
        session.Current_Step__c = 'Committed';
        update session;
      } else if (
        'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      ) {
        session.Current_Step__c = 'Validated';
        update session;
      }
    } else if (
      job.isComplete == true
      && job.isFailed != true
      && ('Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'Validating'.equalsIgnoreCase(session.Current_Step__c))
    ) {
      session.Current_Step__c = 'Validated';
      update session;
      insertMessage(
        sessionId,
        'System',
        'Validate succeeded. ' + (String.isNotBlank(job.summary) ? job.summary : ''),
        'Validated'
      );
    } else if (
      job.isComplete == true
      && job.isFailed != true
      && ('DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c))
    ) {
      // Stamp US + session onto destination (int), then open the next pipeline hop.
      advancePipelineAfterDeployNext(sessionId, session, job);
    } else if (
      job.isComplete == true
      && job.isFailed != true
      && 'Deploy'.equalsIgnoreCase(session.Last_Job_Action__c)
      && String.isNotBlank(session.Last_Deploy_Job_Id__c)
    ) {
      // Persist live Layout fullNames discovered during deploy (layout-merge v4).
      try {
        StoryRef storyForRemap = resolveStoryRef(session);
        String pkg = session.Build_Package_Json__c;
        if (storyForRemap.recordId != null && String.isNotBlank(pkg)) {
          String synced = CopadoDevopsService.syncPackageLayoutsAfterDeploy(
            storyForRemap.recordId,
            pkg,
            session.Last_Deploy_Job_Id__c
          );
          if (String.isNotBlank(synced) && !synced.equals(pkg)) {
            session.Build_Package_Json__c = truncateForLongText(synced, 131072);
            update session;
            insertMessage(
              sessionId,
              'System',
              'Updated package layout names to match the live org (for Commit).',
              'Deployed'
            );
          }
        }
      } catch (Exception remapEx) {
        System.debug(
          LoggingLevel.WARN,
          'Deploy layout remap sync: ' + formatException(remapEx)
        );
      }
    }

    ActionResult result = new ActionResult();
    result.success = job.isFailed != true;
    result.message = String.isNotBlank(job.summary) ? job.summary : ('Job status: ' + job.status);
    result.session = getSessionState(sessionId);
    return result;
  }

  /**
   * After Deploy-to-next succeeds: bind US/session to destination env, clear promotion
   * job fields, set step back to Committed so Validate/Deploy labels target the next hop.
   */
  private static void advancePipelineAfterDeployNext(
    Id sessionId,
    AI_Builder_Session__c session,
    CopadoDevopsService.JobStatus job
  ) {
    Id destEnvId = null;
    if (String.isNotBlank(session.Last_Promotion_Id__c)) {
      try {
        destEnvId = CopadoDevopsService.getPromotionDestinationEnvironmentId(
          (Id) session.Last_Promotion_Id__c
        );
      } catch (Exception ignore) {
      }
    }
    // Fallback: next env from the source that was used for this hop.
    if (destEnvId == null && String.isNotBlank(session.Org_Credential_Id__c)) {
      try {
        Id sourceEnvId = CopadoDevopsService.resolveEnvironmentRecordId(
          session.Org_Credential_Id__c
        );
        Id projectId = null;
        StoryRef story = resolveStoryRef(session);
        if (story.recordId != null) {
          String projectIdStr = CopadoDevopsService.getProjectIdFromUserStory(story.recordId);
          if (String.isNotBlank(projectIdStr)) {
            projectId = (Id) projectIdStr;
          }
        }
        if (sourceEnvId != null) {
          destEnvId = CopadoDevopsService.resolveNextEnvironmentId(sourceEnvId, projectId);
        }
      } catch (Exception ignore) {
      }
    }

    String destName = destEnvId != null
      ? CopadoDevopsService.getEnvironmentName(destEnvId)
      : null;
    String advanceMsg =
      'Deploy to next environment succeeded. '
      + (String.isNotBlank(job.summary) ? job.summary : '');

    session = loadSession(sessionId);
    StoryRef storyRef = resolveStoryRef(session);
    Id storyId = storyRef.recordId;

    if (destEnvId != null) {
      String credForDest = CopadoDevopsService.resolveCredentialIdForEnvironment(destEnvId);
      // Non-production only — same guard as Deploy to Dev.
      CopadoAiApiService.OrgInfo safeOrg = null;
      if (String.isNotBlank(credForDest)) {
        safeOrg = CopadoDevopsService.findNonProductionOrg(credForDest);
      }
      if (safeOrg == null) {
        safeOrg = CopadoDevopsService.findNonProductionOrg(String.valueOf(destEnvId));
      }
      if (safeOrg != null || String.isNotBlank(destName)) {
        if (storyId != null) {
          try {
            CopadoDevopsService.assignEnvironmentToUserStory(
              storyId,
              String.valueOf(destEnvId)
            );
          } catch (Exception stampEx) {
            System.debug(
              LoggingLevel.WARN,
              'advancePipelineAfterDeployNext stamp US: ' + formatException(stampEx)
            );
          }
        }
        if (safeOrg != null) {
          session.Org_Credential_Id__c = String.isNotBlank(safeOrg.orgId)
            ? safeOrg.orgId
            : (String.isNotBlank(credForDest) ? credForDest : String.valueOf(destEnvId));
          session.Selected_Org__c = String.isNotBlank(safeOrg.orgName)
            ? safeOrg.orgName
            : destName;
        } else {
          // Destination known but not in Dev org list — still bind session to env/cred.
          session.Org_Credential_Id__c = String.isNotBlank(credForDest)
            ? credForDest
            : String.valueOf(destEnvId);
          session.Selected_Org__c = destName;
        }
      }
    }

    // Prefer Org Credential Id over Environment Id for Org Intelligence binds.
    if (String.isNotBlank(session.Org_Credential_Id__c)) {
      String normalizedCred = CopadoDevopsService.resolveOrgCredentialId(
        session.Org_Credential_Id__c
      );
      if (String.isNotBlank(normalizedCred)) {
        session.Org_Credential_Id__c = normalizedCred;
      }
    }

    // Reset hop so Next Env / Validate / Deploy target the following pipeline step.
    session.Current_Step__c = 'Committed';
    session.Status__c = 'Committed';
    session.Last_Promotion_Id__c = null;
    session.Last_Job_Id__c = null;
    session.Last_Job_Action__c = 'Commit';
    update session;

    // Re-bind Copado AI User Level (or session integration) to the new env.
    // Callout cannot run after DML here — LWC + @future handle it in fresh txns.
    String integrationId = session.Org_Intelligence_Integration_Id__c;
    String newCred = session.Org_Credential_Id__c;
    String newOrgName = session.Selected_Org__c;
    if (String.isNotBlank(integrationId) && String.isNotBlank(newCred)) {
      suggestOrgIntelligenceSync = true;
      try {
        CopadoAiApiService.syncIntegrationOrgCredentialFuture(
          integrationId,
          newCred,
          newOrgName
        );
      } catch (Exception syncEx) {
        System.debug(
          LoggingLevel.WARN,
          'advancePipeline OI future: ' + formatException(syncEx)
        );
      }
    }

    String nextLabel = null;
    try {
      Id sourceForNext = destEnvId;
      if (sourceForNext == null && String.isNotBlank(session.Org_Credential_Id__c)) {
        sourceForNext = CopadoDevopsService.resolveEnvironmentRecordId(
          session.Org_Credential_Id__c
        );
      }
      Id projectId = null;
      if (storyId != null) {
        String projectIdStr = CopadoDevopsService.getProjectIdFromUserStory(storyId);
        if (String.isNotBlank(projectIdStr)) {
          projectId = (Id) projectIdStr;
        }
      }
      if (sourceForNext != null) {
        Id nextId = CopadoDevopsService.resolveNextEnvironmentId(sourceForNext, projectId);
        if (nextId != null) {
          nextLabel = CopadoDevopsService.getEnvironmentName(nextId);
        }
      }
    } catch (Exception ignore) {
    }

    if (String.isNotBlank(destName)) {
      advanceMsg +=
        ' Story environment is now '
        + destName
        + '.';
    }
    if (String.isNotBlank(integrationId) && String.isNotBlank(newCred)) {
      String oiLabel = String.isNotBlank(newOrgName) ? newOrgName : destName;
      advanceMsg +=
        ' Org Intelligence is updating to '
        + oiLabel
        + ' (User Level). If Check deployment still sees the old org, click Reconnect Org Intelligence.';
    }
    if (String.isNotBlank(nextLabel)) {
      advanceMsg +=
        ' Next Env: '
        + nextLabel
        + ' — Validate / Deploy when ready.';
    } else if (String.isNotBlank(destName)) {
      advanceMsg += ' No further non-production Next Env on this pipeline.';
    }
    insertMessage(sessionId, 'System', advanceMsg, 'Committed');
  }

  /**
   * When Validate/Deploy-next is queued or Last_Job_Id was cleared, attach the latest
   * Job Execution on the session Promotion so Refresh can poll a real Id.
   */
  private static AI_Builder_Session__c resolveLastJobIdForRefresh(AI_Builder_Session__c session) {
    if (session == null) {
      return session;
    }
    Boolean needsAdopt =
      String.isBlank(session.Last_Job_Id__c)
      || isValidateQueuedJobId(session.Last_Job_Id__c)
      || isDeployNextQueuedJobId(session.Last_Job_Id__c)
      || (
        String.isNotBlank(session.Last_Job_Id__c)
        && session.Last_Job_Id__c.startsWith('create-execution-pending')
      );
    if (!needsAdopt || String.isBlank(session.Last_Promotion_Id__c)) {
      return session;
    }
    try {
      Id promoId = (Id) session.Last_Promotion_Id__c;
      Id adopted = CopadoDevopsService.findLatestJobExecutionForPromotion(
        promoId,
        Datetime.now().addMinutes(-60)
      );
      if (adopted == null) {
        return session;
      }
      session.Last_Job_Id__c = String.valueOf(adopted);
      if (
        'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      ) {
        session.Current_Step__c = 'DeployingNext';
      } else if (
        'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
        || String.isBlank(session.Current_Step__c)
      ) {
        session.Current_Step__c = 'Validating';
      }
      update session;
    } catch (Exception ignore) {
    }
    return session;
  }

  /**
   * After a successful Copado commit job that did not create a User Story Commit
   * related-list row, force-link Snapshot Commit + USC from Job Execution / SHA.
   */
  @AuraEnabled
  public static ActionResult linkUserStoryCommitFromLastJob(Id sessionId, String commitSha) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    if (String.isBlank(session.Last_Job_Id__c)) {
      return failure('No Copado job on this chat yet.');
    }
    String linkMsg;
    try {
      Id jobId = (Id) session.Last_Job_Id__c;
      if (String.isNotBlank(commitSha)) {
        CopadoDevopsService.persistCommitShaOnJob(jobId, commitSha.trim());
      }
      linkMsg = CopadoDevopsService.ensureUserStoryCommitFromJob(jobId);
    } catch (Exception ex) {
      return failure('USC link failed: ' + formatException(ex));
    }
    insertMessage(sessionId, 'System', linkMsg, session.Current_Step__c);
    ActionResult result = new ActionResult();
    result.success = linkMsg != null
      && (linkMsg.startsWith('Linked') || linkMsg.contains('already linked'));
    result.message = linkMsg;
    result.session = getSessionState(sessionId);
    return result;
  }

  @AuraEnabled
  public static ActionResult reviewCode(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    if (story.recordId == null && String.isBlank(story.name)) {
      return failure('Create a Copado user story before running: Review Code');
    }

    String packageJson = session.Build_Package_Json__c;
    String buildId = String.isNotBlank(session.Last_Build_Id__c) ? session.Last_Build_Id__c : 'latest-build';
    CopadoAiApiService.BuildResult review;
    try {
      review = CopadoAiApiService.reviewCode(
        session.Dialogue_Id__c,
        formatStoryRef(story),
        buildId,
        packageJson
      );
    } catch (Exception ex) {
      return failure('Review Code failed: ' + formatException(ex));
    }

    logAction(sessionId, 'Review Code', 'Success', buildId, JSON.serialize(review), null);
    session = loadSession(sessionId);
    session.Current_Step__c = 'Reviewed';
    session.Status__c = 'Reviewed';
    update session;
    insertMessage(sessionId, 'System', review.summary, 'Reviewed');

    ActionResult result = new ActionResult();
    result.success = true;
    result.message = review.summary;
    result.session = getSessionState(sessionId);
    return result;
  }

  @AuraEnabled
  public static ActionResult createTests(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    if (story.recordId == null && String.isBlank(story.name)) {
      return failure('Create a Copado user story before running: Create Tests');
    }

    String packageJson = session.Build_Package_Json__c;
    String buildId = String.isNotBlank(session.Last_Build_Id__c) ? session.Last_Build_Id__c : 'latest-build';
    CopadoAiApiService.TestResult tests;
    try {
      tests = CopadoAiApiService.createTests(
        session.Dialogue_Id__c,
        formatStoryRef(story),
        buildId,
        packageJson
      );
    } catch (Exception ex) {
      return failure('Create Tests failed: ' + formatException(ex));
    }

    logAction(sessionId, 'Create Tests', 'Success', buildId, JSON.serialize(tests), null);
    session = loadSession(sessionId);
    session.Current_Step__c = 'Tests Created';
    session.Status__c = 'Tests Created';
    update session;
    insertMessage(sessionId, 'System', tests.summary, 'Tests Created');

    ActionResult result = new ActionResult();
    result.success = true;
    result.message = tests.summary;
    result.session = getSessionState(sessionId);
    return result;
  }

  @AuraEnabled
  public static ActionResult deployToDev(
    Id sessionId,
    String orgId,
    Boolean confirmed,
    Boolean rememberPreference
  ) {
    validateSessionId(sessionId);

    if (confirmed != true) {
      return failure('Deployment requires explicit confirmation.');
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    Id deployStoryId = story.recordId;
    if (deployStoryId == null && CopadoAiApiService.isMockMode()) {
      deployStoryId = sessionId;
    }
    if (deployStoryId == null) {
      return failure('A Copado user story with a Salesforce Id is required before deploying.');
    }

    if (String.isBlank(orgId)) {
      return failure(
        'Select a Dev environment in the Status panel. '
        + 'Copado Builder will add that environment/credential to the user story before deploy.'
      );
    }

    CopadoAiApiService.OrgInfo targetOrg = findSafeDevOrg(orgId);
    if (targetOrg == null) {
      return failure('Only non-production Dev environments are allowed. Production is never permitted.');
    }

    String packageJson = session.Build_Package_Json__c;
    if (String.isBlank(packageJson)) {
      return failure('No build package on this chat yet. Run Build first so there is metadata to deploy.');
    }

    String projectId = CopadoDevopsService.getProjectIdFromUserStory(deployStoryId);

    CopadoDevopsService.JobResult deploy;
    try {
      deploy = CopadoDevopsService.deployPackageToDev(
        deployStoryId,
        packageJson,
        'Copado Builder deploy for ' + formatStoryRef(story),
        null,
        targetOrg.orgId,
        String.isNotBlank(session.Artifact_Content_Document_Id__c)
          ? (Id) session.Artifact_Content_Document_Id__c
          : null
      );
    } catch (Exception ex) {
      return failure('Deployment failed: ' + formatException(ex));
    }

    if (rememberPreference == true) {
      try {
        CopadoDevopsService.saveUserPreference(targetOrg.orgId, projectId);
      } catch (Exception ignore) {
      }
    }

    logAction(
      sessionId,
      'Deploy',
      'Success',
      JSON.serialize(new Map<String, String>{
        'storyId' => String.valueOf(story.recordId),
        'orgId' => targetOrg.orgId,
        'orgName' => targetOrg.orgName
      }),
      JSON.serialize(deploy),
      null
    );

    session = loadSession(sessionId);
    session.Selected_Org__c = targetOrg.orgName;
    session.Org_Credential_Id__c = targetOrg.orgId;
    session.Last_Job_Id__c = deploy.jobId;
    session.Last_Deploy_Job_Id__c = deploy.jobId;
    session.Last_Job_Action__c = 'Deploy';
    session.Status__c = 'Deployed';
    session.Current_Step__c = 'Deployed';
    update session;

    insertMessage(sessionId, 'System', deploy.summary, 'Deployed');

    ActionResult result = new ActionResult();
    result.success = true;
    result.message = deploy.summary;
    // Avoid heavy getSessionState here — Copado JE start already used many SOQLs;
    // a LimitException becomes a Salesforce "Internal server error" toast and
    // rolls back Last_Job_Id so the Refresh button never appears.
    result.session = safeSessionAfterAction(sessionId, true);
    return result;
  }

  /** Apex/test overload — recreateFeatureBranch defaults to false. */
  public static ActionResult commitFromDev(
    Id sessionId,
    String environmentId,
    Boolean rememberPreference
  ) {
    return commitFromDev(sessionId, environmentId, rememberPreference, false);
  }

  /**
   * Commit already-deployed package metadata from the selected Dev org into the
   * user story feature branch. Requires a successful Deploy first.
   * @param recreateFeatureBranch when true, Copado deletes + recreates the feature
   *   branch from base then commits (copado.CommitAction.recreateFeatureBranch).
   */
  @AuraEnabled
  public static ActionResult commitFromDev(
    Id sessionId,
    String environmentId,
    Boolean rememberPreference,
    Boolean recreateFeatureBranch
  ) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    Id storyId = story.recordId;
    if (storyId == null && CopadoAiApiService.isMockMode()) {
      storyId = sessionId;
    }
    if (storyId == null) {
      return failure('Link a Copado user story before committing.');
    }
    if (String.isBlank(environmentId)) {
      return failure(
        'Select a Dev environment in the Status panel before committing. '
          + 'Commit retrieves metadata from that org into the story feature branch.'
      );
    }
    CopadoAiApiService.OrgInfo targetOrg = findSafeDevOrg(environmentId);
    if (targetOrg == null) {
      return failure('Only non-production Dev environments are allowed. Production is never permitted.');
    }
    if (String.isBlank(session.Last_Deploy_Job_Id__c)
      || !CopadoDevopsService.isJobExecutionSuccessful(session.Last_Deploy_Job_Id__c)) {
      return failure(
        'Deploy to Dev must succeed before Commit. Run Deploy and wait for the job to complete.'
      );
    }
    String packageJson = session.Build_Package_Json__c;
    if (String.isBlank(packageJson)) {
      return failure(
        'No build package on this chat yet. Run Build Code first so there is metadata to commit.'
      );
    }

    // Deploy Function remaps invented layout names (Account-Account Layout → live
    // Formato…). Rewrite package + USM before Commit retrieve.
    try {
      String synced = CopadoDevopsService.syncPackageLayoutsAfterDeploy(
        storyId,
        packageJson,
        session.Last_Deploy_Job_Id__c
      );
      if (String.isNotBlank(synced) && !synced.equals(packageJson)) {
        packageJson = synced;
        session.Build_Package_Json__c = truncateForLongText(synced, 131072);
        update session;
      }
    } catch (Exception remapEx) {
      System.debug(
        LoggingLevel.WARN,
        'syncPackageLayoutsAfterDeploy: ' + formatException(remapEx)
      );
    }

    String projectId = CopadoDevopsService.getProjectIdFromUserStory(storyId);
    String commitMsg = recreateFeatureBranch == true
      ? ('Copado Builder recreate-branch commit from '
        + targetOrg.orgName
        + ' for '
        + formatStoryRef(story))
      : ('Copado Builder commit from '
        + targetOrg.orgName
        + ' for '
        + formatStoryRef(story));
    CopadoDevopsService.JobResult commitJob;
    try {
      commitJob = CopadoDevopsService.commitPackageFromDev(
        storyId,
        packageJson,
        commitMsg,
        null,
        targetOrg.orgId,
        String.isNotBlank(session.Artifact_Content_Document_Id__c)
          ? (Id) session.Artifact_Content_Document_Id__c
          : null,
        recreateFeatureBranch == true
      );
    } catch (Exception ex) {
      return failure('Commit failed: ' + formatException(ex));
    }

    if (rememberPreference == true) {
      try {
        CopadoDevopsService.saveUserPreference(targetOrg.orgId, projectId);
      } catch (Exception ignore) {
      }
    }

    session = loadSession(sessionId);
    session.Selected_Org__c = targetOrg.orgName;
    session.Org_Credential_Id__c = targetOrg.orgId;
    session.Last_Job_Id__c = commitJob.jobId;
    session.Last_Commit_Job_Id__c = commitJob.jobId;
    session.Last_Job_Action__c = 'Commit';
    session.Status__c = 'Committed';
    session.Current_Step__c = 'Committed';
    update session;

    insertMessage(sessionId, 'System', commitJob.summary, 'Committed');

    // Custom Job Templates finish Git without creating User Story Commit rows.
    // Schedule a delayed link once the JE should be complete (~2.5 min).
    try {
      Id jobExecutionId = (Id) commitJob.jobId;
      CopadoDevopsService.scheduleUserStoryCommitLink(jobExecutionId, storyId, sessionId);
    } catch (Exception ignore) {
    }

    // Audit last — never roll back the job/session if picklist logging fails.
    logAction(
      sessionId,
      'Commit',
      'Success',
      JSON.serialize(new Map<String, Object>{
        'storyId' => String.valueOf(story.recordId),
        'orgId' => targetOrg.orgId,
        'orgName' => targetOrg.orgName,
        'recreateFeatureBranch' => recreateFeatureBranch == true
      }),
      JSON.serialize(commitJob),
      null
    );

    ActionResult result = new ActionResult();
    result.success = true;
    result.message = commitJob.summary;
    result.session = safeSessionAfterAction(sessionId, true);
    return result;
  }

  /**
   * Validate (dry-run) committed changes to the next pipeline environment.
   */
  @AuraEnabled
  public static ActionResult validateToNextEnvironment(Id sessionId, Boolean confirmed) {
    validateSessionId(sessionId);
    if (confirmed != true) {
      return failure('Validate requires explicit confirmation.');
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    Id storyId = story.recordId;
    if (storyId == null && CopadoAiApiService.isMockMode()) {
      storyId = sessionId;
    }
    if (storyId == null) {
      return failure('Link a Copado user story before validating.');
    }

    Boolean commitOk = false;
    if ('Committed'.equalsIgnoreCase(session.Current_Step__c)
      || 'Validated'.equalsIgnoreCase(session.Current_Step__c)) {
      commitOk = String.isNotBlank(session.Last_Commit_Job_Id__c);
    } else if (String.isNotBlank(session.Last_Commit_Job_Id__c)
      && CopadoDevopsService.isJobExecutionSuccessful(session.Last_Commit_Job_Id__c)) {
      commitOk = true;
    } else if (
      CopadoAiApiService.isMockMode()
      && 'Committed'.equalsIgnoreCase(session.Current_Step__c)
    ) {
      commitOk = true;
    }
    if (!commitOk) {
      return failure(
        'Commit must succeed before Validate. Run Commit and wait for the job to complete.'
      );
    }

    String sourceEnv = session.Org_Credential_Id__c;
    if (String.isBlank(sourceEnv)) {
      sourceEnv = CopadoDevopsService.getUserStoryEnvironmentId(storyId);
    }
    if (String.isBlank(sourceEnv)) {
      return failure('Select a Dev environment before validating to the next environment.');
    }

    // Keep prior Last_Promotion until the new one is stamped inside validate —
    // clearing here then hitting SOQL 101 left the session with a null parent.
    CopadoDevopsService.JobResult validateJob;
    try {
      validateJob = CopadoDevopsService.validateUserStoryToNextEnvironment(
        storyId,
        sourceEnv,
        sessionId
      );
    } catch (System.LimitException limEx) {
      ActionResult fail = failure(
        'Validate hit Salesforce SOQL limits while preparing. '
          + 'Wait a few seconds and click Validate again — the job runs async after prepare.'
      );
      try {
        fail.session = getSessionState(sessionId);
      } catch (Exception ignore) {
      }
      return fail;
    } catch (Exception ex) {
      String msg = formatException(ex);
      ActionResult fail = failure('Validate failed: ' + msg);
      // Avoid a second SOQL blow-up when the transaction is already over limit.
      if (msg == null || !msg.contains('Too many SOQL')) {
        try {
          fail.session = getSessionState(sessionId);
        } catch (Exception ignore) {
        }
      }
      return fail;
    }

    Boolean jobsStarted =
      validateJob != null
      && String.isNotBlank(validateJob.jobId)
      && !'Prepared'.equalsIgnoreCase(validateJob.status)
      && !'Failed'.equalsIgnoreCase(validateJob.status)
      && !validateJob.jobId.startsWith('validate-manual')
      && !validateJob.jobId.startsWith('create-execution-pending');

    session = loadSession(sessionId);
    session.Last_Job_Action__c = 'Validate';
    if (String.isNotBlank(validateJob.promotionId)) {
      session.Last_Promotion_Id__c = validateJob.promotionId;
    }
    if (jobsStarted) {
      session.Last_Job_Id__c = validateJob.jobId;
      // Not "Validated" until the dry-run Job Execution completes successfully.
      // validate-queued means CreateExecution runs async in CopadoValidateQueueable.
      session.Current_Step__c = 'Validating';
    } else {
      // Failed to start — do not leave a prior Validated step unlocking Deploy to next.
      session.Last_Job_Id__c = null;
      if ('Validated'.equalsIgnoreCase(session.Current_Step__c)
        || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
        || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c)) {
        session.Current_Step__c = 'Committed';
      }
    }
    update session;

    insertMessage(
      sessionId,
      'System',
      validateJob.summary,
      jobsStarted ? 'Validating' : 'Validate'
    );

    logAction(
      sessionId,
      'Validate',
      jobsStarted ? 'Success' : 'Failed',
      JSON.serialize(new Map<String, String>{
        'storyId' => String.valueOf(story.recordId),
        'promotionId' => validateJob.promotionId,
        'jobId' => validateJob.jobId,
        'errorDetail' => validateJob.errorDetail
      }),
      JSON.serialize(validateJob),
      null
    );

    ActionResult result = new ActionResult();
    result.success = jobsStarted;
    result.message = validateJob.summary;
    // Avoid SOQL 101 on the post-Validate session refresh when Copado burned the budget.
    try {
      if (Limits.getQueries() < 90) {
        result.session = getSessionState(sessionId);
      } else {
        result.session = getSessionStateLite(sessionId);
      }
    } catch (Exception stateEx) {
      if (stateEx.getMessage() != null && stateEx.getMessage().contains('Too many SOQL')) {
        result.session = getSessionStateLite(sessionId);
      } else {
        throw stateEx;
      }
    }
    return result;
  }

  /**
   * Real (non–dry-run) deploy of validated changes to the next pipeline environment.
   */
  @AuraEnabled
  public static ActionResult deployToNextEnvironment(Id sessionId, Boolean confirmed) {
    validateSessionId(sessionId);
    if (confirmed != true) {
      return failure('Deploy to next environment requires explicit confirmation.');
    }

    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    Id storyId = story.recordId;
    if (storyId == null && CopadoAiApiService.isMockMode()) {
      storyId = sessionId;
    }
    if (storyId == null) {
      return failure('Link a Copado user story before deploying to the next environment.');
    }

    Boolean validateOk =
      'Validated'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c);
    if (!validateOk && CopadoAiApiService.isMockMode()) {
      validateOk = 'Validated'.equalsIgnoreCase(session.Current_Step__c)
        || 'Committed'.equalsIgnoreCase(session.Current_Step__c);
    }
    if (!validateOk) {
      return failure(
        'Validate must succeed before Deploy to next environment. '
          + 'Run Validate and wait until Validate Status is Successful.'
      );
    }

    String sourceEnv = session.Org_Credential_Id__c;
    if (String.isBlank(sourceEnv)) {
      sourceEnv = CopadoDevopsService.getUserStoryEnvironmentId(storyId);
    }
    if (String.isBlank(sourceEnv)) {
      return failure('Select a Dev environment before deploying to the next environment.');
    }

    Id existingPromotionId = null;
    if (String.isNotBlank(session.Last_Promotion_Id__c)) {
      try {
        existingPromotionId = (Id) session.Last_Promotion_Id__c;
      } catch (Exception ignore) {
      }
    }

    CopadoDevopsService.JobResult deployJob;
    try {
      deployJob = CopadoDevopsService.deployUserStoryToNextEnvironment(
        storyId,
        sourceEnv,
        sessionId,
        existingPromotionId
      );
    } catch (Exception ex) {
      return failure('Deploy to next environment failed: ' + formatException(ex));
    }

    Boolean jobsStarted =
      deployJob != null
      && String.isNotBlank(deployJob.jobId)
      && !'Prepared'.equalsIgnoreCase(deployJob.status)
      && !'Failed'.equalsIgnoreCase(deployJob.status)
      && !deployJob.jobId.startsWith('validate-manual')
      && !deployJob.jobId.startsWith('create-execution-pending');

    session = loadSession(sessionId);
    session.Last_Job_Action__c = 'DeployNext';
    if (String.isNotBlank(deployJob.promotionId)) {
      session.Last_Promotion_Id__c = deployJob.promotionId;
    }
    if (jobsStarted) {
      session.Last_Job_Id__c = deployJob.jobId;
      session.Current_Step__c = 'DeployingNext';
    }
    update session;

    insertMessage(
      sessionId,
      'System',
      deployJob.summary,
      jobsStarted ? 'DeployingNext' : 'DeployNext'
    );

    logAction(
      sessionId,
      'DeployNext',
      jobsStarted ? 'Success' : 'Failed',
      JSON.serialize(new Map<String, String>{
        'storyId' => String.valueOf(story.recordId),
        'promotionId' => deployJob.promotionId,
        'jobId' => deployJob.jobId,
        'errorDetail' => deployJob.errorDetail
      }),
      JSON.serialize(deployJob),
      null
    );

    ActionResult result = new ActionResult();
    result.success = jobsStarted;
    result.message = deployJob.summary;
    try {
      if (Limits.getQueries() < 90) {
        result.session = getSessionState(sessionId);
      } else {
        result.session = getSessionStateLite(sessionId);
      }
    } catch (Exception stateEx) {
      if (stateEx.getMessage() != null && stateEx.getMessage().contains('Too many SOQL')) {
        result.session = getSessionStateLite(sessionId);
      } else {
        throw stateEx;
      }
    }
    return result;
  }

  /**
   * Ask Build Agent (+ Org Intelligence when connected) to verify story artifacts
   * exist in the current User Story / session environment (post-promote = int).
   */
  @AuraEnabled
  public static ActionResult checkDeployment(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    if (story.recordId == null && String.isBlank(session.Copado_User_Story__c)) {
      return failure('Link a Copado user story before checking deployment.');
    }
    List<String> artifacts = extractArtifactPaths(session.Build_Package_Json__c);
    if (artifacts == null || artifacts.isEmpty()) {
      return failure('No Build artifacts on this chat. Run Build first.');
    }
    String orgCredRaw = session.Org_Credential_Id__c;
    if (String.isBlank(orgCredRaw) && story.recordId != null) {
      orgCredRaw = CopadoDevopsService.getUserStoryEnvironmentId(story.recordId);
    }
    if (String.isBlank(orgCredRaw)) {
      return failure(
        'No environment on this chat or user story. Complete Deploy to next, or connect Org Context.'
      );
    }
    // Always bind with Org Credential Id (never Environment name like "int").
    String orgCred = CopadoDevopsService.resolveOrgCredentialId(orgCredRaw);
    if (String.isBlank(orgCred)) {
      orgCred = orgCredRaw;
    }
    String orgLabel = String.isNotBlank(session.Selected_Org__c)
      ? session.Selected_Org__c
      : orgCred;
    CopadoAiApiService.OrgInfo orgInfo = CopadoDevopsService.findOrgCredentialById(orgCred);
    if (orgInfo != null && String.isNotBlank(orgInfo.orgName)) {
      orgLabel = orgInfo.orgName;
    }
    String storyLabel = formatStoryRef(story);
    String integrationId = session.Org_Intelligence_Integration_Id__c;
    String workspaceId = session.Workspace_Id__c;
    String dialogueId = session.Dialogue_Id__c;

    Boolean boundOk = false;
    String selectedAfter = null;
    String assistantReply;
    Boolean pendingAi = false;
    String pendingRequestId = null;
    Integer pendingBaselineCount = null;
    String pendingBaselineText = null;

    // Callouts first — re-bind User Level, then ask Build Agent.
    try {
      if (String.isBlank(workspaceId) && !CopadoAiApiService.isMockMode()) {
        CopadoAiApiService.WorkspaceResult workspace =
          CopadoAiApiService.ensureBuilderWorkspace();
        if (workspace != null && String.isNotBlank(workspace.workspaceId)) {
          workspaceId = workspace.workspaceId;
        }
      }
      if (String.isNotBlank(integrationId) && !CopadoAiApiService.isMockMode()) {
        boundOk = CopadoAiApiService.syncIntegrationOrgCredential(
          integrationId,
          orgCred,
          orgLabel
        );
        selectedAfter = CopadoAiApiService.getIntegrationSelectedCredentialId(integrationId);
        Boolean selectedMatches =
          String.isBlank(selectedAfter)
          || orgCred.equals(selectedAfter)
          || (String.isNotBlank(orgLabel) && orgLabel.equalsIgnoreCase(selectedAfter));
        if (boundOk != true || selectedMatches != true) {
          return failure(
            'Org Intelligence is not bound to '
              + orgLabel
              + ' (credential '
              + orgCred
              + ').'
              + (String.isNotBlank(selectedAfter)
                ? ' Currently selected: ' + selectedAfter + '.'
                : '')
              + ' Set Org Context to '
              + orgLabel
              + ', click Update OI, then Check deployment again.'
          );
        }
      } else if (String.isBlank(integrationId) && !CopadoAiApiService.isMockMode()) {
        return failure(
          'No Org Intelligence integration on this chat. Set Org Context to '
            + orgLabel
            + ', click Update OI, then Check deployment again.'
        );
      }
      if (String.isBlank(dialogueId) && String.isNotBlank(workspaceId)
        && !CopadoAiApiService.isMockMode()) {
        CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
          workspaceId,
          'Check deploy ' + storyLabel
        );
        if (created != null && String.isNotBlank(created.dialogueId)) {
          dialogueId = created.dialogueId;
        }
      }

      String bindNote =
        'Builder re-bound User Level to credential Id '
        + orgCred
        + ' ("'
        + orgLabel
        + '").'
        + (String.isNotBlank(selectedAfter)
          ? ' Configure selected Id=' + selectedAfter + '.'
          : '');

      String prompt =
        'Check deployment for '
        + storyLabel
        + '.\n\n'
        + 'Do not reference past validation, earlier chat replies, or prior FOUND/MISSING answers.\n'
        + 'When asked to validate metadata, look at the User Level integration as it is right now.\n\n'
        + 'STEP 1 — Org identity (required first):\n'
        + '- Inspect the User Level / Copado CI/CD integration that is active on this chat *right now*.\n'
        + '- Report which Salesforce org you are connected to (my.salesforce.com host and/or '
        + 'credential name from that live integration read).\n'
        + '- Do not guess from Builder Org Context labels, environment names, or chat history.\n'
        + '- Expected session org for this check: credential Id '
        + orgCred
        + ' (label "'
        + orgLabel
        + '"). '
        + 'If live User Level does not match that credential, say so and stop — do not invent FOUND.\n\n'
        + bindNote
        + '\n\n'
        + 'STEP 2 — Artifacts (only after Step 1 from live tools):\n- '
        + String.join(artifacts, '\n- ')
        + '\n\n'
        + 'Reply in plain language:\n'
        + '1) First line: which org User Level is connected to right now.\n'
        + '2) For each artifact: FOUND or MISSING.\n'
        + '3) One verdict: Ready / Gaps found / Unable to confirm.\n'
        + 'Do not return package JSON or full XML.';

      CopadoAiApiService.DialogueResult dialogue = CopadoAiApiService.sendDialogueMessage(
        dialogueId,
        prompt,
        null,
        CopadoAiApiService.ASSISTANT_BUILD,
        workspaceId,
        null
      );
      if (dialogue != null && String.isNotBlank(dialogue.dialogueId)) {
        dialogueId = dialogue.dialogueId;
      }
      assistantReply = dialogue != null ? dialogue.message : null;
      if (dialogue != null && dialogue.pending == true) {
        pendingAi = true;
        pendingRequestId = dialogue.requestId;
        pendingBaselineCount = dialogue.baselineMessageCount;
        pendingBaselineText = dialogue.baselineAssistantText;
      }
    } catch (Exception ex) {
      return failure('Check deployment failed: ' + formatException(ex));
    }

    session = loadSession(sessionId);
    if (String.isNotBlank(workspaceId)) {
      session.Workspace_Id__c = workspaceId;
    }
    if (String.isNotBlank(dialogueId)) {
      session.Dialogue_Id__c = dialogueId;
    }
    // Keep session org on the resolved credential Id used for bind.
    session.Org_Credential_Id__c = orgCred;
    session.Selected_Org__c = orgLabel;
    update session;

    String userLine =
      'Check deployment for '
      + storyLabel
      + ' (expect '
      + orgLabel
      + ' / '
      + orgCred
      + ').';
    if (boundOk != true) {
      userLine += ' Bind was not verified — confirm User Level points at this credential.';
    }
    insertMessage(sessionId, 'User', userLine, session.Current_Step__c);

    ActionResult result = new ActionResult();
    if (pendingAi == true) {
      result.success = true;
      result.message = 'Waiting for Build Agent to verify metadata in ' + orgLabel + '…';
      result.session = getSessionState(sessionId);
      result.session.awaitingAiReply = true;
      result.session.aiRequestId = pendingRequestId;
      result.session.dialogueId = dialogueId;
      result.session.workspaceId = workspaceId;
      result.session.aiBaselineMessageCount = pendingBaselineCount;
      result.session.aiBaselineAssistantText = pendingBaselineText;
      return result;
    }

    String displayReply = CopadoAiApiService.summarizeForChatDisplay(
      String.isNotBlank(assistantReply)
        ? assistantReply
        : 'No reply from Copado AI. Try Check deployment again.'
    );
    insertMessage(
      sessionId,
      'Assistant',
      '_Build Agent_\n\n' + displayReply,
      session.Current_Step__c
    );
    result.success = true;
    result.message = boundOk
      ? ('Deployment check complete for ' + orgLabel + '.')
      : ('Deployment check ran, but User Level bind to '
        + orgLabel
        + ' was not verified. Click Reconnect Org Intelligence, then Check again.');
    result.session = getSessionState(sessionId);
    return result;
  }

  public class EnvironmentOptions {
    @AuraEnabled public List<CopadoAiApiService.OrgInfo> orgs;
    @AuraEnabled public String preferredEnvironmentId;
    @AuraEnabled public String storyEnvironmentId;
    @AuraEnabled public String projectId;
    @AuraEnabled public String preferredProjectId;
    @AuraEnabled public String helpText;
  }

  public class ProjectOptions {
    @AuraEnabled public List<CopadoDevopsService.ProjectInfo> projects;
    @AuraEnabled public String preferredProjectId;
    @AuraEnabled public String storyProjectId;
    @AuraEnabled public String helpText;
  }

  public class UserSetupDefaults {
    @AuraEnabled public String preferredProjectId;
    @AuraEnabled public String preferredIntegrationId;
    @AuraEnabled public Boolean needsSetup;
    /** True when the running user has a stored Copado AI PAT (secret never returned). */
    @AuraEnabled public Boolean hasPat;
    /** Masked PAT hint, e.g. ••••ab12 — never the full token. */
    @AuraEnabled public String patMask;
  }

  @AuraEnabled
  public static ProjectOptions listCopadoProjects(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);

    ProjectOptions result = new ProjectOptions();
    result.projects = CopadoDevopsService.listProjects();
    result.preferredProjectId = CopadoDevopsService.getPreferredProjectId();
    result.storyProjectId = story.recordId != null
      ? CopadoDevopsService.getProjectIdFromUserStory(story.recordId)
      : null;
    result.helpText =
      'Choose the Copado Project whose pipeline contains your Dev environment. '
      + 'User stories are created in this project.';
    return result;
  }

  @AuraEnabled
  public static void savePreferredProject(String projectId) {
    CopadoDevopsService.savePreferredProject(projectId);
  }

  /** Remember the user's default Dev Org Credential for Org Context prefill. */
  @AuraEnabled
  public static void savePreferredEnvironment(String environmentId, String projectId) {
    CopadoDevopsService.saveUserPreference(environmentId, projectId);
  }

  @AuraEnabled
  public static void savePreferredIntegration(String integrationId) {
    CopadoDevopsService.savePreferredIntegration(integrationId);
  }

  @AuraEnabled
  public static UserSetupDefaults getUserSetupDefaults() {
    UserSetupDefaults defaults = new UserSetupDefaults();
    defaults.preferredProjectId = CopadoDevopsService.getPreferredProjectId();
    defaults.preferredIntegrationId = CopadoDevopsService.getPreferredIntegrationId();
    defaults.hasPat = CopadoAiApiService.hasUserCopadoAiPat();
    defaults.patMask = CopadoAiApiService.getUserCopadoAiPatMask();
    Boolean missingPrefs =
      String.isBlank(defaults.preferredProjectId)
      || String.isBlank(defaults.preferredIntegrationId);
    // PAT is required for Copado AI callouts; Project/Integration can be bypassed.
    Boolean missingPat = defaults.hasPat != true;
    defaults.needsSetup =
      missingPat
      || (missingPrefs && !CopadoDevopsService.isUserSetupBypassed());
    return defaults;
  }

  @AuraEnabled
  public static void saveUserSetupDefaults(
    String projectId,
    String integrationId,
    String copadoAiPat
  ) {
    if (String.isNotBlank(copadoAiPat)) {
      CopadoAiApiService.saveUserCopadoAiPat(copadoAiPat);
    } else if (!CopadoAiApiService.hasUserCopadoAiPat()) {
      throw new AuraHandledException(
        'Copado AI Personal Access Token is required. '
          + 'Create one in the Copado AI Platform for your own account.'
      );
    }
    if (String.isNotBlank(projectId) && String.isNotBlank(integrationId)) {
      CopadoDevopsService.saveUserSetupDefaults(projectId, integrationId);
    }
  }

  /**
   * Update only the running user's Copado AI PAT (Settings / reconnect path).
   */
  @AuraEnabled
  public static String saveUserCopadoAiPat(String copadoAiPat) {
    try {
      CopadoAiApiService.saveUserCopadoAiPat(copadoAiPat);
      return CopadoAiApiService.getUserCopadoAiPatMask();
    } catch (CopadoAiApiService.ApiException apiEx) {
      throw new AuraHandledException(apiEx.getMessage());
    }
  }

  @AuraEnabled
  public static void bypassUserSetup() {
    // PAT cannot be bypassed — Copado AI callouts require the user's own token.
    if (!CopadoAiApiService.hasUserCopadoAiPat()) {
      throw new AuraHandledException(
        'Add your Copado AI Personal Access Token before bypassing. '
          + 'Project and Integration can be set later; the token cannot.'
      );
    }
    CopadoDevopsService.saveUserSetupBypass();
  }

  @AuraEnabled
  public static EnvironmentOptions listSafeDevOrgs(Id sessionId, String projectId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);

    String resolvedProjectId = projectId;
    if (story.recordId != null) {
      String storyProject = CopadoDevopsService.getProjectIdFromUserStory(story.recordId);
      if (String.isNotBlank(storyProject)) {
        resolvedProjectId = storyProject;
      }
    }
    if (String.isBlank(resolvedProjectId)) {
      resolvedProjectId = CopadoDevopsService.getPreferredProjectId();
    }

    // Temporary: Org Context / OI picker shows only credentials this user owns
    // or created (Copado AI credentials are per-user and cannot be shared).
    List<CopadoAiApiService.OrgInfo> allOrgs = CopadoDevopsService.listPipelineOrgs(
      resolvedProjectId,
      true
    );
    List<CopadoAiApiService.OrgInfo> safeOrgs = new List<CopadoAiApiService.OrgInfo>();
    Set<String> seen = new Set<String>();
    for (CopadoAiApiService.OrgInfo org : allOrgs) {
      if (org.isProduction == true) {
        continue;
      }
      safeOrgs.add(org);
      seen.add(org.orgId);
    }

    String storyEnvRaw = story.recordId != null
      ? CopadoDevopsService.getUserStoryEnvironmentRawId(story.recordId)
      : null;
    String storyEnv = CopadoDevopsService.resolveOrgCredentialId(storyEnvRaw);
    // Include the story's Dev org only when this user owns/created that credential.
    if (
      String.isNotBlank(storyEnv)
      && !seen.contains(storyEnv)
      && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(storyEnv)
    ) {
      CopadoAiApiService.OrgInfo storyOrg = CopadoDevopsService.findOrgCredentialById(storyEnv);
      if (storyOrg != null && storyOrg.isProduction != true) {
        safeOrgs.add(storyOrg);
        seen.add(storyOrg.orgId);
      }
    }
    if (!safeOrgs.isEmpty()) {
      safeOrgs.sort();
    }

    String preferred = CopadoDevopsService.getPreferredEnvironmentId(resolvedProjectId);
    if (String.isNotBlank(storyEnv) && seen.contains(storyEnv)) {
      preferred = storyEnv;
    } else if (String.isNotBlank(preferred) && !seen.contains(preferred)) {
      preferred = null;
    }

    EnvironmentOptions result = new EnvironmentOptions();
    result.orgs = safeOrgs;
    result.projectId = resolvedProjectId;
    result.preferredProjectId = CopadoDevopsService.getPreferredProjectId();
    result.storyEnvironmentId = (String.isNotBlank(storyEnv) && seen.contains(storyEnv))
      ? storyEnv
      : null;
    result.preferredEnvironmentId = preferred;
    if (safeOrgs.isEmpty()) {
      result.helpText =
        'No Org Credentials you own yet. In Copado, create/validate your own Dev Org Credential '
        + '(and Connect it in Copado AI). Shared/default credentials from other users do not appear here.';
    } else if (String.isNotBlank(storyEnv) && seen.contains(storyEnv)) {
      result.helpText = 'Your Dev Org Credential from the linked user story is pre-selected.';
    } else if (String.isNotBlank(storyEnvRaw) && !seen.contains(storyEnv)) {
      result.helpText =
        'This story\'s Dev environment uses a credential you do not own. '
        + 'Select one of your own validated Org Credentials below, then click Update OI.';
    } else if (String.isBlank(storyEnvRaw) && story.recordId != null) {
      result.helpText =
        'Select one of your Dev Org Credentials, then click Update OI. '
        + 'Builder will set it on the story when you deploy.';
    } else if (String.isNotBlank(resolvedProjectId)) {
      result.helpText =
        'Your validated Dev Org Credentials for this project (owned/created by you).';
    } else {
      result.helpText =
        'Pick a Copado Project, then select a Dev Org Credential you own.';
    }
    return result;
  }

  /**
   * Improve Story: structure chat into Copado US fields via AI, then:
   * - If a User Story is linked → update that record with the mapped fields
   * - If not linked → polish the session draft / tips (Create Story still creates the US)
   */
  @AuraEnabled
  public static ActionResult improveStory(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Action__c action;
    try {
      AI_Builder_Session__c session = loadSession(sessionId);
      StoryRef linked = resolveStoryRef(session);
      StoryScore score = scoreStory(sessionId);
      ChatCoverage coverage = assessChatCoverage(sessionId);

      // Callouts before any DML
      Map<String, Object> storyData = buildStoryData(sessionId);
      Boolean hasLinkedStory = linked.recordId != null
        || (CopadoAiApiService.isMockMode() && String.isNotBlank(session.Copado_User_Story__c));

      String workspaceId = session.Workspace_Id__c;
      String dialogueId = session.Dialogue_Id__c;
      if (hasLinkedStory && !CopadoAiApiService.isMockMode()) {
        try {
          if (String.isBlank(workspaceId) || String.isBlank(dialogueId)) {
            CopadoAiApiService.WorkspaceResult workspace =
              CopadoAiApiService.ensureBuilderWorkspace();
            if (workspace != null && String.isNotBlank(workspace.workspaceId)) {
              workspaceId = workspace.workspaceId;
            }
          }
          if (String.isBlank(dialogueId) && String.isNotBlank(workspaceId)) {
            CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
              workspaceId,
              'Improve ' + formatStoryRef(linked)
            );
            if (created != null && String.isNotBlank(created.dialogueId)) {
              dialogueId = created.dialogueId;
            }
          }
          String seed = formatStoryDataForChat(storyData);
          if (String.isBlank(seed) && String.isNotBlank(session.Summary__c)) {
            seed = session.Summary__c;
          }
          if (String.isNotBlank(dialogueId) && String.isNotBlank(seed)) {
            CopadoAiApiService.sendDialogueMessage(
              dialogueId,
              'Improve this Copado user story using our conversation. '
                + 'Current draft:\n\n'
                + seed,
              null,
              null,
              workspaceId
            );
          }
        } catch (Exception seedEx) {
          System.debug(
            LoggingLevel.WARN,
            'improveStory dialogue seed: ' + formatException(seedEx)
          );
        }
      }

      try {
        storyData = CopadoAiApiService.enrichStoryDataWithAi(
          dialogueId,
          storyData,
          true
        );
      } catch (Exception enrichEx) {
        storyData.put('enrichError', formatException(enrichEx));
      }

      if (hasLinkedStory) {
        if (linked.recordId == null && !CopadoAiApiService.isMockMode()) {
          return failure(
            'This chat is linked to a story name but has no Salesforce record Id. '
              + 'Use Story again, then retry Improve Story.'
          );
        }
        if (!hasEnoughStoryDataToWrite(storyData)) {
          return failure(
            'Not enough story detail in chat to update '
              + formatStoryRef(linked)
              + '. Add acceptance criteria or requirements in chat, then click Improve Story again.'
          );
        }
        if (linked.recordId != null) {
          storyData.put('targetStoryId', String.valueOf(linked.recordId));
        }
        storyData.put('updateExisting', true);
        storyData.put('existingStoryRef', session.Copado_User_Story__c);

        action = logAction(
          sessionId,
          'Improve Story',
          'In Progress',
          JSON.serialize(storyData),
          null,
          null
        );

        CopadoAiApiService.StoryResult story = CopadoAiApiService.createUserStory(
          String.valueOf(sessionId),
          storyData
        );
        if (story == null) {
          if (action != null) {
            action.Status__c = 'Failed';
            action.Error__c = 'createUserStory returned null';
            update action;
          }
          return failure('Could not update the linked User Story (empty response). Try again.');
        }

        if (action != null) {
          action.Status__c = 'Success';
          action.Response__c = JSON.serialize(story);
          update action;
        }

        session = loadSession(sessionId);
        if (String.isNotBlank(workspaceId)) {
          session.Workspace_Id__c = workspaceId;
        }
        if (String.isNotBlank(dialogueId)) {
          session.Dialogue_Id__c = dialogueId;
        }

        String storyLabel = String.isNotBlank(story.storyId) ? story.storyId : formatStoryRef(linked);
        if (String.isNotBlank(story.storyName)) {
          storyLabel += ' — ' + story.storyName;
        }
        String draftBody = formatStoryDataForChat(storyData);
        applyStoryLink(
          session,
          String.isNotBlank(story.recordId) ? story.recordId : linked.recordId,
          String.isNotBlank(story.storyId) ? story.storyId : linked.name,
          String.isNotBlank(story.storyName) ? story.storyName : linked.title
        );
        session.Summary__c = truncateForLongText(
          String.isNotBlank(draftBody)
            ? draftBody
            : (String.isNotBlank(story.summary) ? story.summary : session.Summary__c),
          131072
        );
        session.Current_Step__c = 'Story Created';
        session.Status__c = 'Story Created';
        // Story body changed — old Build package / Deploy progress no longer applies.
        Boolean clearedArtifacts = clearStaleBuildArtifacts(session);
        if (score != null) {
          session.Score__c = score.totalScore;
          session.Risk_Level__c = score.riskLevel;
        }
        applyChatDraftToSession(session, score, draftBody);
        update session;

        Id linkedStoryId = linked.recordId;
        if (linkedStoryId == null && String.isNotBlank(story.recordId)) {
          try {
            linkedStoryId = (Id) story.recordId;
          } catch (Exception ignore) {
          }
        }
        if (linkedStoryId != null) {
          try {
            CopadoDevopsService.clearUserStoryBuildArtifacts(linkedStoryId);
          } catch (Exception ignore) {
          }
        }

        insertMessage(
          sessionId,
          'System',
          'Updated linked Copado user story: ' + storyLabel
            + ' with improved fields from this chat.'
            + (clearedArtifacts
              ? ' Cleared previous Build artifacts — click Build to generate a new package.'
              : ''),
          'Story Created'
        );
        if (String.isNotBlank(draftBody)) {
          insertMessage(sessionId, 'Assistant', draftBody, 'Story Created');
        }

        // Re-score after Summary write
        StoryScore afterScore = scoreStory(sessionId);
        session = loadSession(sessionId);
        if (afterScore != null) {
          session.Score__c = afterScore.totalScore;
          session.Risk_Level__c = afterScore.riskLevel;
          update session;
        }

        ActionResult result = new ActionResult();
        result.success = true;
        result.message = 'Updated ' + storyLabel + ' from chat.'
          + (clearedArtifacts ? ' Previous artifacts cleared — click Build next.' : '');
        result.session = getSessionState(sessionId);
        return result;
      }

      // No linked story — discovery polish only (same tips as before + draft snapshot)
      if (coverage == null) {
        coverage = assessChatCoverage(sessionId);
      }
      if (coverage.presentLabels == null) {
        coverage.presentLabels = new List<String>();
      }
      if (coverage.missingLabels == null) {
        coverage.missingLabels = new List<String>();
      }
      Integer scoreTotal = score != null && score.totalScore != null ? score.totalScore : 0;
      String prompt;
      String draftBody = formatStoryDataForChat(storyData);
      if (coverage.isComplete == true && scoreTotal >= 70) {
        prompt =
          'Your chat already covers the story details Copado needs:\n\n'
          + '• ' + String.join(coverage.presentLabels, '\n• ')
          + '\n\nStory score is '
          + String.valueOf(scoreTotal)
          + '%. You can Create Story now — no need to ask Copado AI for more of these details.';
      } else if (!coverage.missingLabels.isEmpty()) {
        List<String> tips = new List<String>();
        for (String label : coverage.missingLabels) {
          if (label == 'acceptance criteria') {
            tips.add('Acceptance criteria — 2–3 concrete “done” checks (not yet clear in chat).');
          } else if (label == 'requirements clarity') {
            tips.add('Requirements clarity — what to build and why (persona / want / so that).');
          } else if (label == 'org context') {
            tips.add('Org context — what exists (or doesn’t) in the connected org for this change.');
          } else if (label == 'test scenarios') {
            tips.add('Test scenarios — happy path plus at least one edge/error case.');
          } else {
            tips.add(label);
          }
        }
        prompt =
          'I checked the chat. Already present: '
          + (coverage.presentLabels.isEmpty() ? 'nothing substantial yet' : String.join(coverage.presentLabels, ', '))
          + '.\n\nStill missing — ask Copado AI only for these:\n\n• '
          + String.join(tips, '\n• ');
      } else {
        prompt =
          'Chat has the main sections (score '
          + String.valueOf(scoreTotal)
          + '%). Optional polish only — otherwise Create Story is fine.';
      }

      insertMessage(sessionId, 'Assistant', prompt, 'Discovery');
      if (String.isNotBlank(draftBody) && String.isNotBlank(strVal(storyData, 'title', ''))) {
        insertMessage(
          sessionId,
          'Assistant',
          'Draft ready for Create Story (not written to a Copado User Story yet):\n\n' + draftBody,
          'Discovery'
        );
      }

      session = loadSession(sessionId);
      session.Score__c = score.totalScore;
      session.Risk_Level__c = score.riskLevel;
      applyChatDraftToSession(session, score, draftBody);
      update session;

      ActionResult result = new ActionResult();
      result.success = true;
      result.message = prompt;
      result.session = getSessionState(sessionId);
      return result;
    } catch (Exception ex) {
      if (action != null && action.Id != null) {
        try {
          action.Status__c = 'Failed';
          action.Error__c = formatException(ex);
          update action;
        } catch (Exception ignore) {
        }
      }
      return failure('Could not improve story: ' + formatException(ex));
    }
  }

  @TestVisible
  private static Boolean hasEnoughStoryDataToWrite(Map<String, Object> storyData) {
    if (storyData == null) {
      return false;
    }
    Integer filled = 0;
    for (String key : new List<String>{
      'title', 'asA', 'wantTo', 'soThat', 'acceptanceCriteria', 'functionalSpecs', 'technicalSpecs'
    }) {
      if (String.isNotBlank(strVal(storyData, key, ''))) {
        filled++;
      }
    }
    // Title alone is not enough — need persona or AC/specs from chat.
    return filled >= 2;
  }

  /**
   * After Improve Story / story switch, drop the previous Build package and job
   * progress so the Status panel does not keep showing another story's pipeline.
   * @return true when a prior package or build id was present
   */
  @TestVisible
  private static Boolean clearStaleBuildArtifacts(AI_Builder_Session__c session) {
    if (session == null) {
      return false;
    }
    Boolean hadPackage = String.isNotBlank(session.Build_Package_Json__c)
      || String.isNotBlank(session.Last_Build_Id__c)
      || String.isNotBlank(session.Artifact_Content_Document_Id__c)
      || String.isNotBlank(session.Last_Deploy_Job_Id__c)
      || String.isNotBlank(session.Last_Commit_Job_Id__c)
      || String.isNotBlank(session.Last_Job_Id__c)
      || String.isNotBlank(session.Last_Promotion_Id__c);
    session.Build_Package_Json__c = null;
    session.Last_Build_Id__c = null;
    session.Artifact_Content_Document_Id__c = null;
    session.Last_Deploy_Job_Id__c = null;
    session.Last_Commit_Job_Id__c = null;
    session.Last_Job_Action__c = null;
    session.Last_Promotion_Id__c = null;
    session.Last_Job_Id__c = null;
    return hadPackage;
  }

  /**
   * When the chat links a different Copado story (or creates a new one), reset
   * pipeline Status and re-derive Deploy/Commit from the story itself.
   */
  @TestVisible
  private static void resetPipelineForStoryChange(
    AI_Builder_Session__c session,
    Id newStoryId,
    Boolean isNewStory
  ) {
    if (session == null) {
      return;
    }
    clearStaleBuildArtifacts(session);
    if (isNewStory == true || newStoryId == null) {
      session.Current_Step__c = 'Story Created';
      session.Status__c = 'Story Created';
      return;
    }

    // Linked existing story: reflect Copado progress (USC) so Validate is accurate.
    Boolean hasCommits = false;
    try {
      hasCommits = CopadoDevopsService.userStoryHasCommits(newStoryId);
    } catch (Exception ignore) {
      hasCommits = false;
    }
    if (hasCommits) {
      // Markers — not pollable Job Execution Ids. pastCommit + non-blank deploy/commit ids
      // drive Successful Deploy/Commit without inventing fake JE records.
      session.Last_Deploy_Job_Id__c = 'story-linked-deploy';
      session.Last_Commit_Job_Id__c = 'story-linked-commit';
      session.Current_Step__c = 'Committed';
      session.Status__c = 'Story Created';
    } else {
      session.Current_Step__c = 'Story Linked';
      session.Status__c = 'Story Created';
    }
  }

  @TestVisible
  private static Boolean storyRecordChanged(AI_Builder_Session__c session, Id newStoryId) {
    if (session == null || newStoryId == null) {
      return true;
    }
    if (String.isBlank(session.Story_Record_Id__c)) {
      return true;
    }
    try {
      return (Id) session.Story_Record_Id__c != newStoryId;
    } catch (Exception ignore) {
      return true;
    }
  }

  @TestVisible
  private static String formatStoryDataForChat(Map<String, Object> storyData) {
    if (storyData == null || storyData.isEmpty()) {
      return null;
    }
    List<String> lines = new List<String>();
    String title = strVal(storyData, 'title', '');
    String asA = strVal(storyData, 'asA', '');
    String wantTo = strVal(storyData, 'wantTo', '');
    String soThat = strVal(storyData, 'soThat', '');
    String acceptance = strVal(storyData, 'acceptanceCriteria', '');
    String functional = strVal(storyData, 'functionalSpecs', '');
    String technical = strVal(storyData, 'technicalSpecs', '');

    if (String.isNotBlank(title)) {
      lines.add('## ' + title);
    }
    if (String.isNotBlank(asA) || String.isNotBlank(wantTo) || String.isNotBlank(soThat)) {
      lines.add('');
      if (String.isNotBlank(asA)) {
        lines.add('**As a:** ' + asA);
      }
      if (String.isNotBlank(wantTo)) {
        lines.add('**Want to:** ' + wantTo);
      }
      if (String.isNotBlank(soThat)) {
        lines.add('**So that:** ' + soThat);
      }
    }
    if (String.isNotBlank(acceptance)) {
      lines.add('');
      lines.add('### Acceptance Criteria');
      lines.add(acceptance);
    }
    if (String.isNotBlank(functional)) {
      lines.add('');
      lines.add('### Functional Specifications');
      lines.add(functional);
    }
    if (String.isNotBlank(technical)) {
      lines.add('');
      lines.add('### Technical Specifications');
      lines.add(technical);
    }
    return lines.isEmpty() ? null : String.join(lines, '\n');
  }

  private static String strVal(Map<String, Object> data, String key, String fallback) {
    if (data == null || !data.containsKey(key) || data.get(key) == null) {
      return fallback;
    }
    String value = String.valueOf(data.get(key)).trim();
    return String.isBlank(value) ? fallback : value;
  }

  @AuraEnabled
  public static List<StoryHistoryDto> getMySessions() {
    List<StoryHistoryDto> history = new List<StoryHistoryDto>();
    Id userId = UserInfo.getUserId();
    for (AI_Builder_Session__c session : [
      SELECT
        Id,
        Name,
        Status__c,
        Score__c,
        Copado_User_Story__c,
        CreatedDate,
        LastModifiedDate,
        Summary__c,
        (
          SELECT Message__c
          FROM Messages__r
          WHERE Role__c = 'User'
          ORDER BY CreatedDate ASC
          LIMIT 1
        )
      FROM AI_Builder_Session__c
      WHERE OwnerId = :userId
      ORDER BY LastModifiedDate DESC
      LIMIT 50
    ]) {
      StoryHistoryDto item = new StoryHistoryDto();
      item.sessionId = session.Id;
      String storyLabel = formatStoryLink(session.Copado_User_Story__c);
      item.name = String.isNotBlank(storyLabel) ? storyLabel : session.Name;
      item.status = session.Status__c;
      item.score = session.Score__c != null ? Integer.valueOf(session.Score__c) : 0;
      item.copadoUserStory = session.Copado_User_Story__c;
      item.createdDate = session.CreatedDate;
      item.lastModifiedDate = session.LastModifiedDate;
      item.summary = session.Summary__c;
      if (!session.Messages__r.isEmpty() && String.isNotBlank(session.Messages__r[0].Message__c)) {
        String preview = session.Messages__r[0].Message__c.trim();
        item.preview = preview.length() > 100 ? preview.substring(0, 100) + '…' : preview;
      } else if (String.isNotBlank(session.Summary__c)) {
        String preview = session.Summary__c.trim();
        item.preview = preview.length() > 100 ? preview.substring(0, 100) + '…' : preview;
      } else {
        item.preview = 'New chat';
      }
      history.add(item);
    }
    return history;
  }

  /**
   * Delete a Builder chat (Salesforce session + messages) and best-effort
   * delete the linked Copado AI dialogue so the two sides stay in sync.
   * Returns a usable session (opens another chat or starts a new one).
   */
  @AuraEnabled
  public static SessionState deleteSession(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = [
      SELECT Id, OwnerId, Dialogue_Id__c, Name
      FROM AI_Builder_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];
    if (session.OwnerId != UserInfo.getUserId()) {
      throw new AuraHandledException('You can only delete your own Builder chats.');
    }

    String dialogueId = session.Dialogue_Id__c;
    // Callouts before DML
    if (String.isNotBlank(dialogueId)) {
      try {
        CopadoAiApiService.deleteDialogue(dialogueId);
      } catch (Exception ignore) {
        // Copado side is best-effort; still remove the Builder session.
      }
    }

    delete session;

    List<AI_Builder_Session__c> remaining = [
      SELECT Id
      FROM AI_Builder_Session__c
      WHERE OwnerId = :UserInfo.getUserId()
      ORDER BY LastModifiedDate DESC
      LIMIT 1
    ];
    if (!remaining.isEmpty()) {
      return openSession(remaining[0].Id);
    }
    return startSession();
  }

  @AuraEnabled
  public static SessionState openSession(Id sessionId) {
    validateSessionId(sessionId);
    AI_Builder_Session__c session = [
      SELECT Id, OwnerId
      FROM AI_Builder_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];
    if (session.OwnerId != UserInfo.getUserId()) {
      throw new AuraHandledException('You can only open your own chats.');
    }
    return getSessionState(sessionId);
  }

  @AuraEnabled(cacheable=true)
  public static List<StoryHistoryDto> getStoryHistory() {
    // Kept for compatibility — completed stories for the current user
    List<StoryHistoryDto> history = new List<StoryHistoryDto>();
    Id userId = UserInfo.getUserId();
    for (AI_Builder_Session__c session : [
      SELECT Id, Name, Status__c, Score__c, Copado_User_Story__c, CreatedDate, LastModifiedDate, Summary__c
      FROM AI_Builder_Session__c
      WHERE OwnerId = :userId AND Copado_User_Story__c != null
      ORDER BY CreatedDate DESC
      LIMIT 50
    ]) {
      StoryHistoryDto item = new StoryHistoryDto();
      item.sessionId = session.Id;
      String storyLabel = formatStoryLink(session.Copado_User_Story__c);
      item.name = String.isNotBlank(storyLabel) ? storyLabel : session.Name;
      item.status = session.Status__c;
      item.score = session.Score__c != null ? Integer.valueOf(session.Score__c) : 0;
      item.copadoUserStory = session.Copado_User_Story__c;
      item.createdDate = session.CreatedDate;
      item.lastModifiedDate = session.LastModifiedDate;
      item.summary = session.Summary__c;
      item.preview = session.Copado_User_Story__c;
      history.add(item);
    }
    return history;
  }

  @AuraEnabled
  public static SessionState getSessionState(Id sessionId) {
  validateSessionId(sessionId);
  AI_Builder_Session__c session = loadSession(sessionId);
  // Heal sessions stuck on DeployedNext from older Builder builds (pre-advance).
  if ('DeployedNext'.equalsIgnoreCase(session.Current_Step__c)) {
    try {
      CopadoDevopsService.JobStatus done = new CopadoDevopsService.JobStatus();
      done.isComplete = true;
      done.isFailed = false;
      done.summary = 'Promotion completed.';
      advancePipelineAfterDeployNext(sessionId, session, done);
      session = loadSession(sessionId);
    } catch (Exception healEx) {
      System.debug(LoggingLevel.WARN, 'DeployedNext heal: ' + formatException(healEx));
    }
  }
  StoryScore score = scoreStory(sessionId);
  StoryRef story = resolveStoryRef(session);

  SessionState state = new SessionState();
  state.sessionId = session.Id;
  state.status = session.Status__c;
  state.currentStep = session.Current_Step__c;
  state.copadoUserStory = formatStoryLink(session.Copado_User_Story__c);
  state.storyRecordId = story.recordId != null ? String.valueOf(story.recordId) : session.Story_Record_Id__c;
  state.storyName = String.isNotBlank(session.Story_Name__c) ? session.Story_Name__c : story.name;
  state.storyTitle = String.isNotBlank(session.Story_Title__c) ? session.Story_Title__c : story.title;
  state.lastBuildId = session.Last_Build_Id__c;
  state.lastJobId = session.Last_Job_Id__c;
  state.lastDeployJobId = session.Last_Deploy_Job_Id__c;
  state.lastCommitJobId = session.Last_Commit_Job_Id__c;
  state.lastJobAction = session.Last_Job_Action__c;
  state.lastPromotionId = session.Last_Promotion_Id__c;
  state.builderCodeVersion = CopadoDevopsService.BUILDER_CODE_VERSION;
  state.buildArtifacts = extractArtifactPaths(session.Build_Package_Json__c);
  state.selectedOrg = session.Selected_Org__c;
  String orgCredentialId = resolveSessionOrgCredentialId(session, story);
  state.selectedOrgId = orgCredentialId;
  // Org Context reflects last verified bind only (not a pending dropdown choice).
  if ('Connected'.equalsIgnoreCase(session.Org_Context_Status__c)
    && String.isNotBlank(session.Org_Credential_Id__c)) {
    state.connectedOrgId = session.Org_Credential_Id__c;
    state.connectedOrgName = session.Selected_Org__c;
  }
  state.projectId = story.recordId != null
    ? CopadoDevopsService.getProjectIdFromUserStory(story.recordId)
    : CopadoDevopsService.getPreferredProjectId();
  state.score = score.totalScore;
  state.riskLevel = score.riskLevel;
  state.summary = session.Summary__c;
  state.missingInfo = score.missingInfo;
  persistAndSyncStoryScore(session, score);
  OrgContextSnapshot orgContext = resolveOrgContextSnapshot(session, orgCredentialId);
  state.orgContextStatus = orgContext.status;
  state.orgIntelligenceIntegrationId = orgContext.integrationId;
  // Soft-hide Connected for credentials this user does not own — do not wipe
  // session fields here (that undid a successful Connect/Reconnect).
  String boundCred = String.isNotBlank(session.Org_Credential_Id__c)
    ? session.Org_Credential_Id__c
    : orgCredentialId;
  if (
    'Connected'.equalsIgnoreCase(state.orgContextStatus)
    && String.isNotBlank(boundCred)
    && !CopadoDevopsService.isOrgCredentialOwnedByRunningUser(boundCred)
  ) {
    state.orgContextStatus = 'Not connected';
    state.connectedOrgId = null;
    state.connectedOrgName = null;
  } else if (
    String.isNotBlank(boundCred)
    && String.isBlank(state.selectedOrgId)
    && CopadoDevopsService.isOrgCredentialOwnedByRunningUser(boundCred)
  ) {
    // Prefill picker default from session / last-used credential without Connected.
    state.selectedOrgId = boundCred;
    state.selectedOrg = session.Selected_Org__c;
  }
  state.messages = getMessages(sessionId);

  Boolean lastFailed = false;
  Boolean lastComplete = false;
  Boolean lastInProgress = false;
  // While Validate is queued, adopt a Job Execution created on the Promotion so
  // we do not stay stuck on validate-queued after CreateExecution finishes.
  Boolean wasValidateQueued = isValidateQueuedJobId(session.Last_Job_Id__c);
  Boolean wasDeployNextQueued = isDeployNextQueuedJobId(session.Last_Job_Id__c);
  if (
    (wasValidateQueued || wasDeployNextQueued)
    && Limits.getQueries() < 90
  ) {
    try {
      Id adopted = null;
      if (String.isNotBlank(session.Last_Promotion_Id__c)) {
        Id promoId = (Id) session.Last_Promotion_Id__c;
        Datetime since = Datetime.now().addMinutes(-30);
        adopted = CopadoDevopsService.findLatestJobExecutionForPromotion(promoId, since);
      }
      if (adopted != null) {
        session.Last_Job_Id__c = String.valueOf(adopted);
        session.Current_Step__c = wasDeployNextQueued ? 'DeployingNext' : 'Validating';
        update session;
        state.lastJobId = session.Last_Job_Id__c;
        state.currentStep = session.Current_Step__c;
      } else if (Limits.getQueries() < 95) {
        // Queueable finished but no JE — clear stuck "In progress".
        List<AsyncApexJob> queued = [
          SELECT Id, Status, ExtendedStatus, CompletedDate
          FROM AsyncApexJob
          WHERE ApexClass.Name = 'CopadoValidateQueueable'
            AND CreatedDate >= :Datetime.now().addMinutes(-20)
          ORDER BY CreatedDate DESC
          LIMIT 1
        ];
        if (
          !queued.isEmpty()
          && (
            'Completed'.equalsIgnoreCase(queued[0].Status)
            || 'Failed'.equalsIgnoreCase(queued[0].Status)
            || 'Aborted'.equalsIgnoreCase(queued[0].Status)
          )
        ) {
          session.Last_Job_Id__c = null;
          session.Current_Step__c = wasDeployNextQueued ? 'Validated' : 'Committed';
          update session;
          state.lastJobId = null;
          state.currentStep = session.Current_Step__c;
          lastFailed = true;
          state.lastJobFailed = true;
          state.lastJobSummary =
            'Validate queue finished but no Copado Job Execution was created. '
            + 'Promotion may still be Draft — check Validate Promote Job Template '
            + '(sfdx_promote_1) and Pipeline on the Promotion.';
          if (String.isNotBlank(queued[0].ExtendedStatus)) {
            state.lastJobSummary += ' ' + queued[0].ExtendedStatus;
          }
        }
      }
    } catch (Exception ignore) {
    }
  }
  if (String.isNotBlank(session.Last_Job_Id__c)) {
    // Validate / Deploy-next: Promotion Status wins over a single Promote JE.
    CopadoDevopsService.JobStatus job;
    Boolean validateOrNext =
      'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
      || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
      || 'Validated'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c);
    Id promotionForStatus = null;
    if (validateOrNext && String.isNotBlank(session.Last_Promotion_Id__c)) {
      try {
        promotionForStatus = (Id) session.Last_Promotion_Id__c;
      } catch (Exception ignore) {
      }
    }
    if (promotionForStatus != null) {
      job = CopadoDevopsService.resolveValidateOrDeployNextStatus(
        session.Last_Job_Id__c,
        promotionForStatus,
        false
      );
      // Heal sticky Validated when Promotion actually failed validation.
      if (
        job.isFailed == true
        && (
          'Validated'.equalsIgnoreCase(session.Current_Step__c)
          || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
          || (
            'Committed'.equalsIgnoreCase(session.Current_Step__c)
            && 'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
          )
        )
      ) {
        try {
          if (
            'Validated'.equalsIgnoreCase(session.Current_Step__c)
            || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
          ) {
            session.Current_Step__c = 'Committed';
            update session;
          }
          // Correct the earlier false "Validate succeeded" System line (Promote JE only).
          Boolean alreadyLogged = false;
          for (AI_Builder_Message__c existing : [
            SELECT Message__c
            FROM AI_Builder_Message__c
            WHERE Session__c = :sessionId AND Role__c = 'System'
            ORDER BY CreatedDate DESC
            LIMIT 8
          ]) {
            if (String.isNotBlank(existing.Message__c)
              && existing.Message__c.startsWith('Validate failed:')) {
              alreadyLogged = true;
              break;
            }
          }
          if (!alreadyLogged) {
            String failDetail = String.isNotBlank(job.errorMessage)
              ? job.errorMessage
              : (String.isNotBlank(job.summary) ? job.summary : 'Promotion validation failed');
            insertMessage(
              sessionId,
              'System',
              'Validate failed: '
                + failDetail
                + (String.isNotBlank(session.Last_Promotion_Id__c)
                  ? (' (Promotion ' + session.Last_Promotion_Id__c + ')')
                  : ''),
              'Validate'
            );
          }
        } catch (Exception ignore) {
        }
      }
    } else {
      // Lightweight status only — USC linking runs on Refresh job / Commit schedulable.
      job = CopadoDevopsService.getJobExecutionStatus(session.Last_Job_Id__c, false);
    }
    state.lastJobStatus = job.status;
    state.lastJobSummary = job.summary;
    if (String.isNotBlank(job.errorMessage)) {
      // Prefer Result / JE deploy error over status-only summary (Copado AI Issue 4).
      Integer summaryLen = String.isNotBlank(job.summary) ? job.summary.length() : 0;
      Boolean errorRicher =
        job.errorMessage.length() > summaryLen
        || job.errorMessage.toLowerCase().contains('metadata validation')
        || job.errorMessage.toLowerCase().contains('customfield')
        || job.errorMessage.toLowerCase().contains('componentfailures');
      if (errorRicher) {
        state.lastJobSummary = job.errorMessage;
      }
    }
    // Last resort: status-only summary after failed Validate — force Result extract.
    if (
      promotionForStatus != null
      && job.isFailed == true
      && (
        String.isBlank(state.lastJobSummary)
        || state.lastJobSummary.startsWith('Promotion Validation failed')
        || state.lastJobSummary.equalsIgnoreCase('Validation failed')
        || 'Validation failed'.equalsIgnoreCase(job.status)
      )
      && Limits.getQueries() < 90
    ) {
      try {
        String deployErr = CopadoDevopsService.debugExtractPromotionDeployFailure(promotionForStatus);
        if (String.isNotBlank(deployErr)
          && !deployErr.startsWith('Promotion Validation failed')) {
          state.lastJobSummary = deployErr;
          job.errorMessage = deployErr;
        }
      } catch (Exception ignore) {
      }
    }
    state.lastJobFailed = job.isFailed == true;
    state.lastJobComplete = job.isComplete == true;
    lastFailed = job.isFailed == true;
    lastComplete = job.isComplete == true;
    lastInProgress = job.isComplete != true && job.isFailed != true;
  }
  // Heal stuck Validating / DeployingNext when there is no real Job Execution to poll.
  // Do not heal validate-queued / deploy-next-queued (async start) or mock job ids.
  if (
    (
      'Validating'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
    )
    && !isPollableJobId(session.Last_Job_Id__c)
    && !isValidateQueuedJobId(session.Last_Job_Id__c)
    && !isDeployNextQueuedJobId(session.Last_Job_Id__c)
    && (String.isBlank(session.Last_Job_Id__c)
      || !session.Last_Job_Id__c.startsWith('mock-'))
  ) {
    session.Current_Step__c = 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      ? 'Validated'
      : 'Committed';
    if (String.isNotBlank(session.Last_Job_Id__c)
      && (session.Last_Job_Id__c.startsWith('create-execution-pending')
        || session.Last_Job_Id__c.startsWith('validate-manual')
        || session.Last_Job_Id__c.startsWith('prepared-')
        || session.Last_Job_Id__c.startsWith('webhook-'))) {
      session.Last_Job_Id__c = null;
    }
    update session;
    state.currentStep = session.Current_Step__c;
    state.lastJobId = session.Last_Job_Id__c;
    lastFailed =
      ('Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
        || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c))
      ? true
      : lastFailed;
    lastInProgress = false;
    state.lastJobFailed = lastFailed;
    if (lastFailed == true && String.isBlank(state.lastJobSummary)) {
      state.lastJobSummary =
        'Job did not start a Job Execution. Confirm Job Template API names in Copado Builder Settings.';
    }
  }

  // Prefer session step flags over re-querying Job Executions (SOQL savings on Validate).
  Boolean pastCommit =
    'Committed'.equalsIgnoreCase(session.Current_Step__c)
    || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
    || 'Validated'.equalsIgnoreCase(session.Current_Step__c)
    || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
    || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c)
    || 'Validate'.equalsIgnoreCase(session.Last_Job_Action__c)
    || 'DeployNext'.equalsIgnoreCase(session.Last_Job_Action__c)
    || 'Commit'.equalsIgnoreCase(session.Last_Job_Action__c);
  state.deploySucceeded = String.isNotBlank(session.Last_Deploy_Job_Id__c)
    && (pastCommit
      || ('Deploy'.equalsIgnoreCase(session.Last_Job_Action__c) && lastComplete && !lastFailed)
      || CopadoDevopsService.isJobExecutionSuccessful(session.Last_Deploy_Job_Id__c));
  state.commitSucceeded = String.isNotBlank(session.Last_Commit_Job_Id__c)
    && (pastCommit
      || ('Commit'.equalsIgnoreCase(session.Last_Job_Action__c) && lastComplete && !lastFailed)
      || CopadoDevopsService.isJobExecutionSuccessful(session.Last_Commit_Job_Id__c));
  if (!state.commitSucceeded
    && CopadoAiApiService.isMockMode()
    && 'Committed'.equalsIgnoreCase(session.Current_Step__c)) {
    state.commitSucceeded = true;
  }

  try {
    Id sourceEnvId = null;
    if (String.isNotBlank(orgCredentialId)) {
      sourceEnvId = CopadoDevopsService.resolveEnvironmentRecordId(orgCredentialId);
    }
    Id projectIdForNext = null;
    if (String.isNotBlank(state.projectId)) {
      try {
        projectIdForNext = (Id) state.projectId;
      } catch (Exception ignore) {
      }
    }
    if (sourceEnvId != null) {
      Id nextEnvId = CopadoDevopsService.resolveNextEnvironmentId(sourceEnvId, projectIdForNext);
      if (nextEnvId != null) {
        state.nextEnvironmentId = String.valueOf(nextEnvId);
        state.nextEnvironmentName = CopadoDevopsService.getEnvironmentName(nextEnvId);
      }
    }
  } catch (Exception ignore) {
  }
  state.canValidate = state.commitSucceeded == true && String.isNotBlank(state.nextEnvironmentId);
  if (CopadoAiApiService.isMockMode() && state.commitSucceeded == true) {
    state.canValidate = true;
    if (String.isBlank(state.nextEnvironmentId)) {
      state.nextEnvironmentId = 'mock-next-env';
      state.nextEnvironmentName = 'Mock Next Env';
    }
  }

  applyPipelineStepStatuses(state, session, lastFailed, lastComplete, lastInProgress);
  // Deploy to next is Ready only when Validate Status is Successful (set in applyPipeline).
  state.canDeployNext =
    String.isNotBlank(state.nextEnvironmentId)
    && (
      'Successful'.equalsIgnoreCase(state.validateStepStatus)
      || 'In progress'.equalsIgnoreCase(state.nextDeployStepStatus)
      || 'Successful'.equalsIgnoreCase(state.nextDeployStepStatus)
    );
  state.canCheckDeployment =
    (
      String.isNotBlank(session.Copado_User_Story__c)
      || String.isNotBlank(session.Story_Record_Id__c)
      || String.isNotBlank(state.storyRecordId)
    )
    && String.isNotBlank(orgCredentialId)
    && state.buildArtifacts != null
    && !state.buildArtifacts.isEmpty();
  if (suggestOrgIntelligenceSync == true) {
    state.syncOrgIntelligenceSuggested = true;
    suggestOrgIntelligenceSync = false;
  }
  return state;
  }

  /**
   * Derive Build / Deploy / Commit / Validate labels for the Status panel.
   * Job Detail is only filled when the latest action failed.
   */
  private static void applyPipelineStepStatuses(
    SessionState state,
    AI_Builder_Session__c session,
    Boolean lastFailed,
    Boolean lastComplete,
    Boolean lastInProgress
  ) {
    String action = session.Last_Job_Action__c;
    Boolean hasPackage = (
        String.isNotBlank(session.Build_Package_Json__c)
        && !session.Build_Package_Json__c.contains('_pendingBuild')
      )
      || (
        String.isNotBlank(session.Last_Build_Id__c)
        && !session.Last_Build_Id__c.startsWith('pending')
      );
    Boolean buildDone = hasPackage
      || 'Code Built'.equalsIgnoreCase(session.Status__c)
      || 'Code Built'.equalsIgnoreCase(session.Current_Step__c)
      || state.deploySucceeded == true
      || state.commitSucceeded == true
      || 'Validated'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c);

    // Shared vocabulary for every pipeline row:
    // Not ready | Ready | In progress | Successful | Failed
    Boolean canBuild =
      String.isNotBlank(session.Copado_User_Story__c)
      || String.isNotBlank(session.Story_Record_Id__c)
      || String.isNotBlank(state.storyRecordId);
    if ('Building'.equalsIgnoreCase(session.Current_Step__c)
      || (
        'Build'.equalsIgnoreCase(action)
        && 'In Progress'.equalsIgnoreCase(session.Status__c)
        && !'Code Built'.equalsIgnoreCase(session.Current_Step__c)
        && !'Build Failed'.equalsIgnoreCase(session.Current_Step__c)
      )) {
      state.buildStepStatus = 'In progress';
    } else if ('Build Failed'.equalsIgnoreCase(session.Current_Step__c)) {
      state.buildStepStatus = 'Failed';
    } else if (buildDone) {
      state.buildStepStatus = 'Successful';
    } else if ('Build'.equalsIgnoreCase(action) && lastInProgress == true) {
      state.buildStepStatus = 'In progress';
    } else if ('Build'.equalsIgnoreCase(action) && lastFailed == true) {
      state.buildStepStatus = 'Failed';
    } else if (canBuild) {
      state.buildStepStatus = 'Ready';
    } else {
      state.buildStepStatus = 'Not ready';
    }

    if (state.deploySucceeded == true) {
      state.deployStepStatus = 'Successful';
    } else if ('Deploy'.equalsIgnoreCase(action) && lastInProgress == true) {
      state.deployStepStatus = 'In progress';
    } else if ('Deploy'.equalsIgnoreCase(action) && lastFailed == true) {
      state.deployStepStatus = 'Failed';
    } else if (buildDone) {
      state.deployStepStatus = 'Ready';
    } else {
      state.deployStepStatus = 'Not ready';
    }

    if (state.commitSucceeded == true) {
      state.commitStepStatus = 'Successful';
    } else if ('Commit'.equalsIgnoreCase(action) && lastInProgress == true) {
      state.commitStepStatus = 'In progress';
    } else if ('Commit'.equalsIgnoreCase(action) && lastFailed == true) {
      state.commitStepStatus = 'Failed';
    } else if (state.deploySucceeded == true) {
      state.commitStepStatus = 'Ready';
    } else {
      state.commitStepStatus = 'Not ready';
    }

    // Validate: Successful only after the dry-run Job Execution completes OK.
    // "In progress" requires a real Salesforce Job Execution Id — never placeholders.
    // validate-queued means async CreateExecution is still starting.
    Boolean validateJobPollable = isPollableJobId(session.Last_Job_Id__c);
    Boolean validateQueued = isValidateQueuedJobId(session.Last_Job_Id__c)
      || (
        'Validating'.equalsIgnoreCase(session.Current_Step__c)
        && String.isNotBlank(session.Last_Job_Id__c)
        && session.Last_Job_Id__c.startsWith('mock-')
      );
    Boolean validateInProgress =
      validateQueued
      || (
        validateJobPollable
        && lastFailed != true
        && (
          'Validating'.equalsIgnoreCase(session.Current_Step__c)
          || ('Validate'.equalsIgnoreCase(action) && lastInProgress == true)
        )
      );

    if ('Validate'.equalsIgnoreCase(action) && lastFailed == true && !validateQueued) {
      state.validateStepStatus = 'Failed';
    } else if (validateInProgress) {
      state.validateStepStatus = 'In progress';
    } else if (
      (
        'Validated'.equalsIgnoreCase(session.Current_Step__c)
        || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
        || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c)
      )
      && lastFailed != true
    ) {
      state.validateStepStatus = 'Successful';
    } else if (
      'Validate'.equalsIgnoreCase(action)
      && !'Validated'.equalsIgnoreCase(session.Current_Step__c)
      && !validateJobPollable
      && !validateQueued
    ) {
      // Attempted validate but no live JE (e.g. create-execution-pending)
      state.validateStepStatus = 'Failed';
    } else if (state.canValidate == true) {
      state.validateStepStatus = 'Ready';
    } else {
      state.validateStepStatus = 'Not ready';
    }

    // Next-env deploy (real) — Ready only after Validate Status is Successful.
    Boolean nextDeployQueued = isDeployNextQueuedJobId(session.Last_Job_Id__c);
    Boolean nextDeployInProgress =
      nextDeployQueued
      || (
        validateJobPollable
        && lastFailed != true
        && (
          'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
          || ('DeployNext'.equalsIgnoreCase(action) && lastInProgress == true)
        )
      );
    Boolean validateSucceeded = 'Successful'.equalsIgnoreCase(state.validateStepStatus);
    if ('DeployNext'.equalsIgnoreCase(action) && lastFailed == true && !nextDeployQueued) {
      state.nextDeployStepStatus = 'Failed';
    } else if (nextDeployInProgress) {
      state.nextDeployStepStatus = 'In progress';
    } else if (
      'DeployedNext'.equalsIgnoreCase(session.Current_Step__c)
      && lastFailed != true
      && validateSucceeded
    ) {
      state.nextDeployStepStatus = 'Successful';
    } else if (validateSucceeded && String.isNotBlank(state.nextEnvironmentId)) {
      state.nextDeployStepStatus = 'Ready';
    } else {
      state.nextDeployStepStatus = 'Not ready';
    }

    // Keep canDeployNext aligned with Validate Successful (callers may set it earlier).
    if (state.canDeployNext != true) {
      state.canDeployNext =
        validateSucceeded
        && String.isNotBlank(state.nextEnvironmentId);
    }
    if (!validateSucceeded
      && !'In progress'.equalsIgnoreCase(state.nextDeployStepStatus)
      && !'Successful'.equalsIgnoreCase(state.nextDeployStepStatus)) {
      state.canDeployNext = false;
    }

    // Legacy fields still used by older UI / tests
    state.buildStatus = state.buildStepStatus;
    state.testStatus = '—';
    state.deployStatus = state.deployStepStatus;

    if (lastFailed == true
      || 'Failed'.equalsIgnoreCase(state.validateStepStatus)
      || 'Failed'.equalsIgnoreCase(state.nextDeployStepStatus)
    ) {
      String errAction = String.isNotBlank(action) ? action : 'Job';
      if ('Failed'.equalsIgnoreCase(state.validateStepStatus)
        && (String.isBlank(errAction) || 'Job'.equalsIgnoreCase(errAction))) {
        errAction = 'Validate';
      }
      if ('Failed'.equalsIgnoreCase(state.nextDeployStepStatus)
        && (String.isBlank(errAction) || 'Job'.equalsIgnoreCase(errAction))) {
        errAction = 'DeployNext';
      }
      state.pipelineErrorAction = errAction;
      // Keep Last_Job_Id for Build/Commit JE links. Validate/Deploy-next UI prefers
      // Last_Promotion_Id__c (Promotion page shows Status + all jobs).
      state.pipelineErrorJobId = session.Last_Job_Id__c;
      state.pipelineErrorDetail = String.isNotBlank(state.lastJobSummary)
        ? state.lastJobSummary
        : ('Job status: ' + (String.isNotBlank(state.lastJobStatus) ? state.lastJobStatus : 'Failed'));
      // Surface Promotion Id in detail when Validate/Deploy-next failed on Promotion Status.
      Boolean promoAction =
        'Validate'.equalsIgnoreCase(errAction)
        || 'DeployNext'.equalsIgnoreCase(errAction);
      if (
        promoAction
        && String.isNotBlank(session.Last_Promotion_Id__c)
        && (String.isBlank(state.pipelineErrorDetail)
          || !state.pipelineErrorDetail.contains(session.Last_Promotion_Id__c))
      ) {
        state.pipelineErrorDetail =
          (String.isNotBlank(state.pipelineErrorDetail)
            ? state.pipelineErrorDetail + ' '
            : '')
          + '(Promotion ' + session.Last_Promotion_Id__c + ')';
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /** True when Last_Job_Id can be queried as copado__JobExecution__c. */
  @TestVisible
  private static Boolean isPollableJobId(String jobId) {
    if (String.isBlank(jobId)) {
      return false;
    }
    if (jobId.startsWith('create-execution-pending')
      || jobId.startsWith('validate-manual')
      || jobId.startsWith('validate-queued')
      || jobId.startsWith('deploy-next-queued')
      || jobId.startsWith('prepared-')
      || jobId.startsWith('webhook-')
      || jobId.startsWith('mock-')
      || jobId.startsWith('story-linked-')) {
      return false;
    }
    try {
      return (Id) jobId != null;
    } catch (Exception ignore) {
      return false;
    }
  }

  @TestVisible
  private static Boolean isValidateQueuedJobId(String jobId) {
    return String.isNotBlank(jobId) && jobId.startsWith('validate-queued');
  }

  @TestVisible
  private static Boolean isDeployNextQueuedJobId(String jobId) {
    return String.isNotBlank(jobId) && jobId.startsWith('deploy-next-queued');
  }

  /**
   * Minimal session snapshot when the request is near SOQL limits after Validate.
   */
  private static SessionState getSessionStateLite(Id sessionId) {
    AI_Builder_Session__c session = loadSession(sessionId);
    SessionState state = new SessionState();
    state.sessionId = session.Id;
    state.status = session.Status__c;
    state.currentStep = session.Current_Step__c;
    state.copadoUserStory = formatStoryLink(session.Copado_User_Story__c);
    state.storyRecordId = session.Story_Record_Id__c;
    state.storyName = session.Story_Name__c;
    state.storyTitle = session.Story_Title__c;
    state.lastBuildId = session.Last_Build_Id__c;
    state.lastJobId = session.Last_Job_Id__c;
    state.lastDeployJobId = session.Last_Deploy_Job_Id__c;
    state.lastCommitJobId = session.Last_Commit_Job_Id__c;
    state.lastJobAction = session.Last_Job_Action__c;
    state.lastPromotionId = session.Last_Promotion_Id__c;
    state.builderCodeVersion = CopadoDevopsService.BUILDER_CODE_VERSION;
    state.buildArtifacts = extractArtifactPaths(session.Build_Package_Json__c);
    state.selectedOrg = session.Selected_Org__c;
    state.selectedOrgId = session.Org_Credential_Id__c;
    state.connectedOrgId = session.Org_Credential_Id__c;
    state.connectedOrgName = session.Selected_Org__c;
    state.orgContextStatus = session.Org_Context_Status__c;
    state.summary = session.Summary__c;
    state.messages = getMessages(sessionId);
    state.deploySucceeded = String.isNotBlank(session.Last_Deploy_Job_Id__c);
    state.commitSucceeded = String.isNotBlank(session.Last_Commit_Job_Id__c);
    state.canValidate = state.commitSucceeded == true;
    applyPipelineStepStatuses(
      state,
      session,
      false,
      false,
      isValidateQueuedJobId(session.Last_Job_Id__c)
        || isDeployNextQueuedJobId(session.Last_Job_Id__c)
    );
    state.canDeployNext =
      'Successful'.equalsIgnoreCase(state.validateStepStatus)
      || 'In progress'.equalsIgnoreCase(state.nextDeployStepStatus)
      || 'Successful'.equalsIgnoreCase(state.nextDeployStepStatus);
    state.canCheckDeployment =
      (
        String.isNotBlank(session.Copado_User_Story__c)
        || String.isNotBlank(session.Story_Record_Id__c)
      )
      && String.isNotBlank(session.Org_Credential_Id__c)
      && state.buildArtifacts != null
      && !state.buildArtifacts.isEmpty();
    return state;
  }

  private static ActionResult runStoryRequiredAction(Id sessionId, String actionType) {
    // Legacy path retained for compatibility; prefer dedicated methods.
    if (actionType == 'Build Code') {
      return buildCode(sessionId, null, false);
    }
    if (actionType == 'Review Code') {
      return reviewCode(sessionId);
    }
    if (actionType == 'Create Tests') {
      return createTests(sessionId);
    }
    return failure('Unknown action: ' + actionType);
  }

  private class StoryScore {
  Integer totalScore;
  String riskLevel;
  String summary;
  List<String> missingInfo;
  }

  private class ChatCoverage {
    Boolean isComplete;
    List<String> presentLabels;
    List<String> missingLabels;
  }

  /**
   * When chat already has a full draft, keep Summary in sync so score/Create/Build
   * do not wait for Create Story to "discover" details that were already said.
   */
  private static void applyChatDraftToSession(
    AI_Builder_Session__c session,
    StoryScore score,
    String latestAssistantReply
  ) {
    if (session == null || score == null) {
      return;
    }
    ChatCoverage coverage = assessChatCoverageFromText(
      collectChatStoryText(session.Id, session.Summary__c)
    );
    Boolean complete = coverage != null && coverage.isComplete == true;
    Boolean highScore = score.totalScore != null && score.totalScore >= 70;
    if (complete && highScore) {
      String draft = String.isNotBlank(latestAssistantReply) && isStoryDraftMessage(latestAssistantReply)
        ? latestAssistantReply
        : findBestStoryDraftText(session.Id);
      if (String.isNotBlank(draft)) {
        session.Summary__c = truncateForLongText(draft, 131072);
        return;
      }
    }
    // Do not replace linked/draft story body with a one-line readiness blurb.
    if (!isStoryBodySummary(session.Summary__c)) {
      session.Summary__c = score.summary;
    }
  }

  private static ChatCoverage assessChatCoverage(Id sessionId) {
    AI_Builder_Session__c session = [
      SELECT Summary__c
      FROM AI_Builder_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];
    return assessChatCoverageFromText(collectChatStoryText(sessionId, session.Summary__c));
  }

  private static String collectChatStoryText(Id sessionId, String summary) {
    List<AI_Builder_Message__c> messages = [
      SELECT Message__c, Role__c
      FROM AI_Builder_Message__c
      WHERE Session__c = :sessionId
        AND Role__c IN ('User', 'Assistant')
      ORDER BY CreatedDate ASC
    ];
    String combined = '';
    for (AI_Builder_Message__c msg : messages) {
      if (String.isBlank(msg.Message__c)) {
        continue;
      }
      String text = msg.Message__c.trim();
      if (msg.Role__c == 'User') {
        if (isNonStoryUserChatter(text)) {
          continue;
        }
        combined += ' ' + text;
      } else if (isStoryDraftMessage(text)) {
        combined += ' ' + text;
      }
    }
    if (isStoryBodySummary(summary)) {
      combined += ' ' + summary;
    }
    return combined.toLowerCase();
  }

  @TestVisible
  private static ChatCoverage assessChatCoverageFromText(String lowerCombined) {
    ChatCoverage coverage = new ChatCoverage();
    coverage.presentLabels = new List<String>();
    coverage.missingLabels = new List<String>();
    if (String.isBlank(lowerCombined)) {
      coverage.isComplete = false;
      coverage.missingLabels.addAll(new List<String>{
        'acceptance criteria', 'requirements clarity', 'org context', 'test scenarios'
      });
      return coverage;
    }

    Boolean hasAcceptance = hasStorySection(lowerCombined, new List<String>{
      'acceptance criteria', 'definition of done', 'acceptance criterion'
    });
    Boolean hasClarity = hasStorySection(lowerCombined, new List<String>{
      'requirements clarity', 'functional requirements', 'functional specifications',
      'technical specifications', 'proposed user story'
    });
    Boolean hasOrg = hasStorySection(lowerCombined, new List<String>{
      'org context', 'organization context', 'connected org', 'no existing',
      'net-new', 'no conflicting'
    });
    Boolean hasTest = hasStorySection(lowerCombined, new List<String>{
      'test scenarios', 'test scenario', 'unit tests', 'edge cases', 'test cases'
    });
    Boolean hasPersona = lowerCombined.contains('as a')
      && (lowerCombined.contains('i want') || lowerCombined.contains('want to'))
      && lowerCombined.contains('so that');

    if (hasAcceptance) {
      coverage.presentLabels.add('acceptance criteria');
    } else {
      coverage.missingLabels.add('acceptance criteria');
    }
    if (hasClarity || hasPersona) {
      coverage.presentLabels.add('requirements clarity');
    } else {
      coverage.missingLabels.add('requirements clarity');
    }
    if (hasOrg) {
      coverage.presentLabels.add('org context');
    } else {
      coverage.missingLabels.add('org context');
    }
    if (hasTest) {
      coverage.presentLabels.add('test scenarios');
    } else {
      coverage.missingLabels.add('test scenarios');
    }
    coverage.isComplete = coverage.missingLabels.isEmpty();
    return coverage;
  }

  @TestVisible
  private static String findBestStoryDraftText(Id sessionId) {
    List<AI_Builder_Message__c> messages = [
      SELECT Message__c
      FROM AI_Builder_Message__c
      WHERE Session__c = :sessionId
        AND Role__c = 'Assistant'
      ORDER BY CreatedDate DESC
      LIMIT 20
    ];
    String best = null;
    Integer bestLen = 0;
    for (AI_Builder_Message__c msg : messages) {
      if (String.isBlank(msg.Message__c) || !isStoryDraftMessage(msg.Message__c)) {
        continue;
      }
      Integer len = msg.Message__c.length();
      if (len > bestLen) {
        bestLen = len;
        best = msg.Message__c;
      }
    }
    return best;
  }

  /**
   * Keep Score__c / Risk_Level__c aligned with live scoreStory results (Status panel).
   * When linked, sync sibling chats for the same User Story so My Chats stays consistent.
   */
  @TestVisible
  private static void persistAndSyncStoryScore(
    AI_Builder_Session__c session,
    StoryScore score
  ) {
    if (session == null || session.Id == null || score == null) {
      return;
    }
    Integer liveScore = score.totalScore != null ? score.totalScore : 0;
    String liveRisk = String.isNotBlank(score.riskLevel) ? score.riskLevel : 'Low';
    Integer storedScore = session.Score__c != null ? Integer.valueOf(session.Score__c) : null;
    String storedRisk = session.Risk_Level__c;

    List<AI_Builder_Session__c> toUpdate = new List<AI_Builder_Session__c>();
    if (storedScore != liveScore || storedRisk != liveRisk) {
      toUpdate.add(new AI_Builder_Session__c(
        Id = session.Id,
        Score__c = liveScore,
        Risk_Level__c = liveRisk
      ));
      session.Score__c = liveScore;
      session.Risk_Level__c = liveRisk;
    }

    if (String.isNotBlank(session.Story_Record_Id__c)) {
      for (AI_Builder_Session__c sibling : [
        SELECT Id, Score__c, Risk_Level__c
        FROM AI_Builder_Session__c
        WHERE Story_Record_Id__c = :session.Story_Record_Id__c
          AND Id != :session.Id
        LIMIT 200
      ]) {
        Integer sibScore = sibling.Score__c != null ? Integer.valueOf(sibling.Score__c) : null;
        if (sibScore != liveScore || sibling.Risk_Level__c != liveRisk) {
          toUpdate.add(new AI_Builder_Session__c(
            Id = sibling.Id,
            Score__c = liveScore,
            Risk_Level__c = liveRisk
          ));
        }
      }
    }

    if (!toUpdate.isEmpty()) {
      try {
        update toUpdate;
      } catch (Exception ex) {
        System.debug(LoggingLevel.WARN, 'persistAndSyncStoryScore: ' + ex.getMessage());
      }
    }
  }

  private static StoryScore scoreStory(Id sessionId) {
    // Linked sessions: score the Copado User Story record (stable across chats).
    // Unlinked sessions: score chat requirements + story-body Summary.
    AI_Builder_Session__c session = [
      SELECT
        Summary__c,
        Copado_User_Story__c,
        Story_Record_Id__c,
        Story_Name__c,
        Story_Title__c
      FROM AI_Builder_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];

    StoryRef linked = resolveStoryRef(session);
    Boolean hasLinkedStory =
      linked.recordId != null || String.isNotBlank(session.Copado_User_Story__c);

    String combined = '';
    Integer substantiveChars = 0;

    if (linked.recordId != null) {
      try {
        CopadoDevopsService.UserStoryContext ctx =
          CopadoDevopsService.getUserStoryContext(linked.recordId);
        if (ctx != null && String.isNotBlank(ctx.summaryText)) {
          substantiveChars = ctx.summaryText.length();
          combined = ctx.summaryText;
        }
      } catch (Exception ignore) {
      }
      // Fallback when US context is empty: story-body Summary only (never chat soup).
      if (substantiveChars < 40 && isStoryBodySummary(session.Summary__c)) {
        substantiveChars = session.Summary__c.length();
        combined = session.Summary__c;
      }
    } else {
      List<AI_Builder_Message__c> messages = [
        SELECT Message__c, Role__c
        FROM AI_Builder_Message__c
        WHERE Session__c = :sessionId
          AND Role__c IN ('User', 'Assistant')
        ORDER BY CreatedDate ASC
      ];
      for (AI_Builder_Message__c msg : messages) {
        if (String.isBlank(msg.Message__c)) {
          continue;
        }
        String text = msg.Message__c.trim();
        if (msg.Role__c == 'User') {
          if (isNonStoryUserChatter(text)) {
            continue;
          }
          substantiveChars += text.length();
          combined += ' ' + text;
        } else if (isStoryDraftMessage(text)) {
          substantiveChars += text.length();
          combined += ' ' + text;
        }
      }
      if (isStoryBodySummary(session.Summary__c)) {
        substantiveChars += session.Summary__c.length();
        combined += ' ' + session.Summary__c;
      }
    }
    combined = combined.toLowerCase();

    StoryScore empty = new StoryScore();
    empty.totalScore = 0;
    empty.riskLevel = 'Low';
    empty.summary = 'No story draft yet.';
    empty.missingInfo = new List<String>{
      'acceptance criteria',
      'requirements clarity',
      'org context',
      'test scenarios'
    };
    // Need real requirements text before any score (connection checks don't count).
    if (substantiveChars < 40 || String.isBlank(combined)) {
      return empty;
    }

    Boolean hasAcceptanceSection = hasStorySection(combined, new List<String>{
      'acceptance criteria', 'definition of done', 'acceptance criterion'
    });
    Boolean hasClaritySection = hasStorySection(combined, new List<String>{
      'requirements clarity', 'functional requirements', 'functional specifications',
      'technical specifications', 'proposed user story'
    });
    Boolean hasOrgSection = hasStorySection(combined, new List<String>{
      'org context', 'organization context', 'connected org', 'no existing',
      'net-new', 'no conflicting'
    });
    Boolean hasTestSection = hasStorySection(combined, new List<String>{
      'test scenarios', 'test scenario', 'unit tests', 'edge cases', 'test cases'
    });
    Boolean hasPersona = combined.contains('as a')
      && (combined.contains('i want') || combined.contains('want to'))
      && combined.contains('so that');

    Integer clarity = scoreDimension(
      combined,
      new List<String>{
        'because', 'should', 'need', 'want', 'require', 'build',
        'user story', 'as a', 'so that', 'i want', 'want to',
        'field label', 'api name', 'object', 'utility', 'apex', 'class'
      },
      25
    );
    Integer acceptance = scoreDimension(
      combined,
      new List<String>{
        'acceptance', 'criteria', 'given', 'when', 'then', 'verify',
        'default value', 'required', 'checkbox', 'page layout', 'unchecked', 'checked',
        'functional specifications', 'technical specifications', 'picklist',
        'throws', 'callable', 'coverage', 'pass'
      },
      25
    );
    Integer orgContext = scoreDimension(
      combined,
      new List<String>{
        'account', 'contact', 'opportunity', 'flow', 'trigger', 'field',
        'object', 'api name', 'page layout', 'salesforce', '__c',
        'org', 'api version', 'deployable', 'pipeline', 'duplicate'
      },
      20
    );
    Integer testability = scoreDimension(
      combined,
      new List<String>{
        'test', 'edge', 'error', 'validation', 'bulk', 'verify', 'assert', 'scenario',
        'unit test', 'coverage', 'exception', 'guard'
      },
      15
    );

    // Explicit Copado AI section headers / persona block beat sparse keyword hits
    // (Apex/utility drafts rarely use field/layout keywords).
    if (hasClaritySection || hasPersona) {
      clarity = Math.max(clarity, 20);
    }
    if (hasAcceptanceSection) {
      acceptance = Math.max(acceptance, 20);
    }
    if (hasOrgSection) {
      orgContext = Math.max(orgContext, 16);
    }
    if (hasTestSection) {
      testability = Math.max(testability, 12);
    }

    // Structured metadata drafts (field/object tables) are strong readiness signals
    if (looksLikeStructuredStory(combined)) {
      clarity = Math.max(clarity, 20);
      acceptance = Math.max(acceptance, 18);
      orgContext = Math.max(orgContext, 16);
      if (testability < 8) {
        testability = 8;
      }
    }

    Boolean readyDraft = looksLikeStructuredStory(combined)
      || hasPersona
      || (hasAcceptanceSection && (hasClaritySection || hasOrgSection || hasTestSection));

    // Deploy-risk points only once there is a real draft — never for empty sessions.
    Integer deployRisk = 0;
    if (clarity + acceptance >= 15 || readyDraft) {
      deployRisk = 15;
      if (
        combined.contains('production')
        || combined.contains('delete')
        || combined.contains('migrate')
      ) {
        deployRisk = 5;
      }
    }

    Integer total = Math.min(100, clarity + acceptance + orgContext + testability + deployRisk);

    // Linked Copado stories should stay build-ready when a real body is present.
    if (hasLinkedStory && substantiveChars >= 80) {
      total = Math.max(total, 70);
      if (readyDraft || combined.contains('acceptance')) {
        clarity = Math.max(clarity, 20);
        acceptance = Math.max(acceptance, 18);
        orgContext = Math.max(orgContext, 16);
        testability = Math.max(testability, 8);
      }
    }

    // Full AI drafts with named sections should clear Missing Info even if
    // keyword density is low (common for Apex / non-metadata stories).
    if (readyDraft && hasAcceptanceSection) {
      acceptance = Math.max(acceptance, 18);
    }
    if (readyDraft && (hasClaritySection || hasPersona)) {
      clarity = Math.max(clarity, 18);
    }
    if (readyDraft && hasOrgSection) {
      orgContext = Math.max(orgContext, 12);
    }
    if (readyDraft && hasTestSection) {
      testability = Math.max(testability, 10);
    }
    total = Math.min(100, clarity + acceptance + orgContext + testability + deployRisk);

    StoryScore score = new StoryScore();
    score.totalScore = total;
    score.missingInfo = new List<String>();

    if (acceptance < 15 && !hasAcceptanceSection) {
      score.missingInfo.add('acceptance criteria');
    }
    if (clarity < 15 && !hasClaritySection && !hasPersona) {
      score.missingInfo.add('requirements clarity');
    }
    if (orgContext < 10 && !hasOrgSection) {
      score.missingInfo.add('org context');
    }
    if (testability < 8 && !hasTestSection) {
      score.missingInfo.add('test scenarios');
    }

    if (total >= 75) {
      score.riskLevel = 'Low';
      score.summary = 'Story is ready to create.';
    } else if (total >= 40) {
      score.riskLevel = 'Medium';
      score.summary = 'Story needs more detail before create.';
    } else {
      score.riskLevel = 'High';
      score.summary = 'Still gathering requirements.';
    }
    return score;
  }

  /** True when draft text includes an explicit story section label. */
  @TestVisible
  private static Boolean hasStorySection(String lowerText, List<String> labels) {
    if (String.isBlank(lowerText) || labels == null) {
      return false;
    }
    for (String label : labels) {
      if (String.isNotBlank(label) && lowerText.contains(label)) {
        return true;
      }
    }
    return false;
  }

  /** True when Summary holds real story body, not a one-line score blurb. */
  @TestVisible
  private static Boolean isStoryBodySummary(String text) {
    if (String.isBlank(text)) {
      return false;
    }
    String t = text.trim();
    if (t.length() < 80) {
      return false;
    }
    String lower = t.toLowerCase();
    if (
      lower == 'new builder session started.'
      || lower == 'no story draft yet.'
      || lower == 'story is ready to create.'
      || lower == 'story needs more detail before create.'
      || lower == 'still gathering requirements.'
    ) {
      return false;
    }
    return true;
  }

  /** Assistant messages that are story drafts (not clarifying Qs / status notes). */
  @TestVisible
  private static Boolean isStoryDraftMessage(String text) {
    if (String.isBlank(text) || text.trim().length() < 80) {
      return false;
    }
    String lower = text.toLowerCase();
    if (looksLikeStructuredStory(lower)) {
      return true;
    }
    if (
      lower.contains('acceptance criteria')
      || lower.contains('functional specifications')
      || lower.contains('technical specifications')
      || lower.contains('requirements clarity')
      || lower.contains('org context')
      || lower.contains('test scenarios')
      || lower.contains('proposed user story')
      || (lower.contains('as a') && (lower.contains('i want') || lower.contains('want to')))
    ) {
      return true;
    }
    return false;
  }

  /** Connection / OI / short chatter must not inflate Story Score. */
  @TestVisible
  private static Boolean isNonStoryUserChatter(String text) {
    if (String.isBlank(text)) {
      return true;
    }
    String t = text.trim().toLowerCase();
    if (t.length() < 12) {
      return true;
    }
    if (
      t.contains('org intelligence')
      || t.contains('are we connected')
      || t.contains('do you have access')
      || t.contains('can you see')
      || t.contains('can you read')
      || t.contains('governance org')
      || t.contains('connected?')
      || t.equals('huh')
      || t.equals('wtf')
      || t.equals('ok')
      || t.equals('thanks')
    ) {
      return true;
    }
    return false;
  }

  private static Boolean looksLikeStructuredStory(String text) {
    if (String.isBlank(text)) {
      return false;
    }
    Integer signals = 0;
    if (text.contains('user story') || text.contains('# user story')) {
      signals++;
    }
    if (text.contains('object') && (text.contains('field') || text.contains('api name'))) {
      signals++;
    }
    if (text.contains('field type') || text.contains('checkbox') || text.contains('picklist') || text.contains('text')) {
      signals++;
    }
    if (text.contains('page layout') || text.contains('default value') || text.contains('required')) {
      signals++;
    }
    if (text.contains('__c') || text.contains('api name')) {
      signals++;
    }
    return signals >= 3;
  }

  private static Integer scoreDimension(String text, List<String> keywords, Integer maxPoints) {
  Integer hits = 0;
  for (String keyword : keywords) {
    if (text.contains(keyword)) {
      hits++;
    }
  }
  Decimal ratio = Math.min(1, hits / (Decimal) keywords.size());
  return Integer.valueOf(Math.round(ratio * maxPoints));
  }

  private static Map<String, Object> buildStoryData(Id sessionId) {
    List<AI_Builder_Message__c> messages = [
      SELECT Message__c, Role__c
      FROM AI_Builder_Message__c
      WHERE Session__c = :sessionId
      ORDER BY CreatedDate ASC
    ];

    List<String> userMessages = new List<String>();
    List<String> assistantDrafts = new List<String>();
    for (AI_Builder_Message__c msg : messages) {
      if (msg.Role__c == 'User') {
        userMessages.add(msg.Message__c);
      } else if (msg.Role__c == 'Assistant' && String.isNotBlank(msg.Message__c)) {
        assistantDrafts.add(msg.Message__c);
      }
    }

    String draft = pickBestStoryDraft(assistantDrafts, userMessages);
    Map<String, String> parsed = parseStoryFields(draft, userMessages);

    AI_Builder_Session__c session = [
      SELECT Copado_User_Story__c
      FROM AI_Builder_Session__c
      WHERE Id = :sessionId
      LIMIT 1
    ];
    String existingRef = session.Copado_User_Story__c;

    return new Map<String, Object>{
      'title' => parsed.get('title'),
      'asA' => parsed.get('asA'),
      'wantTo' => parsed.get('wantTo'),
      'soThat' => parsed.get('soThat'),
      'acceptanceCriteria' => parsed.get('acceptanceCriteria'),
      'functionalSpecs' => parsed.get('functionalSpecs'),
      'technicalSpecs' => parsed.get('technicalSpecs'),
      'description' => draft,
      'existingStoryRef' => existingRef,
      'source' => 'Copado Builder'
    };
  }

  private static String pickBestStoryDraft(List<String> assistantDrafts, List<String> userMessages) {
    String best;
    Integer bestScore = -1;
    for (String draft : assistantDrafts) {
      if (String.isBlank(draft)) {
        continue;
      }
      Integer score = 0;
      String lower = draft.toLowerCase();
      if (lower.contains('user story')) score += 3;
      if (lower.contains('api name') || lower.contains('__c')) score += 2;
      if (lower.contains('object') && lower.contains('field')) score += 2;
      if (lower.contains('acceptance') || lower.contains('page layout')) score += 1;
      if (lower.contains('as a') && (lower.contains('i want') || lower.contains('want to'))) score += 4;
      if (looksLikeStructuredStory(lower)) score += 4;
      score += Math.min(5, draft.length() / 200);
      // Penalize clarifying question lists
      if (lower.contains('before i draft') || lower.contains('quick details') || lower.contains('could you confirm')) {
        score -= 8;
      }
      if (countQuestionLines(draft) >= 4) {
        score -= 10;
      }
      if (score > bestScore) {
        bestScore = score;
        best = draft;
      }
    }
    if (String.isNotBlank(best) && bestScore > 0) {
      return best;
    }
    return String.join(userMessages, '\n\n');
  }

  private static Integer countQuestionLines(String text) {
    Integer count = 0;
    for (String line : text.split('\n')) {
      String t = line != null ? line.trim() : '';
      if (t.contains('?') && (t.startsWith('1.') || t.startsWith('2.') || t.startsWith('**') || System.Pattern.matches('^\\d+\\..*', t))) {
        count++;
      }
    }
    return count;
  }

  /**
   * Split a drafted story into Copado US field values.
   */
  @TestVisible
  private static Map<String, String> parseStoryFields(String draft, List<String> userMessages) {
    Map<String, String> result = new Map<String, String>{
      'title' => 'Builder Story',
      'asA' => '',
      'wantTo' => '',
      'soThat' => '',
      'acceptanceCriteria' => '',
      'functionalSpecs' => '',
      'technicalSpecs' => ''
    };

    String title = extractStoryTitle(draft, userMessages);
    result.put('title', title);

    if (String.isBlank(draft)) {
      return result;
    }

    result.put('asA', extractInlineField(draft, new List<String>{
      '(?im)^\\s*as a(?:\\.\\.\\.)?\\s*:?\\s*(.+)$',
      '(?im)^\\s*\\*\\*as a\\*\\*\\s*:?\\s*(.+)$'
    }));
    result.put('wantTo', extractInlineField(draft, new List<String>{
      '(?im)^\\s*(?:i )?want to(?:\\.\\.\\.)?\\s*:?\\s*(.+)$',
      '(?im)^\\s*\\*\\*want to\\*\\*\\s*:?\\s*(.+)$'
    }));
    result.put('soThat', extractInlineField(draft, new List<String>{
      '(?im)^\\s*so that(?:\\.\\.\\.)?\\s*:?\\s*(.+)$',
      '(?im)^\\s*\\*\\*so that\\*\\*\\s*:?\\s*(.+)$'
    }));

    result.put(
      'acceptanceCriteria',
      extractSection(
        draft,
        new List<String>{'acceptance criteria', 'acceptance', 'definition of done'},
        new List<String>{
          'functional specifications', 'functional specs', 'technical specifications',
          'technical specs', 'technical details', 'field details', 'notes'
        }
      )
    );
    result.put(
      'functionalSpecs',
      extractSection(
        draft,
        new List<String>{'functional specifications', 'functional specs', 'story details', 'requirements'},
        new List<String>{
          'technical specifications', 'technical specs', 'technical details',
          'acceptance criteria', 'acceptance', 'field details'
        }
      )
    );
    result.put(
      'technicalSpecs',
      extractSection(
        draft,
        new List<String>{
          'technical specifications', 'technical specs', 'technical details',
          'field details', 'field specification', 'metadata'
        },
        new List<String>{'acceptance criteria', 'acceptance', 'notes', 'next steps'}
      )
    );

    // If no explicit technical section, use markdown tables / API Name blocks as technical
    if (String.isBlank(result.get('technicalSpecs')) && draft.contains('|') && draft.toLowerCase().contains('api name')) {
      result.put('technicalSpecs', extractTablesAndFieldSpecs(draft));
    }

    // Functional fallback: whole draft minus clarifying questions if sections missing
    if (String.isBlank(result.get('functionalSpecs'))) {
      String cleaned = draft;
      if (countQuestionLines(draft) >= 4) {
        cleaned = String.join(userMessages, '\n\n');
      }
      result.put('functionalSpecs', cleaned);
    }

    // Synthesize persona fields from title/user ask when missing
    if (String.isBlank(result.get('asA'))) {
      result.put('asA', 'a Salesforce user');
    }
    if (String.isBlank(result.get('wantTo'))) {
      result.put('wantTo', 'implement: ' + title);
    }
    if (String.isBlank(result.get('soThat'))) {
      result.put('soThat', 'the requirement from Copado Builder is delivered in the org');
    }
    if (String.isBlank(result.get('acceptanceCriteria'))) {
      result.put(
        'acceptanceCriteria',
        'Given the described requirement, when the change is implemented, then it behaves as specified in the functional and technical details.'
      );
    }

    return result;
  }

  private static String extractInlineField(String draft, List<String> patterns) {
    for (String regexPattern : patterns) {
      Matcher m = System.Pattern.compile(regexPattern).matcher(draft);
      if (m.find()) {
        String value = m.group(1).trim();
        value = value.replaceAll('\\*\\*', '').trim();
        if (String.isNotBlank(value) && value.length() < 500) {
          return value;
        }
      }
    }
    return '';
  }

  private static String extractSection(String draft, List<String> startLabels, List<String> endLabels) {
    String lower = draft.toLowerCase();
    Integer startIdx = -1;
    Integer startLabelLen = 0;
    for (String label : startLabels) {
      Integer idx = lower.indexOf(label);
      if (idx >= 0 && (startIdx < 0 || idx < startIdx)) {
        startIdx = idx;
        startLabelLen = label.length();
      }
    }
    if (startIdx < 0) {
      return '';
    }

    Integer contentStart = startIdx + startLabelLen;
    // skip trailing markdown heading punctuation on same line
    while (contentStart < draft.length()) {
      String ch = draft.substring(contentStart, contentStart + 1);
      if (ch != ':' && ch != '#' && ch != ' ' && ch != '\n' && ch != '*') {
        break;
      }
      contentStart++;
    }

    Integer endIdx = draft.length();
    for (String label : endLabels) {
      Integer idx = lower.indexOf(label, contentStart);
      if (idx > contentStart && idx < endIdx) {
        endIdx = idx;
      }
    }
    String section = draft.substring(contentStart, endIdx).trim();
    section = section.replaceAll('(?m)^#+\\s*', '').trim();
    return section;
  }

  private static String extractTablesAndFieldSpecs(String draft) {
    List<String> chunks = new List<String>();
    for (String line : draft.split('\n')) {
      String t = line != null ? line.trim() : '';
      String lower = t.toLowerCase();
      if (t.startsWith('|') || lower.contains('api name') || lower.contains('field type') || lower.contains('object:') || lower.contains('page layout')) {
        chunks.add(t);
      }
    }
    return String.join(chunks, '\n');
  }

  private static String extractStoryTitle(String draft, List<String> userMessages) {
    if (String.isNotBlank(draft)) {
      Matcher m = System.Pattern.compile('(?im)^\\s*#?\\s*user story\\s*:\\s*(.+)$').matcher(draft);
      if (m.find()) {
        String titled = m.group(1).trim().replaceAll('\\*\\*', '');
        if (String.isNotBlank(titled) && !isBadTitle(titled)) {
          return titled.length() > 80 ? titled.substring(0, 80) + '...' : titled;
        }
      }

      if (looksLikeStructuredStory(draft.toLowerCase())) {
        for (String line : draft.split('\n')) {
          String clean = line != null ? line.trim() : '';
          if (String.isBlank(clean)) continue;
          if (clean.startsWith('#')) {
            clean = clean.replaceFirst('^#+\\s*', '');
          }
          String lower = clean.toLowerCase();
          if (lower.startsWith('user story')) {
            clean = clean.replaceFirst('(?i)^user story\\s*:?\\s*', '').trim();
          }
          if (clean.length() > 8 && !isBadTitle(clean) && !clean.startsWith('|')) {
            return clean.length() > 80 ? clean.substring(0, 80) + '...' : clean;
          }
        }
      }
    }

    if (!userMessages.isEmpty() && String.isNotBlank(userMessages[0]) && !isBadTitle(userMessages[0])) {
      String first = userMessages[0].trim();
      return first.length() > 80 ? first.substring(0, 80) + '...' : first;
    }
    return 'Builder Story';
  }

  private static Boolean isBadTitle(String value) {
    if (String.isBlank(value)) return true;
    String lower = value.toLowerCase().trim();
    return lower.startsWith('happy to help')
      || lower.startsWith('before i')
      || lower.startsWith('could you')
      || lower.startsWith('1.')
      || lower.startsWith('field type')
      || lower.contains('should "')
      || lower.contains('?');
  }

  private static CopadoAiApiService.OrgInfo findSafeDevOrg(String orgId) {
    return CopadoDevopsService.findNonProductionOrg(orgId);
  }

  private static String deriveBuildStatus(String status) {
  if (status == 'Code Built' || status == 'Reviewed' || status == 'Tests Created' || status == 'Deployed' || status == 'Complete') {
    return 'Successful';
  }
  if (status == 'Story Created') {
    return 'Ready';
  }
  return 'Not ready';
  }

  private static String deriveTestStatus(String status) {
  if (status == 'Tests Created' || status == 'Deployed' || status == 'Complete') {
    return 'Successful';
  }
  if (status == 'Reviewed') {
    return 'Ready';
  }
  return 'Not ready';
  }

  private static String deriveDeployStatus(String status) {
  if (status == 'Deployed' || status == 'Complete') {
    return 'Successful';
  }
  if (status == 'Tests Created') {
    return 'Ready';
  }
  return 'Not ready';
  }

  private static List<MessageDto> getMessages(Id sessionId) {
  List<MessageDto> dtos = new List<MessageDto>();
  for (AI_Builder_Message__c msg : [
    SELECT Role__c, Message__c, Step__c, CreatedDate
    FROM AI_Builder_Message__c
    WHERE Session__c = :sessionId
    ORDER BY CreatedDate ASC
  ]) {
    MessageDto dto = new MessageDto();
    dto.role = msg.Role__c;
    dto.message = msg.Message__c;
    dto.step = msg.Step__c;
    dto.createdDate = msg.CreatedDate;
    dtos.add(dto);
  }
  return dtos;
  }

  private static String agentLabel(String assistantId) {
    if (assistantId == CopadoAiApiService.ASSISTANT_BUILD) return 'Build Agent';
    if (assistantId == CopadoAiApiService.ASSISTANT_PLAN) return 'Plan Agent';
    if (assistantId == CopadoAiApiService.ASSISTANT_TEST) return 'Test Agent';
    if (assistantId == CopadoAiApiService.ASSISTANT_RELEASE) return 'Release Agent';
    if (assistantId == CopadoAiApiService.ASSISTANT_OPERATE) return 'Operate Agent';
    if (assistantId == CopadoAiApiService.ASSISTANT_KNOWLEDGE) return 'Copado Expert';
    return 'Copado AI';
  }

  private static void insertMessage(Id sessionId, String role, String message, String step) {
  insert new AI_Builder_Message__c(
    Session__c = sessionId,
    Role__c = role,
    Message__c = message,
    Step__c = step
  );
  }

  private static AI_Builder_Action__c logAction(
  Id sessionId,
  String actionType,
  String status,
  String request,
  String response,
  String errorMessage
  ) {
  // Never fail the main workflow because of audit logging / picklist drift.
  try {
    AI_Builder_Action__c action = new AI_Builder_Action__c(
      Session__c = sessionId,
      Action_Type__c = normalizeActionType(actionType),
      Status__c = status,
      Request__c = request,
      Response__c = response,
      Error__c = errorMessage
    );
    insert action;
    return action;
  } catch (Exception ex) {
    System.debug(LoggingLevel.WARN, 'logAction skipped: ' + ex.getMessage());
    return null;
  }
  }

  private static String normalizeActionType(String actionType) {
    if (String.isBlank(actionType)) {
      return 'Build Code';
    }
    // Map UI labels to restricted picklist values.
    if (actionType == 'Build') {
      return 'Build Code';
    }
    if (actionType == 'Commit' || actionType == 'Deploy + Commit' || actionType == 'Commit from Dev') {
      return 'Commit';
    }
    return actionType;
  }

  private static AI_Builder_Session__c loadSession(Id sessionId) {
  return [
    SELECT Id, Name, Status__c, Current_Step__c, Copado_User_Story__c,
      Selected_Org__c, Score__c, Risk_Level__c, Summary__c,
      Workspace_Id__c, Dialogue_Id__c,
      Story_Record_Id__c, Story_Name__c, Story_Title__c,
      Last_Build_Id__c, Last_Job_Id__c, Artifact_Content_Document_Id__c,
      Last_Deploy_Job_Id__c, Last_Commit_Job_Id__c, Last_Job_Action__c,
      Last_Promotion_Id__c,
      Build_Package_Json__c,
      Org_Context_Status__c, Org_Intelligence_Integration_Id__c, Org_Credential_Id__c
    FROM AI_Builder_Session__c
    WHERE Id = :sessionId
    LIMIT 1
  ];
  }

  private class OrgContextSnapshot {
    String status;
    String integrationId;
  }

  private static String resolveSessionOrgCredentialId(
    AI_Builder_Session__c session,
    StoryRef story
  ) {
    if (String.isNotBlank(session.Org_Credential_Id__c)) {
      return session.Org_Credential_Id__c;
    }
    if (story.recordId != null) {
      String envId = CopadoDevopsService.getUserStoryEnvironmentId(story.recordId);
      return CopadoDevopsService.resolveOrgCredentialId(envId);
    }
    return null;
  }

  private static String formatOrgContextStatus(CopadoAiApiService.OrgIntelligenceResult probe) {
    if (probe == null) {
      return 'Not connected';
    }
    // Require verified credential bind — cicd "connected" alone is not enough.
    if (probe.success == true && probe.credentialBound != false) {
      return 'Connected';
    }
    if (probe.credentialBound == false && String.isNotBlank(probe.status)) {
      return probe.status;
    }
    return String.isNotBlank(probe.status) ? probe.status : 'Not connected';
  }

  private static OrgContextSnapshot resolveOrgContextSnapshot(
    AI_Builder_Session__c session,
    String orgCredentialId
  ) {
    OrgContextSnapshot snapshot = new OrgContextSnapshot();
    snapshot.status = 'Not connected';
    snapshot.integrationId = session.Org_Intelligence_Integration_Id__c;

    // Trust session fields written by ensureOrgIntelligenceReady / Connect.
    // Do not call Copado AI on every getSessionState (send/poll would blow callout limits).
    if (
      'Connected'.equalsIgnoreCase(session.Org_Context_Status__c)
      && String.isNotBlank(session.Org_Intelligence_Integration_Id__c)
    ) {
      if (
        String.isBlank(orgCredentialId)
        || String.isBlank(session.Org_Credential_Id__c)
        || orgCredentialId.equals(session.Org_Credential_Id__c)
      ) {
        snapshot.status = 'Connected';
        snapshot.integrationId = session.Org_Intelligence_Integration_Id__c;
        return snapshot;
      }
    }

    if (String.isNotBlank(session.Org_Context_Status__c)
      && (
        String.isBlank(orgCredentialId)
        || orgCredentialId.equals(session.Org_Credential_Id__c)
      )) {
      snapshot.status = session.Org_Context_Status__c;
      snapshot.integrationId = session.Org_Intelligence_Integration_Id__c;
    }
    return snapshot;
  }

  private static void applyStoryLink(
    AI_Builder_Session__c session,
    String recordId,
    String storyName,
    String storyTitle
  ) {
    Id parsedId = null;
    if (String.isNotBlank(recordId)) {
      try {
        parsedId = (Id) recordId;
      } catch (Exception ignore) {
      }
    }
    applyStoryLink(session, parsedId, storyName, storyTitle);
  }

  private static void applyStoryLink(
    AI_Builder_Session__c session,
    Id recordId,
    String storyName,
    String storyTitle
  ) {
    if (recordId != null) {
      session.Story_Record_Id__c = String.valueOf(recordId);
    }
    if (String.isNotBlank(storyName)) {
      session.Story_Name__c = storyName.length() > 80 ? storyName.substring(0, 80) : storyName;
    }
    if (String.isNotBlank(storyTitle)) {
      session.Story_Title__c = storyTitle.length() > 255 ? storyTitle.substring(0, 255) : storyTitle;
    }
    String link;
    if (recordId != null) {
      link = String.valueOf(recordId) + '||'
        + (String.isNotBlank(storyName) ? storyName : '')
        + '||'
        + (String.isNotBlank(storyTitle) ? storyTitle : '');
    } else {
      link = (String.isNotBlank(storyName) ? storyName : 'US')
        + '||'
        + (String.isNotBlank(storyTitle) ? storyTitle : '');
    }
    session.Copado_User_Story__c = link.length() > 255 ? link.substring(0, 255) : link;
    if (String.isNotBlank(storyName)) {
      session.Name = formatSessionDisplayName(storyName, storyTitle);
    }
  }

  private static String formatSessionDisplayName(String storyName, String storyTitle) {
    if (String.isBlank(storyName)) {
      return 'Builder Chat';
    }
    String label = storyName;
    if (String.isNotBlank(storyTitle)) {
      label += ' — ' + storyTitle;
    }
    return label.length() > 80 ? label.substring(0, 80) : label;
  }

  private static StoryRef resolveStoryRef(AI_Builder_Session__c session) {
    StoryRef ref = new StoryRef();
    if (session == null) {
      return ref;
    }
    if (String.isNotBlank(session.Story_Record_Id__c)) {
      try {
        ref.recordId = (Id) session.Story_Record_Id__c;
      } catch (Exception ignore) {
      }
    }
    ref.name = session.Story_Name__c;
    ref.title = session.Story_Title__c;

    if (String.isNotBlank(session.Copado_User_Story__c) && session.Copado_User_Story__c.contains('||')) {
      List<String> parts = session.Copado_User_Story__c.split('\\|\\|');
      if (parts.size() >= 3) {
        if (ref.recordId == null) {
          try {
            ref.recordId = (Id) parts[0];
          } catch (Exception ignore) {
          }
        }
        if (String.isBlank(ref.name)) {
          ref.name = parts[1];
        }
        if (String.isBlank(ref.title)) {
          ref.title = parts[2];
        }
      } else if (parts.size() == 2) {
        // mock style: Name||Title OR Id||Name
        try {
          if (ref.recordId == null && (parts[0].length() == 15 || parts[0].length() == 18)) {
            ref.recordId = (Id) parts[0];
            if (String.isBlank(ref.name)) {
              ref.name = parts[1];
            }
          } else {
            if (String.isBlank(ref.name)) {
              ref.name = parts[0];
            }
            if (String.isBlank(ref.title)) {
              ref.title = parts[1];
            }
          }
        } catch (Exception ignore) {
          if (String.isBlank(ref.name)) {
            ref.name = parts[0];
          }
          if (String.isBlank(ref.title)) {
            ref.title = parts[1];
          }
        }
      }
    }
    return ref;
  }

  private static String formatStoryRef(StoryRef story) {
    if (story == null) {
      return '';
    }
    if (String.isNotBlank(story.name) && String.isNotBlank(story.title)) {
      return story.name + ' — ' + story.title;
    }
    if (String.isNotBlank(story.name)) {
      return story.name;
    }
    return story.recordId != null ? String.valueOf(story.recordId) : '';
  }

  /**
   * Compact context for Build: prefer Copado User Story fields only.
   * Avoid dumping the full chat transcript (slow + encourages tool loops).
   * Cap is large enough for long picklist value lists (30+ values).
   */
  private static final Integer BUILD_CONTEXT_MAX_CHARS = 12000;

  private static String buildLeanBuildContext(Id sessionId, AI_Builder_Session__c session) {
    List<String> lines = new List<String>();
    StoryRef linked = resolveStoryRef(session);
    if (linked.recordId != null) {
      CopadoDevopsService.UserStoryContext live =
        CopadoDevopsService.getUserStoryContext(linked.recordId);
      if (live != null && String.isNotBlank(live.summaryText)) {
        lines.add(live.summaryText);
      }
    }
    if (lines.isEmpty()
      && session != null
      && isStoryBodySummary(session.Summary__c)) {
      lines.add(session.Summary__c);
    }
    // Fallback: last structured assistant draft only (not full history).
    if (lines.isEmpty()) {
      for (AI_Builder_Message__c msg : [
        SELECT Message__c
        FROM AI_Builder_Message__c
        WHERE Session__c = :sessionId
          AND Role__c = 'Assistant'
        ORDER BY CreatedDate DESC
        LIMIT 5
      ]) {
        if (isStoryDraftMessage(msg.Message__c)) {
          lines.add(msg.Message__c);
          break;
        }
      }
    }
    if (lines.isEmpty() && session != null && String.isNotBlank(session.Summary__c)) {
      lines.add(session.Summary__c);
    }

    // Build package generation uses a FRESH dialogue with no Org Intelligence tools.
    // Inject any live Metadata API fullNames already discovered in this chat so the
    // model (and post-process) do not invent Account-Account Layout / wrong names.
    Map<String, List<String>> liveByType = extractLiveMetadataFromSession(sessionId, session);
    String authBlock = CopadoDevopsService.formatAuthoritativeLiveMetadataBlock(liveByType);
    if (String.isNotBlank(authBlock)) {
      lines.add('');
      lines.add(authBlock);
    }

    return truncateForLongText(String.join(lines, '\n'), BUILD_CONTEXT_MAX_CHARS);
  }


  private static Boolean isLayoutResolveQuestion(String message) {
    if (String.isBlank(message)) {
      return false;
    }
    String m = message.toLowerCase();
    Boolean asksLayout = m.contains('layout');
    Boolean asksAction = m.contains('pull')
      || m.contains('update')
      || m.contains('fix')
      || m.contains('resolve')
      || m.contains('actual')
      || m.contains('real')
      || m.contains('live')
      || m.contains('correct')
      || m.contains('artifact');
    return asksLayout && asksAction;
  }

  /**
   * Bind OI to the session Dev org and ask for live Layout fullNames for objects
   * referenced by the package / story (e.g. Account → Account-Formato de cuentas).
   */
  private static List<String> resolveLiveLayoutsViaOrgIntelligence(
    AI_Builder_Session__c session,
    String workspaceId,
    String dialogueId,
    String storyContext,
    String packageJson
  ) {
    Map<String, List<String>> byType = resolveLiveMetadataViaOrgIntelligence(
      session,
      workspaceId,
      dialogueId,
      storyContext,
      packageJson
    );
    if (byType != null && byType.containsKey('Layout') && byType.get('Layout') != null) {
      return byType.get('Layout');
    }
    return new List<String>();
  }

  /**
   * Bind OI to the session Dev org and list live Metadata API fullNames for types
   * inferred from the story / package (Layout, Flow, Profile, CustomField, …).
   */
  private static Map<String, List<String>> resolveLiveMetadataViaOrgIntelligence(
    AI_Builder_Session__c session,
    String workspaceId,
    String dialogueId,
    String storyContext,
    String packageJson
  ) {
    Map<String, List<String>> empty = new Map<String, List<String>>();
    if (session == null) {
      return empty;
    }
    String integrationId = session.Org_Intelligence_Integration_Id__c;
    String orgCred = session.Org_Credential_Id__c;
    String orgLabel = session.Selected_Org__c;
    // Mock mode still returns deterministic fullNames for Build/package gates.
    if (!CopadoAiApiService.isMockMode()
      && (String.isBlank(integrationId) || String.isBlank(orgCred))) {
      return empty;
    }
    if (CopadoAiApiService.isMockMode() && String.isBlank(orgCred)) {
      orgCred = 'mock-org-cred';
    }
    if (CopadoAiApiService.isMockMode() && String.isBlank(integrationId)) {
      integrationId = 'mock-integration';
    }
    String resolved = CopadoDevopsService.resolveOrgCredentialId(orgCred);
    if (String.isNotBlank(resolved)) {
      orgCred = resolved;
    }
    CopadoAiApiService.OrgInfo orgInfo = CopadoDevopsService.findOrgCredentialById(orgCred);
    if (orgInfo != null && String.isNotBlank(orgInfo.orgName)) {
      orgLabel = orgInfo.orgName;
    }
    List<CopadoAiApiService.MetadataListRequest> reqs =
      inferMetadataListRequests(storyContext, packageJson);
    if (reqs.isEmpty()) {
      // Default: Layout for Account so field+layout stories still resolve.
      CopadoAiApiService.MetadataListRequest layoutReq =
        new CopadoAiApiService.MetadataListRequest('Layout', 'Account');
      layoutReq.namePrefix = 'Account-';
      reqs.add(layoutReq);
    }
    String dlg = dialogueId;
    String ws = workspaceId;
    if (String.isBlank(ws)) {
      ws = session.Workspace_Id__c;
    }
    if (String.isBlank(dlg)) {
      dlg = session.Dialogue_Id__c;
    }
    if (String.isBlank(dlg) && String.isNotBlank(ws)) {
      CopadoAiApiService.DialogueResult created = CopadoAiApiService.createDialogue(
        ws,
        'Metadata resolve ' + Datetime.now().getTime()
      );
      if (created != null) {
        dlg = created.dialogueId;
      }
    }
    return CopadoAiApiService.requestLiveMetadataFullNames(
      dlg,
      ws,
      integrationId,
      orgCred,
      orgLabel,
      reqs
    );
  }

  @TestVisible
  private static List<String> inferObjectsForLayoutResolve(
    String storyContext,
    String packageJson
  ) {
    return inferObjectApisForMetadata(storyContext, packageJson);
  }

  /**
   * Infer Metadata API list requests from story text + package paths.
   * Child types are scoped to discovered objects; Layout uses object prefixes.
   */
  @TestVisible
  private static List<CopadoAiApiService.MetadataListRequest> inferMetadataListRequests(
    String storyContext,
    String packageJson
  ) {
    List<CopadoAiApiService.MetadataListRequest> reqs =
      new List<CopadoAiApiService.MetadataListRequest>();
    Set<String> typeKeys = new Set<String>();
    String contextText =
      (String.isNotBlank(storyContext) ? storyContext : '')
      + '\n'
      + (String.isNotBlank(packageJson) ? packageJson : '');
    String lower = contextText.toLowerCase();
    List<String> objects = inferObjectApisForMetadata(storyContext, packageJson);

    // Path-driven types
    for (String path : extractArtifactPaths(packageJson)) {
      if (String.isBlank(path)) {
        continue;
      }
      String p = path.replace('\\', '/').toLowerCase();
      if (p.contains('/layouts/')) {
        typeKeys.add('Layout');
      } else if (p.contains('/objects/') && p.endsWith('.field-meta.xml')) {
        typeKeys.add('CustomField');
      } else if (p.contains('/objects/') && p.endsWith('.validationrule-meta.xml')) {
        typeKeys.add('ValidationRule');
      } else if (p.contains('/objects/') && p.endsWith('.recordtype-meta.xml')) {
        typeKeys.add('RecordType');
      } else if (p.contains('/objects/')
        && (p.endsWith('.object-meta.xml') || p.endsWith('.object'))) {
        typeKeys.add('CustomObject');
      } else if (p.contains('/flows/')) {
        typeKeys.add('Flow');
      } else if (p.contains('/flexipages/')) {
        typeKeys.add('FlexiPage');
      } else if (p.contains('/profiles/')) {
        typeKeys.add('Profile');
      } else if (p.contains('/permissionsets/')) {
        typeKeys.add('PermissionSet');
      } else if (p.contains('/classes/') && p.endsWith('.cls')) {
        typeKeys.add('ApexClass');
      } else if (p.contains('/triggers/') && p.endsWith('.trigger')) {
        typeKeys.add('ApexTrigger');
      } else if (p.contains('/lwc/') || p.contains('/aura/')) {
        typeKeys.add('LightningComponentBundle');
      } else if (p.contains('/email/')) {
        typeKeys.add('EmailTemplate');
      } else if (p.contains('/reports/')) {
        typeKeys.add('Report');
      } else if (p.contains('/dashboards/')) {
        typeKeys.add('Dashboard');
      } else if (p.contains('/documents/')) {
        typeKeys.add('Document');
      }
    }

    // Story-keyword types
    if (containsAnyToken(lower, new List<String>{
      'layout', 'page layout', 'formato'
    })) {
      typeKeys.add('Layout');
    }
    if (containsAnyToken(lower, new List<String>{
      'custom field', 'field on', 'new field', '__c', 'picklist'
    })) {
      typeKeys.add('CustomField');
    }
    if (containsAnyToken(lower, new List<String>{ 'custom object', 'new object' })) {
      typeKeys.add('CustomObject');
    }
    if (containsAnyToken(lower, new List<String>{ 'flow', 'record-triggered', 'screen flow' })) {
      typeKeys.add('Flow');
    }
    if (containsAnyToken(lower, new List<String>{
      'flexipage', 'lightning page', 'app page', 'record page', 'home page'
    })) {
      typeKeys.add('FlexiPage');
    }
    if (containsAnyToken(lower, new List<String>{ 'profile', 'fls', 'field level security' })) {
      typeKeys.add('Profile');
    }
    if (containsAnyToken(lower, new List<String>{ 'permission set', 'permissionset' })) {
      typeKeys.add('PermissionSet');
    }
    if (containsAnyToken(lower, new List<String>{ 'apex class', 'apexclass', 'apex ' })) {
      typeKeys.add('ApexClass');
    }
    if (containsAnyToken(lower, new List<String>{ 'trigger' })) {
      typeKeys.add('ApexTrigger');
    }
    if (containsAnyToken(lower, new List<String>{ 'record type', 'recordtype' })) {
      typeKeys.add('RecordType');
    }
    if (containsAnyToken(lower, new List<String>{ 'validation rule', 'validationrule' })) {
      typeKeys.add('ValidationRule');
    }
    if (containsAnyToken(lower, new List<String>{ 'lwc', 'lightning web component', 'aura component' })) {
      typeKeys.add('LightningComponentBundle');
    }
    if (containsAnyToken(lower, new List<String>{ 'email template' })) {
      typeKeys.add('EmailTemplate');
    }
    if (containsAnyToken(lower, new List<String>{ ' report', 'reports' })) {
      typeKeys.add('Report');
    }
    if (containsAnyToken(lower, new List<String>{ 'dashboard' })) {
      typeKeys.add('Dashboard');
    }

    // Field+layout stories: ensure Layout + CustomField when objects are known
    if (!objects.isEmpty()
      && (typeKeys.contains('CustomField') || typeKeys.contains('Layout')
        || lower.contains('field'))) {
      typeKeys.add('Layout');
      typeKeys.add('CustomField');
    }

    Set<String> childTypes = new Set<String>{
      'CustomField', 'RecordType', 'ValidationRule', 'FieldSet', 'ListView',
      'CompactLayout', 'WebLink'
    };
    Set<String> folderedTypes = new Set<String>{
      'EmailTemplate', 'Report', 'Dashboard', 'Document'
    };

    for (String t : typeKeys) {
      if (childTypes.contains(t) || 'Layout'.equals(t)) {
        if (objects.isEmpty() && 'Layout'.equals(t)) {
          CopadoAiApiService.MetadataListRequest req =
            new CopadoAiApiService.MetadataListRequest('Layout', 'Account');
          req.namePrefix = 'Account-';
          reqs.add(req);
          continue;
        }
        for (String obj : objects) {
          CopadoAiApiService.MetadataListRequest req =
            new CopadoAiApiService.MetadataListRequest(t, obj);
          if ('Layout'.equals(t)) {
            req.namePrefix = obj + '-';
          }
          reqs.add(req);
        }
      } else if (folderedTypes.contains(t)) {
        // Folder unknown at infer time — agent returns Folder/Item fullNames.
        reqs.add(new CopadoAiApiService.MetadataListRequest(t));
      } else {
        reqs.add(new CopadoAiApiService.MetadataListRequest(t));
      }
    }
    return reqs;
  }

  @TestVisible
  private static List<String> inferObjectApisForMetadata(
    String storyContext,
    String packageJson
  ) {
    Set<String> objs = new Set<String>();
    String contextText =
      (String.isNotBlank(storyContext) ? storyContext : '')
      + '\n'
      + (String.isNotBlank(packageJson) ? packageJson : '');
    for (String path : extractArtifactPaths(packageJson)) {
      if (String.isBlank(path)) {
        continue;
      }
      if (path.contains('/layouts/')) {
        String base = path.substring(path.lastIndexOf('/') + 1);
        if (base.contains('-')) {
          objs.add(base.substring(0, base.indexOf('-')));
        }
      }
      Integer objIdx = path.indexOf('/objects/');
      if (objIdx >= 0) {
        String rest = path.substring(objIdx + '/objects/'.length());
        Integer slash = rest.indexOf('/');
        if (slash > 0) {
          objs.add(rest.substring(0, slash));
        } else if (rest.contains('.')) {
          objs.add(rest.substring(0, rest.indexOf('.')));
        }
      }
    }
    // Standard + custom object API names mentioned in prose / specs
    Pattern objPat = Pattern.compile(
      '\\b([A-Z][A-Za-z0-9_]{2,40}__(?:c|mdt|e)|Account|Contact|Lead|Opportunity|Case|User|Campaign|Product2|Order|Contract|Asset|Task|Event)\\b'
    );
    Matcher m = objPat.matcher(contextText);
    while (m.find()) {
      objs.add(m.group(1));
    }
    // Object.Field__c references
    Pattern fieldPat = Pattern.compile(
      '\\b([A-Za-z][A-Za-z0-9_]{1,40})\\.[A-Za-z][A-Za-z0-9_]{1,40}__(?:c|pc)\\b'
    );
    Matcher fm = fieldPat.matcher(contextText);
    while (fm.find()) {
      objs.add(fm.group(1));
    }
    return new List<String>(objs);
  }

  private static Boolean containsAnyToken(String haystack, List<String> tokens) {
    if (String.isBlank(haystack) || tokens == null) {
      return false;
    }
    for (String token : tokens) {
      if (String.isNotBlank(token) && haystack.contains(token)) {
        return true;
      }
    }
    return false;
  }

  /**
   * When package has custom fields but no layout file, add a layout path for the
   * preferred live fullName and a minimal layout XML that includes each new __c field.
   */
  @TestVisible
  private static String ensurePackageHasLiveLayouts(
    String packageJson,
    List<String> liveLayouts
  ) {
    if (String.isBlank(packageJson) || liveLayouts == null || liveLayouts.isEmpty()) {
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
    Map<String, String> preferred = new Map<String, String>();
    for (String name : liveLayouts) {
      if (String.isBlank(name) || !name.contains('-')) {
        continue;
      }
      String objectApi = name.substring(0, name.indexOf('-'));
      if (!preferred.containsKey(objectApi)) {
        preferred.put(objectApi, name);
      }
    }
    Set<String> objectsWithLayout = new Set<String>();
    Map<String, List<String>> fieldsByObject = new Map<String, List<String>>();
    for (Object item : rawFiles) {
      if (!(item instanceof Map<String, Object>)) {
        continue;
      }
      Map<String, Object> fileMap = (Map<String, Object>) item;
      String path = fileMap.get('path') != null ? String.valueOf(fileMap.get('path')) : '';
      if (path.contains('/layouts/')) {
        String base = path.substring(path.lastIndexOf('/') + 1);
        if (base.contains('-')) {
          objectsWithLayout.add(base.substring(0, base.indexOf('-')));
        }
      }
      if (path.contains('/objects/') && path.contains('/fields/') && path.endsWith('.field-meta.xml')) {
        Integer objIdx = path.indexOf('/objects/') + '/objects/'.length();
        Integer slash = path.indexOf('/', objIdx);
        if (slash > objIdx) {
          String objectApi = path.substring(objIdx, slash);
          String fileName = path.substring(path.lastIndexOf('/') + 1);
          String fieldApi = fileName.replace('.field-meta.xml', '');
          if (!fieldsByObject.containsKey(objectApi)) {
            fieldsByObject.put(objectApi, new List<String>());
          }
          fieldsByObject.get(objectApi).add(fieldApi);
        }
      }
    }
    Boolean changed = false;
    List<Map<String, Object>> files = new List<Map<String, Object>>();
    for (Object item : rawFiles) {
      if (item instanceof Map<String, Object>) {
        files.add((Map<String, Object>) item);
      }
    }
    for (String objectApi : preferred.keySet()) {
      if (objectsWithLayout.contains(objectApi)) {
        continue;
      }
      List<String> fields = fieldsByObject.get(objectApi);
      if (fields == null || fields.isEmpty()) {
        continue;
      }
      String layoutName = preferred.get(objectApi);
      String layoutPath =
        'force-app/main/default/layouts/' + layoutName + '.layout-meta.xml';
      String items = '';
      for (String fieldApi : fields) {
        items +=
          '\\n            <layoutItems>\\n'
          + '                <behavior>Edit</behavior>\\n'
          + '                <field>'
          + fieldApi
          + '</field>\\n'
          + '            </layoutItems>';
      }
      String xml =
        '<?xml version="1.0" encoding="UTF-8"?>\\n'
        + '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">\\n'
        + '    <layoutSections>\\n'
        + '        <customLabel>false</customLabel>\\n'
        + '        <detailHeading>false</detailHeading>\\n'
        + '        <editHeading>true</editHeading>\\n'
        + '        <label>Information</label>\\n'
        + '        <layoutColumns>\\n'
        + '            <layoutItems>\\n'
        + '                <behavior>Required</behavior>\\n'
        + '                <field>Name</field>\\n'
        + '            </layoutItems>'
        + items
        + '\\n        </layoutColumns>\\n'
        + '        <layoutColumns/>\\n'
        + '        <style>TwoColumnsTopToBottom</style>\\n'
        + '    </layoutSections>\\n'
        + '</Layout>';
      files.add(
        new Map<String, Object>{
          'path' => layoutPath,
          'content' => xml.replace('\\n', '\n')
        }
      );
      changed = true;
    }
    if (!changed) {
      return packageJson;
    }
    root.put('files', files);
    return JSON.serialize(root);
  }


  /**
   * Pull Layout fullNames mentioned in recent chat / story text for Build context.
   */
  private static List<String> extractLiveLayoutsFromSession(
    Id sessionId,
    AI_Builder_Session__c session
  ) {
    Map<String, List<String>> byType = extractLiveMetadataFromSession(sessionId, session);
    if (byType != null && byType.containsKey('Layout') && byType.get('Layout') != null) {
      return byType.get('Layout');
    }
    return new List<String>();
  }

  /**
   * Pull typed AUTHORITATIVE LIVE METADATA from recent chat / story text.
   */
  @TestVisible
  private static Map<String, List<String>> extractLiveMetadataFromSession(
    Id sessionId,
    AI_Builder_Session__c session
  ) {
    List<String> chunks = new List<String>();
    if (session != null && String.isNotBlank(session.Summary__c)) {
      chunks.add(session.Summary__c);
    }
    if (session != null && String.isNotBlank(session.Build_Package_Json__c)) {
      chunks.add(session.Build_Package_Json__c);
    }
    try {
      for (AI_Builder_Message__c msg : [
        SELECT Message__c
        FROM AI_Builder_Message__c
        WHERE Session__c = :sessionId
          AND Role__c IN ('User', 'Assistant', 'System')
        ORDER BY CreatedDate DESC
        LIMIT 30
      ]) {
        if (String.isNotBlank(msg.Message__c)) {
          chunks.add(msg.Message__c);
        }
      }
    } catch (Exception ignore) {
    }
    return CopadoDevopsService.extractAuthoritativeLiveMetadata(String.join(chunks, '\n'));
  }

  private static String buildStoryContext(Id sessionId, AI_Builder_Session__c session) {
    List<String> lines = new List<String>();
    // Prefer live Copado User Story fields when a story is linked.
    StoryRef linked = resolveStoryRef(session);
    if (linked.recordId != null) {
      CopadoDevopsService.UserStoryContext live =
        CopadoDevopsService.getUserStoryContext(linked.recordId);
      if (live != null && String.isNotBlank(live.summaryText)) {
        lines.add(live.summaryText);
      }
    }
    if (session != null && String.isNotBlank(session.Summary__c)) {
      // Avoid duplicating the same imported summary.
      if (lines.isEmpty() || !lines[0].equals(session.Summary__c)) {
        lines.add(session.Summary__c);
      }
    }
    for (AI_Builder_Message__c msg : [
      SELECT Role__c, Message__c
      FROM AI_Builder_Message__c
      WHERE Session__c = :sessionId
        AND Role__c IN ('User', 'Assistant')
      ORDER BY CreatedDate DESC
      LIMIT 12
    ]) {
      lines.add(msg.Role__c + ': ' + msg.Message__c);
    }
    return String.join(lines, '\n');
  }

  private static Id storePackageArtifact(Id sessionId, String buildId, String packageJson) {
    if (String.isBlank(packageJson)) {
      return null;
    }
    try {
      ContentVersion cv = new ContentVersion();
      cv.Title = 'CopadoBuilder-Package-' + (String.isNotBlank(buildId) ? buildId : String.valueOf(sessionId));
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
      linkContentToSession(created.ContentDocumentId, sessionId);
      return created.ContentDocumentId;
    } catch (Exception ignore) {
      return null;
    }
  }

  private static void linkContentToSession(Id contentDocumentId, Id sessionId) {
    if (contentDocumentId == null || sessionId == null) {
      return;
    }
    try {
      List<ContentDocumentLink> existing = [
        SELECT Id
        FROM ContentDocumentLink
        WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :sessionId
        LIMIT 1
      ];
      if (existing.isEmpty()) {
        insert new ContentDocumentLink(
          ContentDocumentId = contentDocumentId,
          LinkedEntityId = sessionId,
          ShareType = 'V',
          Visibility = 'AllUsers'
        );
      }
    } catch (Exception ignore) {
    }
  }

  private static List<String> extractArtifactPaths(String packageJson) {
    List<String> paths = new List<String>();
    if (String.isBlank(packageJson) || packageJson.contains('_pendingBuild')) {
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

  private static String truncateForLongText(String value, Integer maxLen) {
    if (String.isBlank(value) || value.length() <= maxLen) {
      return value;
    }
    return value.substring(0, maxLen);
  }

  private static String formatStoryLink(String ref) {
    if (String.isBlank(ref)) {
      return ref;
    }
    if (ref.contains('||')) {
      List<String> parts = ref.split('\\|\\|');
      if (parts.size() >= 3) {
        return parts[1] + ' — ' + parts[2];
      }
      if (parts.size() == 2) {
        return parts[0] + ' — ' + parts[1];
      }
    }
    return ref;
  }

  private static String getCurrentStep(Id sessionId) {
  return loadSession(sessionId).Current_Step__c;
  }

  private static String formatException(Exception ex) {
    if (ex == null) {
      return 'Unknown error';
    }
    String msg = ex.getMessage();
    if (String.isBlank(msg) || msg == 'Script-thrown exception') {
      msg = ex.getTypeName();
      if (ex.getCause() != null && String.isNotBlank(ex.getCause().getMessage())) {
        msg += ': ' + ex.getCause().getMessage();
      }
    }
    return msg;
  }

  private static void validateSessionId(Id sessionId) {
  if (sessionId == null) {
    throw new AuraHandledException('Session is required.');
  }
  }

  /**
   * After Deploy/Commit/Validate start: never throw back to LWC.
   * Heavy getSessionState often hits SOQL/CPU limits right after Copado JE creation,
   * which surfaces as "Internal server error" and can roll back session job ids.
   * @param jobJustStarted when true, treat Last_Job_Id as In Progress without querying JE.
   */
  private static SessionState safeSessionAfterAction(Id sessionId, Boolean jobJustStarted) {
    try {
      if (jobJustStarted == true) {
        return buildLightSessionState(sessionId, true);
      }
      return getSessionState(sessionId);
    } catch (Exception ex) {
      System.debug(LoggingLevel.ERROR, 'safeSessionAfterAction: ' + formatException(ex));
      try {
        return buildLightSessionState(sessionId, jobJustStarted == true);
      } catch (Exception ignore) {
        SessionState bare = new SessionState();
        bare.sessionId = sessionId;
        bare.builderCodeVersion = CopadoDevopsService.BUILDER_CODE_VERSION;
        bare.lastJobSummary =
          'Session refresh deferred — use the refresh icon next to the running job.';
        return bare;
      }
    }
  }

  /**
   * Minimal Status panel state without JE polling / next-env resolution.
   * LWC startJobPoll + refreshJobStatus do the heavy lift in a fresh transaction.
   */
  private static SessionState buildLightSessionState(Id sessionId, Boolean jobJustStarted) {
    AI_Builder_Session__c session = loadSession(sessionId);
    StoryRef story = resolveStoryRef(session);
    SessionState state = new SessionState();
    state.sessionId = session.Id;
    state.status = session.Status__c;
    state.currentStep = session.Current_Step__c;
    state.copadoUserStory = formatStoryLink(session.Copado_User_Story__c);
    state.storyRecordId = story.recordId != null
      ? String.valueOf(story.recordId)
      : session.Story_Record_Id__c;
    state.storyName = String.isNotBlank(session.Story_Name__c) ? session.Story_Name__c : story.name;
    state.storyTitle = String.isNotBlank(session.Story_Title__c) ? session.Story_Title__c : story.title;
    state.lastBuildId = session.Last_Build_Id__c;
    state.lastJobId = session.Last_Job_Id__c;
    state.lastDeployJobId = session.Last_Deploy_Job_Id__c;
    state.lastCommitJobId = session.Last_Commit_Job_Id__c;
    state.lastJobAction = session.Last_Job_Action__c;
    state.lastPromotionId = session.Last_Promotion_Id__c;
    state.builderCodeVersion = CopadoDevopsService.BUILDER_CODE_VERSION;
    state.buildArtifacts = extractArtifactPaths(session.Build_Package_Json__c);
    state.selectedOrg = session.Selected_Org__c;
    state.selectedOrgId = session.Org_Credential_Id__c;
    if ('Connected'.equalsIgnoreCase(session.Org_Context_Status__c)
      && String.isNotBlank(session.Org_Credential_Id__c)) {
      state.connectedOrgId = session.Org_Credential_Id__c;
      state.connectedOrgName = session.Selected_Org__c;
    }
    state.orgContextStatus = session.Org_Context_Status__c;
    state.orgIntelligenceIntegrationId = session.Org_Intelligence_Integration_Id__c;
    state.score = session.Score__c != null ? Integer.valueOf(session.Score__c) : 0;
    state.summary = session.Summary__c;
    state.messages = getMessages(sessionId);

    Boolean lastFailed = false;
    Boolean lastComplete = false;
    Boolean lastInProgress = false;
    if (jobJustStarted == true && String.isNotBlank(session.Last_Job_Id__c)) {
      state.lastJobStatus = 'In Progress';
      state.lastJobSummary = 'Job started — refreshing status…';
      state.lastJobComplete = false;
      state.lastJobFailed = false;
      lastInProgress = true;
    }

    // Do not call isJobExecutionSuccessful here (extra SOQL). Derive from step flags.
    Boolean pastCommit =
      'Committed'.equalsIgnoreCase(session.Current_Step__c)
      || 'Validating'.equalsIgnoreCase(session.Current_Step__c)
      || 'Validated'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployingNext'.equalsIgnoreCase(session.Current_Step__c)
      || 'DeployedNext'.equalsIgnoreCase(session.Current_Step__c);
    // While the just-started job is still running, do not mark that step Successful yet.
    if (jobJustStarted == true && 'Commit'.equalsIgnoreCase(session.Last_Job_Action__c)) {
      state.deploySucceeded = String.isNotBlank(session.Last_Deploy_Job_Id__c);
      state.commitSucceeded = false;
      lastInProgress = true;
    } else if (jobJustStarted == true && 'Deploy'.equalsIgnoreCase(session.Last_Job_Action__c)) {
      state.deploySucceeded = false;
      state.commitSucceeded = false;
      lastInProgress = true;
    } else {
      state.deploySucceeded = String.isNotBlank(session.Last_Deploy_Job_Id__c) && pastCommit;
      state.commitSucceeded = String.isNotBlank(session.Last_Commit_Job_Id__c) && pastCommit;
    }
    state.canValidate = state.commitSucceeded == true;
    applyPipelineStepStatuses(state, session, lastFailed, lastComplete, lastInProgress);
    state.buildStatus = state.buildStepStatus;
    state.deployStatus = state.deployStepStatus;
    state.canCheckDeployment =
      (
        String.isNotBlank(session.Copado_User_Story__c)
        || String.isNotBlank(session.Story_Record_Id__c)
      )
      && String.isNotBlank(session.Org_Credential_Id__c)
      && state.buildArtifacts != null
      && !state.buildArtifacts.isEmpty();
    return state;
  }

  private static ActionResult failBuildInProgress(Id sessionId, String message) {
    try {
      AI_Builder_Session__c session = [
        SELECT Id, Current_Step__c, Status__c, Last_Job_Action__c,
          Build_Package_Json__c, Last_Build_Id__c
        FROM AI_Builder_Session__c
        WHERE Id = :sessionId
        LIMIT 1
      ];
      session.Last_Job_Action__c = 'Build';
      session.Current_Step__c = 'Build Failed';
      // Clear pending marker so Status is not stuck In progress.
      if (String.isNotBlank(session.Build_Package_Json__c)
        && session.Build_Package_Json__c.contains('_pendingBuild')) {
        session.Build_Package_Json__c = null;
        session.Last_Build_Id__c = null;
      }
      // Status__c is a restricted picklist — keep a valid value; Current_Step drives Failed.
      if (String.isNotBlank(session.Build_Package_Json__c)
        && !session.Build_Package_Json__c.contains('_pendingBuild')) {
        session.Status__c = 'Code Built';
      } else {
        session.Status__c = 'In Progress';
      }
      update session;
      try {
        insertMessage(sessionId, 'System', message, 'Build Failed');
      } catch (Exception ignoreMsg) {
      }
    } catch (Exception ignore) {
    }
    ActionResult result = failure(message);
    result.awaitingBuild = false;
    try {
      result.session = getSessionState(sessionId);
    } catch (Exception ignore) {
    }
    return result;
  }

  private static ActionResult failure(String message) {
  ActionResult result = new ActionResult();
  result.success = false;
  result.message = message;
  return result;
  }
}
