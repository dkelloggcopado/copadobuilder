import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { EnclosingUtilityId } from 'lightning/platformUtilityBarApi';
import startSession from '@salesforce/apex/CopadoBuilderController.startSession';
import resumeOrStartSession from '@salesforce/apex/CopadoBuilderController.resumeOrStartSession';
import sendMessage from '@salesforce/apex/CopadoBuilderController.sendMessage';
import pollAiReply from '@salesforce/apex/CopadoBuilderController.pollAiReply';
import createCopadoStory from '@salesforce/apex/CopadoBuilderController.createCopadoStory';
import listCopadoUserStories from '@salesforce/apex/CopadoBuilderController.listCopadoUserStories';
import openCopadoUserStory from '@salesforce/apex/CopadoBuilderController.openCopadoUserStory';
import buildCode from '@salesforce/apex/CopadoBuilderController.buildCode';
import pollBuildPackage from '@salesforce/apex/CopadoBuilderController.pollBuildPackage';
import refreshJobStatus from '@salesforce/apex/CopadoBuilderController.refreshJobStatus';
import linkUserStoryCommitFromLastJob from '@salesforce/apex/CopadoBuilderController.linkUserStoryCommitFromLastJob';
import listSafeDevOrgs from '@salesforce/apex/CopadoBuilderController.listSafeDevOrgs';
import listCopadoProjects from '@salesforce/apex/CopadoBuilderController.listCopadoProjects';
import savePreferredProject from '@salesforce/apex/CopadoBuilderController.savePreferredProject';
import savePreferredEnvironment from '@salesforce/apex/CopadoBuilderController.savePreferredEnvironment';
import savePreferredIntegration from '@salesforce/apex/CopadoBuilderController.savePreferredIntegration';
import getUserSetupDefaults from '@salesforce/apex/CopadoBuilderController.getUserSetupDefaults';
import saveUserSetupDefaults from '@salesforce/apex/CopadoBuilderController.saveUserSetupDefaults';
import saveUserCopadoAiPat from '@salesforce/apex/CopadoBuilderController.saveUserCopadoAiPat';
import bypassUserSetup from '@salesforce/apex/CopadoBuilderController.bypassUserSetup';
import commitFromDev from '@salesforce/apex/CopadoBuilderController.commitFromDev';
import deployToDev from '@salesforce/apex/CopadoBuilderController.deployToDev';
import validateToNextEnvironment from '@salesforce/apex/CopadoBuilderController.validateToNextEnvironment';
import deployToNextEnvironment from '@salesforce/apex/CopadoBuilderController.deployToNextEnvironment';
import checkDeployment from '@salesforce/apex/CopadoBuilderController.checkDeployment';
import improveStory from '@salesforce/apex/CopadoBuilderController.improveStory';
import getMySessions from '@salesforce/apex/CopadoBuilderController.getMySessions';
import openSession from '@salesforce/apex/CopadoBuilderController.openSession';
import deleteSession from '@salesforce/apex/CopadoBuilderController.deleteSession';
import connectOrgIntelligence from '@salesforce/apex/CopadoBuilderController.connectOrgIntelligence';
import listOrgIntelligenceIntegrations from '@salesforce/apex/CopadoBuilderController.listOrgIntelligenceIntegrations';
import ensureOrgIntelligenceReady from '@salesforce/apex/CopadoBuilderController.ensureOrgIntelligenceReady';

export default class CopadoBuilderChat extends NavigationMixin(LightningElement) {
  /** App Manager toggle for utility panel compact layout. */
  @api utilityCompact = false;

  @track sessionId;
  @track messages = [];
  @track inputMessage = '';
  @track isLoading = false;
  @track waitingLabel = 'Copado is thinking';
  @track pendingUserMessage = '';

  @track score = 0;
  @track currentStep = 'Discovery';
  @track missingInfo = [];
  @track orgContextStatus = 'Not connected';
  @track orgIntelligenceIntegrationId = '';
  @track buildStatus = 'Not ready';
  @track testStatus = 'Not ready';
  @track deployStatus = 'Not ready';
  @track buildStepStatus = 'Not ready';
  @track deployStepStatus = 'Not ready';
  @track commitStepStatus = 'Not ready';
  @track validateStepStatus = 'Not ready';
  @track nextDeployStepStatus = 'Not ready';
  @track canDeployNext = false;
  @track canCheckDeployment = false;
  @track pipelineErrorDetail = '';
  @track pipelineErrorJobId = '';
  @track pipelineErrorAction = '';
  @track connectedOrgId = '';
  @track connectedOrgName = '';
  @track isEditingOrgContext = false;
  @track copadoUserStory = '';
  @track storyRecordId = '';
  @track storyName = '';
  @track storyTitle = '';
  @track hasStory = false;

  @track projectOptions = [];
  @track selectedProjectId = '';
  @track projectHelpText =
    'Choose the Copado Project whose pipeline contains your Dev environment.';
  @track orgOptions = [];
  @track selectedOrgId = '';
  @track integrationOptions = [];
  @track selectedIntegrationId = '';
  @track integrationsLoaded = false;
  @track rememberEnvironment = true;
  @track environmentHelpText =
    'Choose a Dev Org Credential you own, then click Update OI to bind Org Intelligence.';
  @track chatSessions = [];
  @track userStoryOptions = [];
  @track selectedUserStoryId = '';
  @track storySearchTerm = '';
  @track isChangingStory = false;
  @track lastBuildId = '';
  @track lastJobId = '';
  @track lastJobStatus = '';
  @track lastJobSummary = '';
  @track lastJobFailed = false;
  @track lastJobComplete = false;
  @track lastJobAction = '';
  @track lastPromotionId = '';
  @track lastDeployJobId = '';
  @track lastCommitJobId = '';
  @track deploySucceeded = false;
  @track commitSucceeded = false;
  @track canValidate = false;
  @track nextEnvironmentId = '';
  @track nextEnvironmentName = '';
  @track buildArtifacts = [];
  /** Artifacts list starts expanded so filenames are visible; click to minimize. */
  @track artifactsExpanded = true;

  /** In-app confirm modal (replaces LightningConfirm + window.confirm). */
  @track confirmOpen = false;
  @track confirmTitle = '';
  @track confirmMessage = '';
  @track confirmConfirmLabel = 'Confirm';
  @track confirmVariant = 'default';
  @track confirmRecreateFeatureBranch = false;

  /** First-run setup wizard: (1) PAT + Project → (2) Integration. */
  @track setupOpen = false;
  @track setupStep = 1;
  @track setupProjectId = '';
  @track setupIntegrationId = '';
  @track setupPat = '';
  @track setupHasPat = false;
  @track setupPatMask = '';
  @track setupSaving = false;
  @track setupLoadingIntegrations = false;
  @track setupStatusMessage = '';
  @track preferredIntegrationId = '';

  _waitingTimer;
  _lastMessagesKey = '';
  _scrollRaf;
  _jobPollTimer;
  _jobPollAttempts = 0;
  _aiPollTimer;
  _aiPollAttempts = 0;
  _confirmAction = null;
  _pendingDeleteId = null;
  _pendingDeleteName = null;
  _boundConfirmKeydown = null;

  @wire(EnclosingUtilityId)
  utilityId;

  @track showChatsInCompact = false;
  @track showStatusInCompact = false;

  get isCompact() {
    // Aura Global Action often passes the boolean @api as the string "true".
    return (
      !!this.utilityId
      || this.utilityCompact === true
      || this.utilityCompact === 'true'
    );
  }

  /** @deprecated alias — compact covers utility + global action */
  get isUtilityBar() {
    return this.isCompact;
  }

  get showBrandChrome() {
    return !this.isCompact;
  }

  get showChatHeader() {
    return !this.isCompact;
  }

  get showChatsPanel() {
    return !this.isCompact || this.showChatsInCompact;
  }

  get showStatusPanel() {
    return !this.isCompact || this.showStatusInCompact;
  }

  get chatsToggleLabel() {
    return this.showChatsInCompact ? 'Hide Chats' : 'Chats';
  }

  get statusToggleLabel() {
    return this.showStatusInCompact ? 'Hide Status' : 'Status';
  }

  get rootClass() {
    return this.isCompact ? 'builder-root builder-root_compact' : 'builder-root';
  }

  get shellClass() {
    return this.isCompact ? 'builder-shell builder-shell_utility' : 'builder-shell';
  }

  get layoutClass() {
    return this.isCompact ? 'builder-layout builder-layout_utility' : 'builder-layout';
  }

  toggleChatsPanel() {
    this.showChatsInCompact = !this.showChatsInCompact;
    if (this.showChatsInCompact) {
      this.showStatusInCompact = false;
    }
  }

  toggleStatusPanel() {
    this.showStatusInCompact = !this.showStatusInCompact;
    if (this.showStatusInCompact) {
      this.showChatsInCompact = false;
    }
  }

  renderedCallback() {
    this.renderMessages();
  }

  disconnectedCallback() {
    this.clearWaitingTimer();
    this.clearJobPoll();
    this.clearAiPoll();
    this.teardownConfirmKeyListener();
  }

  connectedCallback() {
    this._boundConfirmKeydown = (event) => this.handleConfirmKeydown(event);
    this.initSession();
  }

  openConfirm({ title, message, confirmLabel, variant, action }) {
    this.confirmTitle = title || 'Confirm';
    this.confirmMessage = message || '';
    this.confirmConfirmLabel = confirmLabel || 'Confirm';
    this.confirmVariant = variant === 'commit' ? 'commit' : 'default';
    this.confirmRecreateFeatureBranch = false;
    this._confirmAction = action || null;
    this.confirmOpen = true;
    this.setupConfirmKeyListener();
  }

  closeConfirm() {
    this.confirmOpen = false;
    this.confirmTitle = '';
    this.confirmMessage = '';
    this.confirmConfirmLabel = 'Confirm';
    this.confirmVariant = 'default';
    this.confirmRecreateFeatureBranch = false;
    this._confirmAction = null;
    this._pendingDeleteId = null;
    this._pendingDeleteName = null;
    this.teardownConfirmKeyListener();
  }

  setupConfirmKeyListener() {
    if (!this._boundConfirmKeydown) return;
    window.removeEventListener('keydown', this._boundConfirmKeydown);
    window.addEventListener('keydown', this._boundConfirmKeydown);
  }

  teardownConfirmKeyListener() {
    if (this._boundConfirmKeydown) {
      window.removeEventListener('keydown', this._boundConfirmKeydown);
    }
  }

  handleConfirmKeydown(event) {
    if (!this.confirmOpen) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      this.handleConfirmCancel();
    }
  }

  handleConfirmBackdropClick() {
    this.handleConfirmCancel();
  }

  handleConfirmCancel() {
    if (this._confirmAction === 'build') {
      this.closeConfirm();
      this.showToast('Build cancelled', 'No package was generated.', 'info');
      return;
    }
    this.closeConfirm();
  }

  handleConfirmCardClick(event) {
    event.stopPropagation();
  }

  handleConfirmRecreateChange(event) {
    this.confirmRecreateFeatureBranch = event.target.checked === true;
  }

  async handleConfirmOk() {
    const action = this._confirmAction;
    const recreate = this.confirmRecreateFeatureBranch === true;
    const deleteId = this._pendingDeleteId;
    this.closeConfirm();
    if (action === 'improve') {
      await this.runAction(
        () => improveStory({ sessionId: this.sessionId }),
        'Updating linked story from chat'
      );
    } else if (action === 'build') {
      await this.executeBuildCode();
    } else if (action === 'deploy') {
      await this.executeDeploy();
    } else if (action === 'commit') {
      await this.executeCommit(recreate);
    } else if (action === 'validate') {
      await this.executeValidate();
    } else if (action === 'deployNext') {
      await this.executeDeployNext();
    } else if (action === 'delete') {
      this._pendingDeleteId = deleteId;
      await this.executeDeleteChat();
    }
  }

  get isConfirmCommitVariant() {
    return this.confirmVariant === 'commit';
  }

  get confirmPrimaryVariant() {
    return this.confirmVariant === 'commit' ? 'success' : 'brand';
  }

  async initSession() {
    this.beginWaiting('Opening Copado Builder');
    try {
      const session = await resumeOrStartSession();
      this.applySession(session);
      await Promise.all([
        this.loadProjects(),
        this.loadChatSessions(),
        this.loadUserStories()
      ]);
      await this.loadOrgs();
      await this.loadIntegrations();
      await this.maybeOpenUserSetup();
      await this.checkExistingOrgIntelligence();
    } catch (error) {
      this.showError(error);
    } finally {
      this.endWaiting();
    }
  }

  async handleNewChat() {
    if (this.isLoading) return;
    this.beginWaiting('Starting new chat');
    try {
      const session = await startSession();
      this.isChangingStory = false;
      this.applySession(session);
      await this.loadChatSessions();
      await this.loadProjects();
      await this.loadOrgs();
      await this.loadIntegrations();
      await this.maybeOpenUserSetup();
      await this.checkExistingOrgIntelligence();
    } catch (error) {
      this.showError(error);
    } finally {
      this.endWaiting();
    }
  }

  async handleOpenChat(event) {
    const id = event.currentTarget?.dataset?.id;
    if (!id || this.isLoading || id === this.sessionId) return;

    this.beginWaiting('Opening chat');
    try {
      const session = await openSession({ sessionId: id });
      this.applySession(session);
      await Promise.all([this.loadChatSessions(), this.loadProjects(), this.loadUserStories()]);
      await this.loadOrgs();
      await this.loadIntegrations();
      await this.maybeOpenUserSetup();
      await this.checkExistingOrgIntelligence();
    } catch (error) {
      this.showError(error);
    } finally {
      this.endWaiting();
    }
  }

  async handleDeleteChat(event) {
    event.stopPropagation();
    const id = event.currentTarget?.dataset?.id;
    const name = event.currentTarget?.dataset?.name || 'this chat';
    if (!id || this.isLoading) return;

    this._pendingDeleteId = id;
    this._pendingDeleteName = name;
    this.openConfirm({
      title: 'Delete chat',
      message:
        `Delete "${name}"?\n\n`
        + 'This removes it from Copado Builder and tries to delete the linked Copado AI chat too.',
      confirmLabel: 'Delete',
      action: 'delete'
    });
  }

  async executeDeleteChat() {
    const id = this._pendingDeleteId;
    if (!id) return;
    this.beginWaiting('Deleting chat');
    try {
      const session = await deleteSession({ sessionId: id });
      this.isChangingStory = false;
      this.applySession(session);
      await Promise.all([
        this.loadChatSessions(),
        this.loadProjects(),
        this.loadUserStories()
      ]);
      await this.loadOrgs();
      await this.loadIntegrations();
      this.showToast('Deleted', 'Chat removed.', 'success');
    } catch (error) {
      this.showError(error);
    } finally {
      this._pendingDeleteId = null;
      this._pendingDeleteName = null;
      this.endWaiting();
    }
  }

  async loadProjects() {
    if (!this.sessionId) return;
    try {
      const result = await listCopadoProjects({ sessionId: this.sessionId });
      const projects = result?.projects || [];
      this.projectOptions = projects.map((p) => ({
        label: p.projectName,
        value: p.projectId
      }));
      if (result?.helpText) {
        this.projectHelpText = result.helpText;
      }
      const preferred =
        result?.storyProjectId ||
        result?.preferredProjectId ||
        (this.projectOptions.length > 0 ? this.projectOptions[0].value : '');
      if (preferred && this.projectOptions.some((o) => o.value === preferred)) {
        this.selectedProjectId = preferred;
      } else if (this.projectOptions.length > 0 && !this.selectedProjectId) {
        this.selectedProjectId = this.projectOptions[0].value;
      }
    } catch (error) {
      this.showError(error);
    }
  }

  async loadOrgs() {
    if (!this.sessionId) return;
    try {
      const result = await listSafeDevOrgs({
        sessionId: this.sessionId,
        projectId: this.selectedProjectId || null
      });
      const orgs = result?.orgs || result || [];
      this.orgOptions = orgs.map((org) => ({
        label: org.orgName,
        value: org.orgId
      }));
      if (result?.helpText) {
        this.environmentHelpText = result.helpText;
      }
      if (
        result?.projectId &&
        this.projectOptions.some((o) => o.value === result.projectId)
      ) {
        this.selectedProjectId = result.projectId;
      }
      // Bound credential not in this user's owned list → not Connected; show picker.
      const ownedIds = new Set(this.orgOptions.map((o) => o.value));
      if (this.connectedOrgId && !ownedIds.has(this.connectedOrgId)) {
        this.orgContextStatus = 'Not connected';
        this.connectedOrgId = '';
        this.connectedOrgName = '';
        this.isEditingOrgContext = true;
      }
      if (this.selectedOrgId && !ownedIds.has(this.selectedOrgId)) {
        this.selectedOrgId = '';
      }
      const preferred =
        (this.selectedOrgId &&
        this.orgOptions.some((o) => o.value === this.selectedOrgId)
          ? this.selectedOrgId
          : null) ||
        result?.sessionSelectedOrgId ||
        result?.storyEnvironmentId ||
        result?.preferredEnvironmentId ||
        (this.orgOptions.length > 0 ? this.orgOptions[0].value : '');
      if (preferred && this.orgOptions.some((o) => o.value === preferred)) {
        this.selectedOrgId = preferred;
      } else if (this.orgOptions.length > 0) {
        this.selectedOrgId = this.orgOptions[0].value;
      } else {
        this.selectedOrgId = '';
      }
      // Keep collapsed (name + pencil) when a credential is already selected.
      // Only force the editor open when there is nothing to show yet.
      if (!this.selectedOrgId && !this.connectedOrgId) {
        this.isEditingOrgContext = true;
      }
    } catch (error) {
      this.showError(error);
    }
  }

  async loadIntegrations(options = {}) {
    const surfaceError = options.surfaceError === true;
    if (!this.sessionId) {
      if (surfaceError) {
        throw new Error('No Builder session yet — close setup and reopen Copado Builder.');
      }
      return;
    }
    try {
      let preferredFromPrefs = this.preferredIntegrationId || '';
      try {
        const defaults = await getUserSetupDefaults();
        if (defaults?.preferredIntegrationId) {
          preferredFromPrefs = defaults.preferredIntegrationId;
          this.preferredIntegrationId = preferredFromPrefs;
        }
        if (defaults?.preferredProjectId
          && this.projectOptions.some((o) => o.value === defaults.preferredProjectId)
          && !this.selectedProjectId) {
          this.selectedProjectId = defaults.preferredProjectId;
        }
      } catch (ignore) {
        // Prefs are best-effort
      }

      const rows = await listOrgIntelligenceIntegrations({ sessionId: this.sessionId });
      this.integrationOptions = (rows || []).map((row) => ({
        label: row.label || row.name || row.id,
        value: row.id,
        connected: row.connected === true,
        name: row.name || '',
        matchedToCurrentUser: row.matchedToCurrentUser === true,
        matchScore: row.matchScore || 0
      }));
      this.integrationsLoaded = true;
      const preferred =
        this.orgIntelligenceIntegrationId
        || this.selectedIntegrationId
        || preferredFromPrefs
        || '';
      const preferredRow = preferred
        ? this.integrationOptions.find((o) => o.value === preferred)
        : null;
      const personalConnected = this.integrationOptions.find(
        (o) => o.matchedToCurrentUser === true && o.connected === true
      );
      const personalAny = this.integrationOptions.find(
        (o) => o.matchedToCurrentUser === true
      );
      const preferredIsGeneric =
        preferredRow
        && (preferredRow.name || '').trim().toLowerCase() === 'user level';
      const preferredIsSavedPersonal =
        preferredFromPrefs
        && preferredRow
        && preferredRow.value === preferredFromPrefs;

      if (preferredIsSavedPersonal) {
        this.selectedIntegrationId = preferredRow.value;
      } else if (preferredRow && !(preferredIsGeneric && personalConnected)) {
        this.selectedIntegrationId = preferredRow.value;
      } else if (personalConnected?.value) {
        this.selectedIntegrationId = personalConnected.value;
      } else if (personalAny?.value) {
        this.selectedIntegrationId = personalAny.value;
      } else {
        const userLevel = (rows || []).find(
          (r) => (r.name || '').toLowerCase() === 'user level' && r.connected === true
        );
        const anyConnected = (rows || []).find((r) => r.connected === true);
        if (userLevel?.id) {
          this.selectedIntegrationId = userLevel.id;
        } else if (anyConnected?.id) {
          this.selectedIntegrationId = anyConnected.id;
        } else if (this.integrationOptions.length > 0) {
          this.selectedIntegrationId = this.integrationOptions[0].value;
        } else {
          this.selectedIntegrationId = '';
        }
      }
      // Picker only — Connected status comes from checkExistingOrgIntelligence / Connect.
    } catch (error) {
      this.integrationOptions = [];
      this.integrationsLoaded = true;
      if (surfaceError) {
        throw error;
      }
    }
  }

  /**
   * First-run wizard: Step 1 PAT + Project, Step 2 Integration (after PAT callout).
   */
  async maybeOpenUserSetup() {
    try {
      const defaults = await getUserSetupDefaults();
      this.preferredIntegrationId = defaults?.preferredIntegrationId || '';
      this.setupHasPat = defaults?.hasPat === true;
      this.setupPatMask = defaults?.patMask || '';
      if (defaults?.needsSetup !== true) {
        this.setupOpen = false;
        return;
      }
      this.setupProjectId =
        defaults?.preferredProjectId
        || this.selectedProjectId
        || (this.projectOptions[0] && this.projectOptions[0].value)
        || '';
      this.setupIntegrationId = defaults?.preferredIntegrationId || '';
      this.setupPat = '';
      this.setupStep = 1;
      this.setupStatusMessage = '';
      this.setupLoadingIntegrations = false;
      this.setupOpen = true;
    } catch (error) {
      // Do not block Builder if prefs cannot be read
      this.setupOpen = false;
    }
  }

  /** Re-open setup wizard so the user can paste/update their Copado AI PAT. */
  async handleUpdateCopadoAiToken() {
    try {
      const defaults = await getUserSetupDefaults();
      this.setupHasPat = defaults?.hasPat === true;
      this.setupPatMask = defaults?.patMask || '';
      this.setupProjectId =
        defaults?.preferredProjectId
        || this.selectedProjectId
        || (this.projectOptions[0] && this.projectOptions[0].value)
        || '';
      this.setupIntegrationId =
        defaults?.preferredIntegrationId
        || this.selectedIntegrationId
        || '';
      this.setupPat = '';
      this.setupStep = 1;
      this.setupStatusMessage = '';
      this.setupLoadingIntegrations = false;
      this.setupOpen = true;
    } catch (error) {
      this.showError(error);
    }
  }

  handleSetupProjectChange(event) {
    this.setupProjectId = event.detail.value;
  }

  handleSetupIntegrationChange(event) {
    this.setupIntegrationId = event.detail.value;
  }

  handleSetupPatChange(event) {
    this.setupPat = event.detail.value || '';
  }

  get setupPatHelpText() {
    if (this.setupHasPat && this.setupPatMask) {
      return `Token on file (${this.setupPatMask}). Paste a new token to replace it, or Continue to keep it.`;
    }
    return 'Create a Personal Access Token in the Copado AI Platform for your own account. Do not use a teammate\'s token.';
  }

  get isSetupStep1() {
    return this.setupStep === 1;
  }

  get isSetupStep2() {
    return this.setupStep === 2;
  }

  get setupProgressLabel() {
    return this.setupStep === 2 ? 'Step 2 of 2' : 'Step 1 of 2';
  }

  get setupProgressTitle() {
    return this.setupStep === 2
      ? 'Choose your Copado AI Integration'
      : 'Token & Project';
  }

  get setupProgressPercent() {
    return this.setupStep === 2 ? 100 : 50;
  }

  get setupProgressStyle() {
    return `width: ${this.setupProgressPercent}%;`;
  }

  get isSetupContinueDisabled() {
    if (this.setupSaving || this.setupLoadingIntegrations) {
      return true;
    }
    const hasPat = this.setupHasPat || !!this.setupPat;
    return !hasPat || !this.setupProjectId || this.projectOptions.length === 0;
  }

  get isSetupSaveDisabled() {
    return this.setupSaving
      || this.setupLoadingIntegrations
      || !this.setupIntegrationId
      || this.integrationOptions.length === 0;
  }

  get isSetupBypassDisabled() {
    return this.setupSaving || this.setupLoadingIntegrations || !this.setupHasPat;
  }

  get isSetupBackDisabled() {
    return this.setupSaving || this.setupLoadingIntegrations;
  }

  get isSetupIntegrationDisabled() {
    return this.setupSaving
      || this.setupLoadingIntegrations
      || this.setupIntegrationEmpty;
  }

  get isSetupRetryDisabled() {
    return this.setupSaving || this.setupLoadingIntegrations;
  }

  get setupIntegrationEmpty() {
    return !this.setupLoadingIntegrations
      && this.isSetupStep2
      && this.integrationOptions.length === 0;
  }

  /** Step 1 → save PAT + project, then load integrations for Step 2. */
  async handleSetupContinue() {
    if (this.isSetupContinueDisabled) {
      this.showToast(
        'Notice',
        'Enter your Copado AI Personal Access Token and select a Copado Project.',
        'warning'
      );
      return;
    }
    this.setupSaving = true;
    this.setupStatusMessage = 'Saving your token…';
    try {
      if (this.setupPat) {
        const mask = await saveUserCopadoAiPat({ copadoAiPat: this.setupPat });
        this.setupHasPat = true;
        this.setupPatMask = mask || '';
        this.setupPat = '';
      }
      if (this.setupProjectId) {
        await savePreferredProject({ projectId: this.setupProjectId });
        this.selectedProjectId = this.setupProjectId;
      }
      this.setupStep = 2;
      this.setupSaving = false;
      this.setupLoadingIntegrations = true;
      this.setupStatusMessage = 'Looking up your Copado AI integrations…';
      await this.loadIntegrations({ surfaceError: true });
      const personal =
        this.integrationOptions.find((o) => o.matchedToCurrentUser === true && o.connected)
        || this.integrationOptions.find((o) => o.matchedToCurrentUser === true);
      this.setupIntegrationId =
        this.preferredIntegrationId
        || personal?.value
        || this.selectedIntegrationId
        || (this.integrationOptions[0] && this.integrationOptions[0].value)
        || '';
      if (this.integrationOptions.length === 0) {
        this.setupStatusMessage =
          'No integrations returned for this token. Confirm Organization Id in Copado Builder Settings, that the PAT belongs to your Copado AI user, and that a User Level CI/CD integration exists — then Retry. Or Bypass to chat now.';
      } else {
        this.setupStatusMessage =
          `${this.integrationOptions.length} integration`
          + (this.integrationOptions.length === 1 ? '' : 's')
          + ' found. Select yours, then Save — or Bypass to chat now.';
      }
    } catch (error) {
      this.setupStep = 2;
      const msg = this.reduceError(error);
      this.setupStatusMessage =
        'Could not load integrations: '
        + msg
        + ' Fix the token / Organization Id, then Retry — or Bypass to chat.';
      this.showToast('Integration lookup failed', msg, 'error');
    } finally {
      this.setupSaving = false;
      this.setupLoadingIntegrations = false;
    }
  }

  handleSetupBack() {
    if (this.setupSaving || this.setupLoadingIntegrations) {
      return;
    }
    this.setupStep = 1;
    this.setupStatusMessage = '';
  }

  async handleSetupRetryIntegrations() {
    if (this.setupSaving || this.setupLoadingIntegrations) {
      return;
    }
    this.setupLoadingIntegrations = true;
    this.setupStatusMessage = 'Looking up your Copado AI integrations…';
    try {
      await this.loadIntegrations({ surfaceError: true });
      if (this.integrationOptions.length === 0) {
        this.setupStatusMessage =
          'Still no integrations for this PAT. Confirm Organization Id + User Level in Copado AI, then Retry — or Bypass.';
      } else {
        this.setupStatusMessage =
          `${this.integrationOptions.length} integration`
          + (this.integrationOptions.length === 1 ? '' : 's')
          + ' found.';
        this.setupIntegrationId =
          this.setupIntegrationId
          || this.selectedIntegrationId
          || this.integrationOptions[0].value;
      }
    } catch (error) {
      const msg = this.reduceError(error);
      this.setupStatusMessage = 'Lookup failed: ' + msg;
      this.showToast('Integration lookup failed', msg, 'error');
    } finally {
      this.setupLoadingIntegrations = false;
    }
  }

  async handleSetupSave() {
    if (this.isSetupSaveDisabled) {
      this.showToast(
        'Notice',
        'Select your Copado AI Integration (named for you), or Bypass to chat without it.',
        'warning'
      );
      return;
    }
    this.setupSaving = true;
    this.setupStatusMessage = 'Saving your defaults…';
    try {
      await saveUserSetupDefaults({
        projectId: this.setupProjectId,
        integrationId: this.setupIntegrationId,
        copadoAiPat: null
      });
      this.selectedProjectId = this.setupProjectId;
      this.selectedIntegrationId = this.setupIntegrationId;
      this.preferredIntegrationId = this.setupIntegrationId;
      this.setupHasPat = true;
      this.setupPat = '';
      this.setupOpen = false;
      this.setupStep = 1;
      this.setupStatusMessage = '';
      this.isEditingOrgContext = true;
      await this.loadOrgs();
      this.showToast(
        'Saved',
        'Your Copado AI token, Project, and Integration are remembered for this Salesforce user.',
        'success'
      );
    } catch (error) {
      this.showError(error);
    } finally {
      this.setupSaving = false;
    }
  }

  async handleSetupBypass() {
    if (this.isSetupBypassDisabled) {
      this.showToast(
        'Notice',
        'Finish Step 1 first (token + project), then you can bypass Integration.',
        'warning'
      );
      return;
    }
    this.setupSaving = true;
    this.setupStatusMessage = 'Finishing setup…';
    try {
      if (this.setupProjectId) {
        await savePreferredProject({ projectId: this.setupProjectId });
        this.selectedProjectId = this.setupProjectId;
      }
      await bypassUserSetup();
      this.setupOpen = false;
      this.setupStep = 1;
      this.setupStatusMessage = '';
      this.showToast(
        'Chat ready',
        'Token and Project saved. Set Integration later for Org Context / Deploy.',
        'info'
      );
    } catch (error) {
      this.showError(error);
    } finally {
      this.setupSaving = false;
    }
  }

  /**
   * Once per chat: pick the best Copado AI integration, then verify whether it is
   * already bound to an owned Dev credential. If yes, adopt Org Context Connected
   * (green name + pencil) without requiring Update OI.
   */
  async checkExistingOrgIntelligence() {
    if (!this.sessionId) return;
    if (this._oiCheckedSessionId === this.sessionId) return;
    this._oiCheckedSessionId = this.sessionId;

    const personalConnected = this.integrationOptions.find(
      (o) => o.matchedToCurrentUser === true && o.connected === true
    );

    // Already Connected by this user — optionally upgrade off shared generic User Level.
    if (
      this.isOrgContextConnected
      && this.orgIntelligenceIntegrationId
    ) {
      const current = this.integrationOptions.find(
        (o) => o.value === this.orgIntelligenceIntegrationId
      );
      const currentIsGeneric =
        current && (current.name || '').trim().toLowerCase() === 'user level';
      if (
        personalConnected?.value
        && currentIsGeneric
        && personalConnected.value !== this.orgIntelligenceIntegrationId
      ) {
        this.selectedIntegrationId = personalConnected.value;
        await this.syncOrgIntelligence(true);
      }
      this.isEditingOrgContext = false;
      return;
    }

    // Prefer personal match, then connected User Level, then any connected.
    const matched =
      personalConnected
      || this.integrationOptions.find(
        (o) => o.connected === true && (o.name || '').toLowerCase() === 'user level'
      )
      || this.integrationOptions.find((o) => o.connected === true);

    if (matched?.value) {
      this.selectedIntegrationId = matched.value;
    }

    // Verify bind via Copado AI GET — mark Connected when already good to go.
    if (!this.setupOpen) {
      await this.syncOrgIntelligence(false);
      if (this.isOrgContextConnected) {
        this.isEditingOrgContext = false;
      }
    }
  }

  /**
   * bindCredential=false: verify existing Copado AI bind and adopt Connected when matched.
   * bindCredential=true: push selected Dev org onto the integration (Update OI).
   */
  async syncOrgIntelligence(bindCredential = false) {
    if (!this.sessionId) return;
    try {
      const session = await ensureOrgIntelligenceReady({
        sessionId: this.sessionId,
        orgCredentialId: this.selectedOrgId || this.connectedOrgId || null,
        preferredIntegrationId: this.selectedIntegrationId || null,
        bindCredential: bindCredential === true
      });
      if (session) {
        this.applySession(session);
        if (this.isOrgContextConnected) {
          this.isEditingOrgContext = false;
          if (this.connectedOrgId) {
            this.selectedOrgId = this.connectedOrgId;
          }
        }
      }
    } catch (error) {
      // Non-fatal — user can still click Update OI.
    }
  }

  async loadUserStories() {
    try {
      const rows = await listCopadoUserStories({
        searchTerm: this.storySearchTerm || ''
      });
      this.userStoryOptions = (rows || []).map((row) => ({
        label: row.label || row.name,
        value: row.id
      }));
      // Prefer currently linked story if present in options
      if (!this.selectedUserStoryId && this.userStoryOptions.length > 0) {
        this.selectedUserStoryId = this.userStoryOptions[0].value;
      }
    } catch (error) {
      this.userStoryOptions = [];
    }
  }

  handleStorySearchChange(event) {
    this.storySearchTerm = event.target.value || '';
  }

  handleStorySearchKeyDown(event) {
    if (event.key === 'Enter') {
      event.preventDefault();
      this.handleStorySearch();
    }
  }

  async handleStorySearch() {
    this.isLoading = true;
    try {
      await this.loadUserStories();
    } finally {
      this.isLoading = false;
    }
  }

  async handleUseExistingStory() {
    if (!this.selectedUserStoryId) {
      this.showToast('Select a story', 'Pick an existing Copado User Story first.', 'warning');
      return;
    }
    this.isLoading = true;
    this.waitingLabel = 'Loading existing story';
    try {
      const result = await openCopadoUserStory({
        sessionId: this.sessionId,
        userStoryId: this.selectedUserStoryId
      });
      if (result?.success) {
        this.applySession(result.session);
        this.isChangingStory = false;
        this.showToast('Success', result.message || 'Story loaded.', 'success');
        await Promise.all([this.loadProjects(), this.loadOrgs(), this.loadChatSessions()]);
      } else {
        this.showToast('Notice', result?.message || 'Could not open story.', 'warning');
      }
    } catch (error) {
      this.showError(error);
    } finally {
      this.isLoading = false;
      this.waitingLabel = 'Copado is thinking';
    }
  }

  async loadChatSessions() {
    try {
      this.chatSessions = await getMySessions();
    } catch (error) {
      // History is non-critical
    }
  }

  applySession(session) {
    if (!session) return;
    this.sessionId = session.sessionId;
    this.messages = session.messages || [];
    this.score = session.score || 0;
    this.currentStep = session.currentStep || 'Discovery';
    this.missingInfo = session.missingInfo || [];
    this.orgContextStatus = session.orgContextStatus || 'Not connected';
    this.orgIntelligenceIntegrationId = session.orgIntelligenceIntegrationId || '';
    this.connectedOrgId = session.connectedOrgId || '';
    this.connectedOrgName = session.connectedOrgName || '';
    if (
      this.orgIntelligenceIntegrationId
      && this.integrationOptions.some((o) => o.value === this.orgIntelligenceIntegrationId)
    ) {
      this.selectedIntegrationId = this.orgIntelligenceIntegrationId;
    }
    this.buildStatus = session.buildStatus || 'Not ready';
    this.testStatus = session.testStatus || 'Not ready';
    this.deployStatus = session.deployStatus || 'Not ready';
    this.buildStepStatus = session.buildStepStatus || this.buildStatus || 'Not ready';
    this.deployStepStatus = session.deployStepStatus || this.deployStatus || 'Not ready';
    this.commitStepStatus = session.commitStepStatus
      || (session.commitSucceeded ? 'Successful' : 'Not ready');
    this.validateStepStatus = session.validateStepStatus || 'Not ready';
    this.nextDeployStepStatus = session.nextDeployStepStatus || 'Not ready';
    this.pipelineErrorDetail = session.pipelineErrorDetail || '';
    this.pipelineErrorJobId = session.pipelineErrorJobId || '';
    this.pipelineErrorAction = session.pipelineErrorAction || '';
    this.copadoUserStory = session.copadoUserStory || '';
    this.storyRecordId = session.storyRecordId || '';
    this.storyName = session.storyName || this.parseStoryNumber(session.copadoUserStory);
    this.storyTitle = session.storyTitle || '';
    this.hasStory = !!this.copadoUserStory;
    if (this.hasStory) {
      this.isChangingStory = false;
    }
    if (session.projectId && this.projectOptions.some((o) => o.value === session.projectId)) {
      this.selectedProjectId = session.projectId;
    }
    if (session.selectedOrgId) {
      this.selectedOrgId = session.selectedOrgId;
    }
    this.lastBuildId = session.lastBuildId || '';
    this.lastJobId = session.lastJobId || '';
    this.lastJobStatus = session.lastJobStatus || '';
    this.lastJobSummary = session.lastJobSummary || '';
    this.lastJobFailed = session.lastJobFailed === true;
    this.lastJobComplete = session.lastJobComplete === true;
    this.lastJobAction = session.lastJobAction || '';
    this.lastPromotionId = session.lastPromotionId || '';
    this.lastDeployJobId = session.lastDeployJobId || '';
    this.lastCommitJobId = session.lastCommitJobId || '';
    this.deploySucceeded = session.deploySucceeded === true;
    this.commitSucceeded = session.commitSucceeded === true;
    this.canValidate = session.canValidate === true;
    this.canDeployNext = session.canDeployNext === true;
    this.canCheckDeployment = session.canCheckDeployment === true;
    this.nextEnvironmentId = session.nextEnvironmentId || '';
    this.nextEnvironmentName = session.nextEnvironmentName || '';
    this.buildArtifacts = session.buildArtifacts || [];
    // Stop polling as soon as the job reaches a terminal state.
    if (this.lastJobComplete || this.lastJobFailed) {
      this.clearJobPoll();
    }
    // Prefer linked story record for the update picker
    if (session.storyRecordId) {
      this.selectedUserStoryId = session.storyRecordId;
    }
    if (session.syncOrgIntelligenceSuggested === true) {
      // Fire-and-forget: re-bind User Level to the new env (int) after promote.
      Promise.resolve().then(() => this.syncOrgIntelligenceToSessionOrg());
    }
  }

  /**
   * After Deploy-to-next advances Org Context, push the same credential onto the
   * Copado AI User Level integration so Check deployment / chat hit the right org.
   */
  async syncOrgIntelligenceToSessionOrg() {
    const envId = this.connectedOrgId || this.selectedOrgId;
    if (!this.sessionId || !envId || this._oiSyncInFlight) {
      return;
    }
    this._oiSyncInFlight = true;
    try {
      const result = await connectOrgIntelligence({
        sessionId: this.sessionId,
        environmentId: envId,
        askProbeQuestion: false,
        preferredIntegrationId: this.orgIntelligenceIntegrationId || this.selectedIntegrationId || null
      });
      if (result?.session) {
        // Avoid re-entering sync from syncOrgIntelligenceSuggested.
        const { syncOrgIntelligenceSuggested, ...rest } = result.session;
        this.applySession({ ...rest, syncOrgIntelligenceSuggested: false });
      }
      if (result?.success) {
        this.showToast(
          'Org Intelligence',
          result.message || `Bound to ${this.connectedOrgName || envId}.`,
          'success'
        );
      }
    } catch (error) {
      this.showToast(
        'Org Intelligence',
        'Could not auto-update User Level. Open Org Context (pencil) and click Update OI.',
        'warning'
      );
    } finally {
      this._oiSyncInFlight = false;
    }
  }

  messagesRenderKey() {
    const parts = (this.messages || []).map(
      (msg) => `${msg.role || ''}:${msg.message || ''}`
    );
    return [
      parts.join('\u0001'),
      this.pendingUserMessage || '',
      this.isLoading ? '1' : '0',
      this.waitingLabel || ''
    ].join('\u0002');
  }

  renderMessages() {
    const container = this.template.querySelector('.chat-messages');
    if (!container) return;

    const key = this.messagesRenderKey();
    if (key === this._lastMessagesKey) {
      return;
    }
    this._lastMessagesKey = key;

    container.innerHTML = '';
    this.messages.forEach((msg) => {
      const bubble = document.createElement('div');
      const role = (msg.role || 'assistant').toLowerCase();
      bubble.className = `message-bubble message-${role}`;
      if (role === 'assistant' || role === 'system') {
        bubble.innerHTML = this.formatCopadoAiHtml(msg.message || '');
      } else {
        bubble.textContent = msg.message || '';
      }
      container.appendChild(bubble);
    });

    // Optimistic user bubble while waiting for Apex round-trip
    if (this.pendingUserMessage) {
      const pending = document.createElement('div');
      pending.className = 'message-bubble message-user';
      pending.textContent = this.pendingUserMessage;
      container.appendChild(pending);
    }

    // Inline typing indicator instead of full-screen spinner
    if (this.isLoading) {
      const typing = document.createElement('div');
      typing.className = 'message-bubble message-assistant message-typing';
      typing.setAttribute('aria-live', 'polite');
      typing.innerHTML =
        `<span class="typing-label">${this.escapeHtml(this.waitingLabel)}</span>` +
        '<span class="typing-dots" aria-hidden="true"><span></span><span></span><span></span></span>';
      container.appendChild(typing);
    }

    const anchor = document.createElement('div');
    anchor.className = 'chat-scroll-anchor';
    anchor.setAttribute('aria-hidden', 'true');
    container.appendChild(anchor);

    this.scrollChatToBottom();
  }

  /**
   * Render Copado AI-style markdown lightly: agent label, bold, bullets, paragraphs.
   * Package JSON / escaped XML dumps are summarized — never shown raw.
   */
  formatCopadoAiHtml(raw) {
    if (!raw) return '';
    let text = String(raw).replace(/\r\n/g, '\n');

    // Leading _Build Agent_ / _Plan Agent_ style labels → badge
    let agentBadge = '';
    const agentMatch = text.match(/^_([^_\n]+)_\s*\n+/);
    if (agentMatch) {
      agentBadge = `<div class="msg-agent">${this.escapeHtml(agentMatch[1])}</div>`;
      text = text.slice(agentMatch[0].length);
    }

    const packageSummary = this.summarizePackageDumpForDisplay(text);
    if (packageSummary) {
      text = packageSummary;
    } else if (text.includes('\\n') && (text.match(/\\n/g) || []).length > 8) {
      // JSON-escaped content that leaked into chat as a single blob
      text = text.replace(/\\n/g, '\n').replace(/\\t/g, '  ');
      if (text.length > 2500 || /<(CustomObject|Layout|fields)\b/i.test(text)) {
        text =
          'I prepared Salesforce metadata for this story. '
          + 'Click **Build** to capture the package — raw XML is hidden from chat.';
      }
    }

    const escaped = this.escapeHtml(text);
    const withBold = escaped.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    const lines = withBold.split('\n');
    const htmlParts = [];
    let inList = false;

    const closeList = () => {
      if (inList) {
        htmlParts.push('</ul>');
        inList = false;
      }
    };

    lines.forEach((line) => {
      const bullet = line.match(/^\s*[-•]\s+(.*)$/);
      if (bullet) {
        if (!inList) {
          htmlParts.push('<ul class="msg-list">');
          inList = true;
        }
        htmlParts.push(`<li>${bullet[1]}</li>`);
        return;
      }
      closeList();
      if (line.trim() === '') {
        htmlParts.push('<div class="msg-gap"></div>');
      } else {
        htmlParts.push(`<p class="msg-p">${line}</p>`);
      }
    });
    closeList();

    return agentBadge + htmlParts.join('');
  }

  /**
   * If the bubble is raw package JSON, show a short file list instead of XML.
   */
  summarizePackageDumpForDisplay(text) {
    if (!text || text.length < 40) {
      return null;
    }
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }
    let parsed;
    try {
      parsed = JSON.parse(text.slice(start, end + 1));
    } catch (e) {
      return null;
    }
    if (!parsed || !Array.isArray(parsed.files) || parsed.files.length === 0) {
      return null;
    }
    const paths = parsed.files
      .map((f) => (f && f.path ? String(f.path) : ''))
      .filter(Boolean);
    if (!paths.length) {
      return null;
    }
    const summary =
      (parsed.summary && String(parsed.summary).trim())
      || `Prepared a metadata package with ${paths.length} file${paths.length === 1 ? '' : 's'}.`;
    const shown = paths.slice(0, 8);
    const extra = paths.length > shown.length
      ? `\n- …and ${paths.length - shown.length} more`
      : '';
    return (
      `${summary}\n\n**Files**\n`
      + shown.map((p) => `- ${p}`).join('\n')
      + extra
      + '\n\nClick **Build** when you are ready to capture this package in Builder.'
    );
  }

  scrollChatToBottom() {
    if (this._scrollRaf) {
      cancelAnimationFrame(this._scrollRaf);
    }
    const run = () => {
      const container = this.template.querySelector('.chat-messages');
      if (!container) return;
      // Only scroll the chat pane — never scrollIntoView (that can jump the page)
      container.scrollTop = container.scrollHeight;
    };
    // Double rAF so layout (and typing bubble) settles before scrolling
    this._scrollRaf = requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        run();
        // One more tick for Lightning layout / toast chrome
        window.setTimeout(run, 50);
      });
    });
  }

  escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  beginWaiting(label, pendingUserMessage = '') {
    this.clearWaitingTimer();
    this.isLoading = true;
    this.waitingLabel = label || 'Copado is thinking';
    this.pendingUserMessage = pendingUserMessage || '';
    this._waitingTimer = window.setTimeout(() => {
      this.waitingLabel = 'Still working — Copado AI can take a bit';
    }, 15000);
    // Ensure latest content stays visible when actions start
    Promise.resolve().then(() => this.scrollChatToBottom());
  }

  endWaiting() {
    this.clearWaitingTimer();
    this.isLoading = false;
    this.pendingUserMessage = '';
    this.waitingLabel = 'Copado is thinking';
    Promise.resolve().then(() => this.scrollChatToBottom());
  }

  clearWaitingTimer() {
    if (this._waitingTimer) {
      window.clearTimeout(this._waitingTimer);
      this._waitingTimer = undefined;
    }
  }

  handleInputChange(event) {
    this.inputMessage = event.target.value;
  }

  handleKeyDown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      this.handleSend();
    }
  }

  async handleSend() {
    const text = this.inputMessage?.trim();
    if (!text || this.isLoading) return;

    this.inputMessage = '';
    this._sendGeneration = (this._sendGeneration || 0) + 1;
    const gen = this._sendGeneration;
    this.beginWaiting('Copado is thinking', text);
    try {
      const session = await sendMessage({
        sessionId: this.sessionId,
        message: text,
        // Only the session's connected OI id — never the picker leftover from another chat.
        orgIntelligenceIntegrationId: this.orgIntelligenceIntegrationId || null,
        orgCredentialId: this.selectedOrgId || null
      });
      if (gen !== this._sendGeneration) {
        return;
      }
      this.applySession(session);
      if (session?.awaitingAiReply) {
        this.beginWaiting('Waiting for Copado AI reply');
        await this.pollAiUntilReady(
          session.dialogueId,
          session.aiRequestId,
          session.aiBaselineMessageCount,
          session.aiBaselineAssistantText,
          gen
        );
      }
    } catch (error) {
      if (gen === this._sendGeneration) {
        this.showError(error);
      }
    } finally {
      if (gen === this._sendGeneration) {
        this.endWaiting();
        this.loadChatSessions();
      }
    }
  }

  handleStopWaiting() {
    this._sendGeneration = (this._sendGeneration || 0) + 1;
    this._buildGeneration = (this._buildGeneration || 0) + 1;
    this.clearAiPoll();
    this.clearBuildPoll();
    this.endWaiting();
    this.showToast('Stopped', 'Stopped waiting for Copado AI. You can send again.', 'info');
    this.loadChatSessions();
  }

  clearAiPoll() {
    if (this._aiPollTimer) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      clearTimeout(this._aiPollTimer);
      this._aiPollTimer = null;
    }
    this._aiPollAttempts = 0;
  }

  async pollAiUntilReady(
    dialogueId,
    requestId,
    baselineMessageCount,
    baselineAssistantText,
    generation
  ) {
    this.clearAiPoll();
    // Org Intelligence tool turns often need 1–2 minutes after an empty 201 body.
    const maxAttempts = 60; // ~2 min at 2s interval
    for (let i = 0; i < maxAttempts; i++) {
      if (generation != null && generation !== this._sendGeneration) {
        return;
      }
      this._aiPollAttempts = i + 1;
      if (i > 0) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        await new Promise((resolve) => {
          this._aiPollTimer = setTimeout(resolve, 2000);
        });
      }
      if (generation != null && generation !== this._sendGeneration) {
        return;
      }
      const timedOut = i === maxAttempts - 1;
      if (i === 0) {
        this.beginWaiting('Waiting for Copado AI reply');
      } else if (i === 15) {
        this.beginWaiting('Still waiting on Copado AI');
      } else if (i === 35) {
        this.beginWaiting('Almost there — still polling for the reply');
      }
      try {
        const session = await pollAiReply({
          sessionId: this.sessionId,
          dialogueId: dialogueId || null,
          requestId: requestId || null,
          assistantId: 'build',
          timedOut,
          baselineMessageCount:
            baselineMessageCount == null ? null : baselineMessageCount,
          baselineAssistantText: baselineAssistantText || null
        });
        if (generation != null && generation !== this._sendGeneration) {
          return;
        }
        this.applySession(session);
        if (!session?.awaitingAiReply) {
          this.clearAiPoll();
          return;
        }
      } catch (error) {
        if (generation != null && generation !== this._sendGeneration) {
          return;
        }
        this.clearAiPoll();
        this.showError(error);
        return;
      }
    }
    this.clearAiPoll();
  }

  async handleImproveStory() {
    this.scrollChatToBottom();
    if (this.hasStory) {
      const storyLabel = this.linkedStoryNumber || this.copadoUserStory || 'the linked story';
      this.openConfirm({
        title: 'Improve Story',
        message:
          `Update ${storyLabel} from this chat?\n\n`
          + 'Copado Builder will structure the chat into User Story fields '
          + '(title, persona, acceptance criteria, specs) and write them onto the linked Copado User Story.',
        confirmLabel: 'Improve Story',
        action: 'improve'
      });
      return;
    }
    await this.runAction(
      () => improveStory({ sessionId: this.sessionId }),
      'Improving your story'
    );
  }

  async handleCreateStory() {
    this.scrollChatToBottom();
    if (!this.selectedProjectId) {
      this.showToast(
        'Select a project',
        'Choose a Copado Project in the Status panel. Dev1 must belong to that project’s pipeline.',
        'warning'
      );
      return;
    }
    await this.runAction(
      () =>
        createCopadoStory({
          sessionId: this.sessionId,
          updateExisting: false,
          targetStoryId: null,
          projectId: this.selectedProjectId
        }),
      'Creating Copado story'
    );
    await Promise.all([this.loadChatSessions(), this.loadUserStories(), this.loadProjects()]);
    await this.loadOrgs();
  }

  handleBuildCode() {
    this.scrollChatToBottom();
    if (!this.hasStory) {
      this.showToast(
        'Link a story first',
        'Create Story or Use Story before building.',
        'warning'
      );
      return;
    }
    this.confirmAndBuild();
  }

  confirmAndBuild() {
    const storyLabel = this.linkedStoryNumber || this.copadoUserStory || 'the linked story';
    const prior =
      this.hasBuildArtifacts
        ? '\n\nThis will replace the current artifacts ('
          + (this.artifactsDisplay || 'previous package')
          + ') with a new package and clear Deploy/Commit progress.'
        : '';
    this.openConfirm({
      title: 'Build',
      message:
        `Build metadata for ${storyLabel}?${prior}\n\n`
        + 'Copado Builder will generate the Salesforce metadata package for this story.\n'
        + 'It will not deploy or commit yet — use Deploy, then Commit, when ready.',
      confirmLabel: 'Build',
      action: 'build'
    });
  }

  async executeBuildCode() {
    // Optimistic Status panel: rebuild must leave Successful immediately.
    this.buildStepStatus = 'In progress';
    this.buildStatus = 'In progress';
    this.currentStep = 'Building';
    this.deployStepStatus = 'Not ready';
    this.commitStepStatus = 'Not ready';
    this.validateStepStatus = 'Not ready';
    this.nextDeployStepStatus = 'Not ready';
    this.canDeployNext = false;
    this.canCheckDeployment = false;
    this.pipelineErrorDetail = '';
    this.pipelineErrorJobId = '';
    this.pipelineErrorAction = '';
    // Only pass env ids that appear in the validated Environment list.
    const envId =
      this.selectedOrgId
      && (this.orgOptions || []).some((o) => o.value === this.selectedOrgId)
        ? this.selectedOrgId
        : null;
    this._buildGeneration = (this._buildGeneration || 0) + 1;
    const gen = this._buildGeneration;
    this.beginWaiting('Building metadata');
    try {
      const result = await buildCode({
        sessionId: this.sessionId,
        environmentId: envId,
        rememberPreference: this.rememberEnvironment && !!envId
      });
      if (gen !== this._buildGeneration) {
        return;
      }
      if (result?.session) {
        this.applySession(result.session);
      }
      if (result?.awaitingBuild) {
        this.beginWaiting('Waiting for Copado AI package');
        await this.pollBuildUntilReady(gen);
        return;
      }
      if (result?.success) {
        this.showToast('Success', result.message || 'Done.', 'success');
      } else {
        this.showToast('Notice', result?.message || 'Action did not complete.', 'warning');
      }
    } catch (error) {
      if (gen === this._buildGeneration) {
        this.showError(error);
        this.buildStepStatus = 'Failed';
        this.buildStatus = 'Failed';
      }
    } finally {
      if (gen === this._buildGeneration) {
        this.endWaiting();
        this.loadChatSessions();
        await this.loadOrgs();
      }
    }
  }

  clearBuildPoll() {
    if (this._buildPollTimer) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      clearTimeout(this._buildPollTimer);
      this._buildPollTimer = null;
    }
  }

  async pollBuildUntilReady(generation) {
    this.clearBuildPoll();
    // Match Apex ~8 minute pending window (~2s interval) for large packages.
    const maxAttempts = 240;
    for (let i = 0; i < maxAttempts; i++) {
      if (generation != null && generation !== this._buildGeneration) {
        return;
      }
      if (i > 0) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        await new Promise((resolve) => {
          this._buildPollTimer = setTimeout(resolve, 2000);
        });
      }
      if (generation != null && generation !== this._buildGeneration) {
        return;
      }
      if (i === 0) {
        this.beginWaiting('Waiting for Copado AI package');
      } else if (i === 30) {
        this.beginWaiting('Still generating metadata package');
      } else if (i === 90) {
        this.beginWaiting('Large package — still waiting on package JSON');
      } else if (i === 150) {
        this.beginWaiting('Almost there — still waiting on package JSON');
      }
      try {
        const result = await pollBuildPackage({ sessionId: this.sessionId });
        if (generation != null && generation !== this._buildGeneration) {
          return;
        }
        if (result?.session) {
          this.applySession(result.session);
        }
        if (!result?.awaitingBuild) {
          this.clearBuildPoll();
          if (result?.success) {
            this.showToast('Success', result.message || 'Build complete.', 'success');
          } else {
            this.showToast(
              'Notice',
              result?.message || 'Build did not complete.',
              'warning'
            );
            if ((this.buildStepStatus || '').toLowerCase() === 'in progress') {
              this.buildStepStatus = 'Failed';
              this.buildStatus = 'Failed';
            }
          }
          return;
        }
      } catch (error) {
        if (generation != null && generation !== this._buildGeneration) {
          return;
        }
        this.clearBuildPoll();
        this.showError(error);
        this.buildStepStatus = 'Failed';
        this.buildStatus = 'Failed';
        return;
      }
    }
    this.clearBuildPoll();
    this.showToast(
      'Notice',
      'Build timed out waiting for Copado AI. Wait a moment, then click Build once more.',
      'warning'
    );
    this.buildStepStatus = 'Failed';
    this.buildStatus = 'Failed';
  }

  async handleRefreshJobStatus() {
    if (!this.sessionId) {
      return;
    }
    // Allow refresh during Validate/Deploy-next even when Last_Job_Id was cleared
    // (queueable placeholder) — Apex adopts the Promotion JE or heals status.
    const validateInFlight =
      (this.validateStepStatus || '').toLowerCase() === 'in progress'
      || (this.nextDeployStepStatus || '').toLowerCase() === 'in progress';
    const stepInFlight =
      (this.buildStepStatus || '').toLowerCase() === 'in progress'
      || (this.deployStepStatus || '').toLowerCase() === 'in progress'
      || (this.commitStepStatus || '').toLowerCase() === 'in progress'
      || validateInFlight;
    if (!this.lastJobId && stepInFlight) {
      try {
        const session = await openSession({ sessionId: this.sessionId });
        this.applySession(session);
      } catch (ignore) {
        // continue — refreshJobStatus may still heal
      }
    }
    if (!this.lastJobId && !validateInFlight) {
      this.showToast(
        'Notice',
        'No Copado job on this chat yet. Run Deploy, Commit, or Validate first.',
        'warning'
      );
      return;
    }
    await this.runAction(
      () => refreshJobStatus({ sessionId: this.sessionId }),
      'Checking job status'
    );
    if (!this.lastJobComplete && !this.lastJobFailed && this.lastJobId) {
      this.startJobPoll();
    }
  }

  async handleLinkUserStoryCommit() {
    if (!this.sessionId || !this.lastJobId) {
      return;
    }
    let commitSha = '';
    // If auto-link failed previously due to missing SHA, let the user paste it from the job log.
    if (
      (this.lastJobSummary || '').includes('No SHA found')
      || (this.lastJobSummary || '').includes('could not create/find Snapshot Commit')
    ) {
      commitSha = window.prompt(
        'Paste the git commit SHA from the Copado job log (git rev-parse HEAD line), or leave blank to retry auto-detect:',
        ''
      );
      if (commitSha === null) {
        return;
      }
      commitSha = (commitSha || '').trim();
    }
    await this.runAction(
      () =>
        linkUserStoryCommitFromLastJob({
          sessionId: this.sessionId,
          commitSha: commitSha || null
        }),
      'Linking User Story Commit'
    );
  }

  startJobPoll() {
    this.clearJobPoll();
    const queuedPlaceholder =
      typeof this.lastJobId === 'string'
      && (this.lastJobId.startsWith('validate-queued')
        || this.lastJobId.startsWith('deploy-next-queued'));
    // Keep polling while Validate/Deploy-next is async-starting even if Last_Job_Id
    // is a placeholder — otherwise the queueable System message never appears.
    if (
      !this.sessionId
      || this.lastJobComplete
      || this.lastJobFailed
      || (!this.lastJobId && !queuedPlaceholder)
    ) {
      return;
    }

    this._jobPollStartedAt = Date.now();
    this._jobPollInFlight = false;
    const maxMs = 10 * 60 * 1000; // hard ceiling only — stop earlier when ready

    const scheduleNext = (delayMs) => {
      this._jobPollTimer = window.setTimeout(pollOnce, delayMs);
    };

    const pollOnce = async () => {
      this._jobPollTimer = null;

      if (this.lastJobComplete || this.lastJobFailed) {
        return;
      }
      if (Date.now() - this._jobPollStartedAt > maxMs) {
        this.showToast(
          'Job still running',
          'Polling timed out. Use Refresh job status or Link commit to story when it finishes.',
          'info'
        );
        return;
      }
      if (this._jobPollInFlight) {
        scheduleNext(3000);
        return;
      }

      this._jobPollInFlight = true;
      try {
        const result = await refreshJobStatus({ sessionId: this.sessionId });
        if (result?.session) {
          this.applySession(result.session);
        }
        // Queueable finished with no JE: Last_Job_Id cleared + System diagnostics.
        if (!this.lastJobId && !this.lastJobComplete && !this.lastJobFailed) {
          this.lastJobFailed = true;
          this.clearJobPoll();
          return;
        }
        // Ready — stop immediately (applySession also clears the timer).
        if (this.lastJobComplete || this.lastJobFailed) {
          return;
        }
      } catch (error) {
        // Transient errors: keep trying until the ceiling.
      } finally {
        this._jobPollInFlight = false;
      }

      if (this.lastJobComplete || this.lastJobFailed) {
        return;
      }

      // Still in progress: poll faster early, then every 10s.
      const elapsed = Date.now() - this._jobPollStartedAt;
      const delayMs = elapsed < 90 * 1000 ? 5000 : 10000;
      scheduleNext(delayMs);
    };

    // First check soon after the job is queued.
    scheduleNext(3000);
  }

  clearJobPoll() {
    if (this._jobPollTimer) {
      window.clearTimeout(this._jobPollTimer);
      this._jobPollTimer = null;
    }
    this._jobPollInFlight = false;
  }

  handleDeployClick() {
    this.scrollChatToBottom();
    if (!this.selectedOrgId) {
      this.showToast(
        'Select a Dev environment',
        'Choose which Dev org to deploy into in the Status panel.',
        'warning'
      );
      return;
    }
    if (!this.hasBuildArtifacts) {
      this.showToast('Build first', 'Run Build so there is a package to deploy.', 'warning');
      return;
    }
    const orgName =
      this.orgOptions.find((o) => o.value === this.selectedOrgId)?.label || 'selected Dev environment';
    this.openConfirm({
      title: 'Deploy',
      message:
        `Deploy package to ${orgName}?\n\n`
        + 'This deploys the Build package into Dev only.\n'
        + 'It does not commit to Git — use Commit after you review / test in Dev.\n\n'
        + 'Watch Job Status until Deploy finishes successfully.',
      confirmLabel: 'Deploy',
      action: 'deploy'
    });
  }

  async executeDeploy() {
    await this.runAction(
      () =>
        deployToDev({
          sessionId: this.sessionId,
          orgId: this.selectedOrgId,
          confirmed: true,
          rememberPreference: this.rememberEnvironment
        }),
      'Deploying package to Dev'
    );
    await Promise.all([this.loadChatSessions(), this.loadOrgs()]);
    this.startJobPoll();
  }

  handleCommitClick() {
    this.scrollChatToBottom();
    if (!this.selectedOrgId) {
      this.showToast(
        'Select a Dev environment',
        'Choose which Dev org to commit from in the Status panel.',
        'warning'
      );
      return;
    }
    if (!this.deploySucceeded) {
      this.showToast(
        'Deploy first',
        'Wait for Deploy to succeed, then Commit from Dev to the user story.',
        'warning'
      );
      return;
    }
    const orgName =
      this.orgOptions.find((o) => o.value === this.selectedOrgId)?.label || 'selected Dev environment';
    this.openConfirm({
      title: 'Commit',
      message:
        `Commit to the user story from ${orgName}?\n\n`
        + 'Runs Copado commit (CommitAction or sfdx_commit_1).\n'
        + 'It does not re-deploy the package — Deploy must already have succeeded.\n\n'
        + 'Watch Job Status until Commit finishes.',
      confirmLabel: 'Commit',
      variant: 'commit',
      action: 'commit'
    });
  }

  async executeCommit(recreateFeatureBranch = false) {
    const recreate = recreateFeatureBranch === true;
    await this.runAction(
      () =>
        commitFromDev({
          sessionId: this.sessionId,
          environmentId: this.selectedOrgId,
          rememberPreference: this.rememberEnvironment,
          recreateFeatureBranch: recreate
        }),
      recreate
        ? 'Recreating feature branch and committing'
        : 'Committing from Dev to the user story'
    );
    await Promise.all([this.loadChatSessions(), this.loadOrgs()]);
    this.startJobPoll();
  }

  handleValidateClick() {
    this.scrollChatToBottom();
    if (!this.commitSucceeded) {
      this.showToast(
        'Commit first',
        'Validate requires a successful Commit before checking the next environment.',
        'warning'
      );
      return;
    }
    const nextLabel = this.nextEnvironmentName || 'the next pipeline environment';
    this.openConfirm({
      title: 'Validate',
      message:
        `Validate to ${nextLabel}?\n\n`
        + 'Runs Copado Validate (dry-run) toward the next environment.\n'
        + 'You stay in Copado Builder while jobs run.\n'
        + 'Destination org is not changed on a successful validation.',
      confirmLabel: 'Validate',
      action: 'validate'
    });
  }

  async executeValidate() {
    await this.runAction(
      () =>
        validateToNextEnvironment({
          sessionId: this.sessionId,
          confirmed: true
        }),
      'Validating to next environment'
    );
    await Promise.all([this.loadChatSessions(), this.loadOrgs()]);
    // Stay in Builder — do not auto-open a prior Draft Promotion (e.g. P00008) on failure.
    this.startJobPoll();
  }

  handleDeployNextClick() {
    this.scrollChatToBottom();
    const validateOk = (this.validateStepStatus || '').toLowerCase() === 'successful';
    if (!validateOk) {
      this.showToast(
        'Validate first',
        'Deploy to next requires Successful Validate Status.',
        'warning'
      );
      return;
    }
    const nextLabel = this.nextEnvironmentName || 'the next pipeline environment';
    this.openConfirm({
      title: 'Deploy to next',
      message:
        `Deploy to ${nextLabel}?\n\n`
        + 'Runs a real Copado deploy (not dry-run) toward the next pipeline environment.\n'
        + 'Requires Validate Status = Successful.\n\n'
        + 'Watch Job Status until the deploy finishes.',
      confirmLabel: 'Deploy',
      action: 'deployNext'
    });
  }

  async executeDeployNext() {
    await this.runAction(
      () =>
        deployToNextEnvironment({
          sessionId: this.sessionId,
          confirmed: true
        }),
      'Deploying to next environment'
    );
    await Promise.all([this.loadChatSessions(), this.loadOrgs()]);
    this.startJobPoll();
  }

  async handleCheckDeployment() {
    this.scrollChatToBottom();
    if (!this.canCheckDeployment) {
      this.showToast(
        'Not ready',
        'Need a linked story, Build artifacts, and a current environment.',
        'warning'
      );
      return;
    }
    this._sendGeneration = (this._sendGeneration || 0) + 1;
    const gen = this._sendGeneration;
    this.beginWaiting('Checking deployment in current org');
    try {
      const result = await checkDeployment({ sessionId: this.sessionId });
      if (gen !== this._sendGeneration) {
        return;
      }
      if (result?.session) {
        this.applySession(result.session);
      }
      if (result?.session?.awaitingAiReply) {
        this.beginWaiting('Waiting for Build Agent verification');
        await this.pollAiUntilReady(
          result.session.dialogueId,
          result.session.aiRequestId,
          result.session.aiBaselineMessageCount,
          result.session.aiBaselineAssistantText,
          gen
        );
      } else if (result?.success) {
        this.showToast('Success', result.message || 'Check complete.', 'success');
      } else {
        this.showToast('Notice', result?.message || 'Check did not complete.', 'warning');
      }
    } catch (error) {
      if (gen === this._sendGeneration) {
        await this.handleActionTransportError(error);
      }
    } finally {
      if (gen === this._sendGeneration) {
        this.endWaiting();
        this.loadChatSessions();
      }
    }
  }

  async openPromotionInNewTab() {
    await this.openPromotionRecordById(this.lastPromotionId);
  }

  openPromotionRecord() {
    // Keep for any older callers — open in a new tab so Builder stays put.
    this.openPromotionInNewTab();
  }

  async handlePendingOrgChange(event) {
    this.selectedOrgId = event.detail.value;
    // Persist as this user's default selection. Bind only when they click Update OI.
    try {
      if (this.selectedOrgId && this.rememberEnvironment) {
        await savePreferredEnvironment({
          environmentId: this.selectedOrgId,
          projectId: this.selectedProjectId || null
        });
      }
    } catch (ignore) {
      // Preference is best-effort
    }
  }

  handleStartOrgContextEdit() {
    this.isEditingOrgContext = true;
    // Seed the picker with the verified org when present; else keep preferred/selected.
    if (this.connectedOrgId) {
      this.selectedOrgId = this.connectedOrgId;
    }
  }

  handleCancelOrgContextEdit() {
    this.isEditingOrgContext = false;
    if (this.connectedOrgId) {
      this.selectedOrgId = this.connectedOrgId;
    }
  }

  async handleIntegrationChange(event) {
    this.selectedIntegrationId = event.detail.value;
    try {
      if (this.selectedIntegrationId) {
        await savePreferredIntegration({ integrationId: this.selectedIntegrationId });
        this.preferredIntegrationId = this.selectedIntegrationId;
      }
    } catch (error) {
      // Preference is best-effort
    }
  }

  async handleConnectOrgIntelligence() {
    if (this.setupOpen) {
      this.showToast(
        'Notice',
        'Finish setup: choose your Project and Copado AI Integration first.',
        'warning'
      );
      return;
    }
    if (!this.selectedOrgId) {
      this.showToast('Notice', 'Select a Dev environment first.', 'warning');
      this.isEditingOrgContext = true;
      return;
    }
    this.beginWaiting('Updating Org Intelligence');
    try {
      if (!this.integrationsLoaded) {
        await this.loadIntegrations();
      }
      const result = await connectOrgIntelligence({
        sessionId: this.sessionId,
        environmentId: this.selectedOrgId,
        // Do not smoke-test via extra Copado AI dialogues (that created OI Probe / org chat spam).
        askProbeQuestion: false,
        preferredIntegrationId: this.selectedIntegrationId || null
      });
      if (result?.session) {
        this.applySession(result.session);
      }
      if (result?.orgIntelligence?.integrationId) {
        this.orgIntelligenceIntegrationId = result.orgIntelligence.integrationId;
        this.selectedIntegrationId = result.orgIntelligence.integrationId;
      }
      if (result?.session?.orgContextStatus) {
        this.orgContextStatus = result.session.orgContextStatus;
      } else if (result?.success) {
        this.orgContextStatus = 'Connected';
      }
      if (result?.success) {
        this.showToast('Success', result.message || 'Org Intelligence updated.', 'success');
        this.orgContextStatus = 'Connected';
        this.connectedOrgId =
          result.session?.connectedOrgId || this.selectedOrgId || this.connectedOrgId;
        this.connectedOrgName =
          result.session?.connectedOrgName
          || this.orgOptions.find((o) => o.value === this.connectedOrgId)?.label
          || this.connectedOrgName;
        this.selectedOrgId = this.connectedOrgId || this.selectedOrgId;
        this.isEditingOrgContext = false;
        try {
          if (this.rememberEnvironment && this.connectedOrgId) {
            await savePreferredEnvironment({
              environmentId: this.connectedOrgId,
              projectId: this.selectedProjectId || null
            });
          }
        } catch (ignore) {
          // Preference is best-effort
        }
      } else {
        const detail =
          result?.message
          || 'Could not confirm Org Intelligence is bound to the selected credential.';
        this.showToast(
          'Update OI',
          `${detail} If it still shows the wrong org, reconnect the Org Credential in Copado AI Settings (your per-user PAT must own that integration).`,
          'warning'
        );
        this.isEditingOrgContext = true;
      }
      // Refresh list so status labels stay current
      await this.loadIntegrations();
    } catch (error) {
      this.showError(error);
      this.isEditingOrgContext = true;
    } finally {
      this.endWaiting();
    }
  }

  async handleProjectChange(event) {
    this.selectedProjectId = event.detail.value;
    this.selectedOrgId = '';
    this.isEditingOrgContext = true;
    try {
      if (this.selectedProjectId) {
        await savePreferredProject({ projectId: this.selectedProjectId });
      }
    } catch (error) {
      // Preference is best-effort; still reload orgs for the selected project
    }
    await this.loadOrgs();
  }

  handleRememberEnvironmentChange(event) {
    this.rememberEnvironment = event.target.checked;
  }

  handleUserStoryChange(event) {
    this.selectedUserStoryId = event.detail.value;
  }

  async runAction(actionFn, waitingLabel = 'Working on it') {
    this.beginWaiting(waitingLabel);
    try {
      const result = await actionFn();
      if (result?.session) {
        this.applySession(result.session);
      }
      if (result?.success) {
        this.showToast('Success', result.message || 'Done.', 'success');
      } else {
        this.showToast('Notice', result?.message || 'Action did not complete.', 'warning');
      }
    } catch (error) {
      await this.handleActionTransportError(error);
    } finally {
      this.endWaiting();
      this.loadChatSessions();
    }
  }

  /**
   * Salesforce gacks after Deploy/Commit often mean the JE already started but
   * session refresh blew limits. Recover quietly instead of a red Error toast.
   */
  async handleActionTransportError(error) {
    const message =
      error?.body?.message ||
      error?.body?.pageErrors?.[0]?.message ||
      error?.message ||
      '';
    const isGack = /internal server error|error id\s*:/i.test(String(message));
    if (isGack && this.sessionId) {
      this.showToast(
        'Notice',
        'Salesforce hit a limit refreshing status. The Copado job may already be running — checking…',
        'warning'
      );
      try {
        const session = await openSession({ sessionId: this.sessionId });
        this.applySession(session);
        if (this.lastJobId && !this.lastJobComplete && !this.lastJobFailed) {
          this.startJobPoll();
        }
        return;
      } catch (ignore) {
        // fall through to standard error
      }
    }
    this.showError(error);
  }

  reduceError(error) {
    return (
      error?.body?.message ||
      error?.body?.pageErrors?.[0]?.message ||
      error?.body?.fieldErrors?.[Object.keys(error?.body?.fieldErrors || {})[0]]?.[0]?.message ||
      error?.message ||
      (typeof error === 'string' ? error : null) ||
      JSON.stringify(error?.body || error) ||
      'Something went wrong.'
    );
  }

  showError(error) {
    this.showToast('Error', this.reduceError(error), 'error');
  }

  showToast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  get scoreDisplay() {
    return `${this.score}%`;
  }

  get scoreClass() {
    if (this.score >= 75) return 'status-value score-good';
    if (this.score >= 50) return 'status-value score-medium';
    return 'status-value score-low';
  }

  get missingInfoDisplay() {
    return this.missingInfo.length > 0 ? this.missingInfo.join(', ') : 'None';
  }

  get isCreateStoryDisabled() {
    return this.isLoading || this.score < 40 || !this.selectedProjectId;
  }

  get isUpdateStoryDisabled() {
    return this.isLoading || this.score < 40 || !this.selectedUserStoryId;
  }

  get showLinkStoryPicker() {
    return !this.hasStory;
  }

  get canEditLinkedStory() {
    return this.hasStory && !this.isChangingStory;
  }

  get showLinkedStoryTitle() {
    return !!this.linkedStoryTitle && !this.isChangingStory;
  }

  get isUseStoryDisabled() {
    return this.isLoading || !this.selectedUserStoryId;
  }

  get showProjectSelect() {
    return this.projectOptions.length > 0;
  }

  get hasBuildArtifacts() {
    return this.buildArtifacts && this.buildArtifacts.length > 0;
  }

  get artifactItems() {
    if (!this.buildArtifacts || this.buildArtifacts.length === 0) {
      return [];
    }
    return this.buildArtifacts.map((path, index) => {
      const full = String(path);
      const parts = full.split('/');
      const name = parts[parts.length - 1] || full;
      return {
        key: `${index}-${name}`,
        name,
        path: full
      };
    });
  }

  get artifactsAreStale() {
    return (
      this.hasBuildArtifacts
      && (this.buildStepStatus || this.buildStatus || '').toLowerCase() === 'not ready'
    );
  }

  get artifactsDisplay() {
    if (!this.buildArtifacts || this.buildArtifacts.length === 0) {
      return 'None';
    }
    const names = this.artifactItems.map((item) => item.name).join(', ');
    if (this.artifactsAreStale) {
      return names + ' (stale — click Build)';
    }
    return names;
  }

  /** Collapsed summary; expanded list shows each file name. */
  get artifactsOneLine() {
    const items = this.artifactItems || [];
    if (items.length === 0) {
      return 'None';
    }
    if (items.length === 1) {
      const name = items[0].name || '';
      return name.length > 22 ? `${name.slice(0, 20)}…` : name;
    }
    return `${items.length} files`;
  }

  get artifactsTooltip() {
    return (this.buildArtifacts || []).join('\n');
  }

  get artifactsChevronIcon() {
    return this.artifactsExpanded
      ? 'utility:chevrondown'
      : 'utility:chevronright';
  }

  get artifactsToggleTitle() {
    return this.artifactsExpanded
      ? 'Hide artifact file names'
      : 'Show artifact file names';
  }

  handleToggleArtifacts() {
    this.artifactsExpanded = !this.artifactsExpanded;
  }

  stepStatusClass(value) {
    const v = (value || '').toLowerCase();
    if (v === 'successful' || v === 'complete') {
      return 'status-value score-good';
    }
    if (v === 'failed') {
      return 'status-value score-low';
    }
    if (v === 'in progress' || v === 'ready') {
      return 'status-value score-medium';
    }
    return 'status-value';
  }

  /** Icon + click behavior for pipeline Status rows. */
  pipelineStatusVisual(status, { canLink = false, linkTitle = '' } = {}) {
    const v = (status || '').toLowerCase();
    const base = {
      status: status || 'Not ready',
      canLink: false,
      canRefresh: false,
      disabled: true
    };
    if (v === 'successful' || v === 'complete') {
      return {
        ...base,
        iconName: 'utility:success',
        iconClass: 'status-pipe-icon status-pipe-icon_success',
        buttonClass: canLink
          ? 'status-pipe-btn status-pipe-btn_link'
          : 'status-pipe-btn',
        title: canLink ? linkTitle || 'Successful — open record' : 'Successful',
        ariaLabel: canLink ? `Successful — ${linkTitle || 'open'}` : 'Successful',
        canLink,
        disabled: !canLink
      };
    }
    if (v === 'failed') {
      return {
        ...base,
        iconName: 'utility:error',
        iconClass: 'status-pipe-icon status-pipe-icon_failed',
        buttonClass: canLink
          ? 'status-pipe-btn status-pipe-btn_link'
          : 'status-pipe-btn',
        title: canLink ? linkTitle || 'Failed — open record' : 'Failed',
        ariaLabel: canLink ? `Failed — ${linkTitle || 'open'}` : 'Failed',
        canLink,
        disabled: !canLink
      };
    }
    if (v === 'in progress') {
      return {
        ...base,
        iconName: 'utility:sync',
        iconClass: 'status-pipe-icon status-pipe-icon_progress status-pipe-icon_spin',
        buttonClass: canLink
          ? 'status-pipe-btn status-pipe-btn_link status-pipe-btn_action'
          : 'status-pipe-btn status-pipe-btn_action',
        title: canLink
          ? linkTitle || 'In progress — open record'
          : 'In progress — click to refresh',
        ariaLabel: canLink
          ? `In progress — ${linkTitle || 'open record'}`
          : 'In progress — refresh job status',
        // Prefer opening the live job/promotion; polling already refreshes status.
        canLink,
        canRefresh: !canLink,
        disabled: false
      };
    }
    if (v === 'ready') {
      return {
        ...base,
        iconName: 'utility:routing_offline',
        iconClass: 'status-pipe-icon status-pipe-icon_ready',
        buttonClass: 'status-pipe-btn',
        title: 'Ready',
        ariaLabel: 'Ready',
        disabled: true
      };
    }
    // Not ready / unknown — quiet hollow mark
    return {
      ...base,
      iconName: 'utility:record',
      iconClass: 'status-pipe-icon status-pipe-icon_idle',
      buttonClass: 'status-pipe-btn',
      title: status || 'Not ready',
      ariaLabel: status || 'Not ready',
      disabled: true
    };
  }

  /** True for a real Salesforce Id (15/18), not mock/queued placeholders. */
  isSalesforceRecordId(value) {
    const id = (value || '').trim();
    return (
      !!id
      && !id.startsWith('mock')
      && !id.startsWith('validate-queued')
      && !id.startsWith('deploy-next-queued')
      && !id.startsWith('create-execution-pending')
      && !id.startsWith('pending')
      && !id.startsWith('story-linked')
      && /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(id)
    );
  }

  pickFirstRecordId(...candidates) {
    for (const candidate of candidates) {
      if (this.isSalesforceRecordId(candidate)) {
        return String(candidate).trim();
      }
    }
    return '';
  }

  stepStatusAllowsRecordLink(status) {
    const v = (status || '').toLowerCase();
    return v === 'failed' || v === 'successful' || v === 'complete' || v === 'in progress';
  }

  get deployJobRecordId() {
    const action = (this.lastJobAction || '').toLowerCase();
    return this.pickFirstRecordId(
      this.lastDeployJobId,
      action === 'deploy' ? this.lastJobId : null
    );
  }

  get commitJobRecordId() {
    const action = (this.lastJobAction || '').toLowerCase();
    return this.pickFirstRecordId(
      this.lastCommitJobId,
      action === 'commit' ? this.lastJobId : null
    );
  }

  get showDeployStatusLink() {
    return (
      !!this.deployJobRecordId && this.stepStatusAllowsRecordLink(this.deployStepStatus)
    );
  }

  get showCommitStatusLink() {
    return (
      !!this.commitJobRecordId && this.stepStatusAllowsRecordLink(this.commitStepStatus)
    );
  }

  get buildStatusVisual() {
    // Build is AI package generation — no Copado Job Execution to open.
    return this.pipelineStatusVisual(this.buildStepStatus);
  }
  get buildStatusIconName() {
    return this.buildStatusVisual.iconName;
  }
  get buildStatusIconClass() {
    return this.buildStatusVisual.iconClass;
  }
  get buildStatusIconButtonClass() {
    return this.buildStatusVisual.buttonClass;
  }
  get buildStatusIconTitle() {
    return this.buildStatusVisual.title;
  }
  get buildStatusAriaLabel() {
    return this.buildStatusVisual.ariaLabel;
  }
  get buildStatusIconDisabled() {
    return this.buildStatusVisual.disabled;
  }
  handleBuildStatusIconClick() {
    if (this.buildStatusVisual.canRefresh) {
      this.handleRefreshJobStatus();
    }
  }

  get deployStatusVisual() {
    return this.pipelineStatusVisual(this.deployStepStatus, {
      canLink: this.showDeployStatusLink,
      linkTitle: 'Open Deploy Job Execution'
    });
  }
  get deployStatusIconName() {
    return this.deployStatusVisual.iconName;
  }
  get deployStatusIconClass() {
    return this.deployStatusVisual.iconClass;
  }
  get deployStatusIconButtonClass() {
    return this.deployStatusVisual.buttonClass;
  }
  get deployStatusIconTitle() {
    return this.deployStatusVisual.title;
  }
  get deployStatusAriaLabel() {
    return this.deployStatusVisual.ariaLabel;
  }
  get deployStatusIconDisabled() {
    return this.deployStatusVisual.disabled;
  }
  handleDeployStatusIconClick() {
    if (this.deployStatusVisual.canLink) {
      this.openJobExecutionById(this.deployJobRecordId);
      return;
    }
    if (this.deployStatusVisual.canRefresh) {
      this.handleRefreshJobStatus();
    }
  }

  get commitStatusVisual() {
    return this.pipelineStatusVisual(this.commitStepStatus, {
      canLink: this.showCommitStatusLink,
      linkTitle: 'Open Commit Job Execution'
    });
  }
  get commitStatusIconName() {
    return this.commitStatusVisual.iconName;
  }
  get commitStatusIconClass() {
    return this.commitStatusVisual.iconClass;
  }
  get commitStatusIconButtonClass() {
    return this.commitStatusVisual.buttonClass;
  }
  get commitStatusIconTitle() {
    return this.commitStatusVisual.title;
  }
  get commitStatusAriaLabel() {
    return this.commitStatusVisual.ariaLabel;
  }
  get commitStatusIconDisabled() {
    return this.commitStatusVisual.disabled;
  }
  handleCommitStatusIconClick() {
    if (this.commitStatusVisual.canLink) {
      this.openJobExecutionById(this.commitJobRecordId);
      return;
    }
    if (this.commitStatusVisual.canRefresh) {
      this.handleRefreshJobStatus();
    }
  }

  get validateStatusVisual() {
    return this.pipelineStatusVisual(this.validateStepStatus, {
      canLink: this.showValidateStatusLink,
      linkTitle: 'Open Promotion'
    });
  }
  get validateStatusIconName() {
    return this.validateStatusVisual.iconName;
  }
  get validateStatusIconClass() {
    return this.validateStatusVisual.iconClass;
  }
  get validateStatusIconButtonClass() {
    return this.validateStatusVisual.buttonClass;
  }
  get validateStatusIconTitle() {
    return this.validateStatusVisual.title;
  }
  get validateStatusAriaLabel() {
    return this.validateStatusVisual.ariaLabel;
  }
  get validateStatusIconDisabled() {
    return this.validateStatusVisual.disabled;
  }
  handleValidateStatusIconClick(event) {
    if (this.validateStatusVisual.canLink) {
      if (this.hasPromotionRecordLink) {
        this.handleOpenValidatePromotion(event);
      } else {
        this.openJobExecutionById(this.validateJobRecordId);
      }
      return;
    }
    if (this.validateStatusVisual.canRefresh) {
      this.handleRefreshJobStatus();
    }
  }

  get nextDeployStatusVisual() {
    return this.pipelineStatusVisual(this.nextDeployStepStatus, {
      canLink: this.showNextDeployStatusLink,
      linkTitle: 'Open Promotion'
    });
  }
  get nextDeployStatusIconName() {
    return this.nextDeployStatusVisual.iconName;
  }
  get nextDeployStatusIconClass() {
    return this.nextDeployStatusVisual.iconClass;
  }
  get nextDeployStatusIconButtonClass() {
    return this.nextDeployStatusVisual.buttonClass;
  }
  get nextDeployStatusIconTitle() {
    return this.nextDeployStatusVisual.title;
  }
  get nextDeployStatusAriaLabel() {
    return this.nextDeployStatusVisual.ariaLabel;
  }
  get nextDeployStatusIconDisabled() {
    return this.nextDeployStatusVisual.disabled;
  }
  handleNextDeployStatusIconClick(event) {
    if (this.nextDeployStatusVisual.canLink) {
      if (this.hasPromotionRecordLink) {
        this.handleOpenValidatePromotion(event);
      } else {
        this.openJobExecutionById(this.nextDeployJobRecordId);
      }
      return;
    }
    if (this.nextDeployStatusVisual.canRefresh) {
      this.handleRefreshJobStatus();
    }
  }

  get buildStepStatusClass() {
    return this.stepStatusClass(this.buildStepStatus);
  }

  get deployStepStatusClass() {
    return this.stepStatusClass(this.deployStepStatus);
  }

  get commitStepStatusClass() {
    return this.stepStatusClass(this.commitStepStatus);
  }

  get validateStepStatusClass() {
    return this.stepStatusClass(this.validateStepStatus);
  }

  get validateStatusLinkClass() {
    return `${this.validateStepStatusClass} story-hotlink status-job-link`;
  }

  /** Validate/Deploy-next outcomes live on the Promotion, not a single Promote JE. */
  get isPromotionPipelineAction() {
    const action = (this.pipelineErrorAction || this.lastJobAction || '').toLowerCase();
    return (
      action === 'validate'
      || action === 'deploynext'
      || action === 'deploy next'
    );
  }

  get hasPromotionRecordLink() {
    const id = (this.lastPromotionId || '').trim();
    return (
      !!id
      && !id.startsWith('mock')
      && /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(id)
    );
  }

  get showValidateStatusLink() {
    if (!this.stepStatusAllowsRecordLink(this.validateStepStatus)) {
      return false;
    }
    return this.hasPromotionRecordLink || !!this.validateJobRecordId;
  }

  /** Same Promotion record as Validate — deploy-to-next jobs live there too. */
  get showNextDeployStatusLink() {
    if (!this.stepStatusAllowsRecordLink(this.nextDeployStepStatus)) {
      return false;
    }
    return this.hasPromotionRecordLink || !!this.nextDeployJobRecordId;
  }

  get validateJobRecordId() {
    const action = (this.lastJobAction || '').toLowerCase();
    if (action === 'validate' || action === 'deploynext' || action === 'deploy next') {
      return this.pickFirstRecordId(this.lastJobId);
    }
    return '';
  }

  get nextDeployJobRecordId() {
    const action = (this.lastJobAction || '').toLowerCase();
    if (action === 'deploynext' || action === 'deploy next') {
      return this.pickFirstRecordId(this.lastJobId);
    }
    return '';
  }

  get nextDeployStatusLinkClass() {
    return `${this.nextDeployStepStatusClass} story-hotlink status-job-link`;
  }

  get nextDeployStepStatusClass() {
    return this.stepStatusClass(this.nextDeployStepStatus);
  }

  get showPipelineErrorPanel() {
    const validateFailed = (this.validateStepStatus || '').toLowerCase() === 'failed';
    const nextDeployFailed = (this.nextDeployStepStatus || '').toLowerCase() === 'failed';
    return !!(
      this.pipelineErrorDetail
      || this.lastJobFailed
      || validateFailed
      || nextDeployFailed
    );
  }

  get pipelineErrorLabel() {
    if ((this.validateStepStatus || '').toLowerCase() === 'failed') {
      return 'Validate error';
    }
    if ((this.nextDeployStepStatus || '').toLowerCase() === 'failed') {
      return 'DeployNext error';
    }
    const action = (this.pipelineErrorAction || this.lastJobAction || 'Job').trim();
    return action + ' error';
  }

  get pipelineErrorDetailLabel() {
    return this.usePromotionErrorLink
      ? 'Promotion detail'
      : 'Job Detail';
  }

  get pipelineErrorLinkTitle() {
    return this.usePromotionErrorLink
      ? 'Open Promotion (status, promote, and deploy jobs)'
      : 'Open Job Execution for error details';
  }

  /**
   * Same target as Validate Status: the Promotion record (never the Promote JE).
   * Do not require lastJobAction — after a failed validate, step may be Committed
   * while Last_Job_Id still points at the successful Promote Job Execution.
   */
  get usePromotionErrorLink() {
    if (!this.hasPromotionRecordLink) {
      return false;
    }
    // Mirror Validate Status link conditions.
    if (this.showValidateStatusLink) {
      return true;
    }
    const next = (this.nextDeployStepStatus || '').toLowerCase();
    if (next === 'failed' || next === 'successful' || next === 'in progress') {
      return true;
    }
    return this.isPromotionPipelineAction;
  }

  /** Record opened from the Failed link — Promotion for Validate/Deploy-next. */
  get pipelineErrorTargetId() {
    if (this.usePromotionErrorLink) {
      return (this.lastPromotionId || '').trim();
    }
    return (this.pipelineErrorJobId || this.lastJobId || '').trim();
  }

  get hasPipelineErrorRecordLink() {
    const id = (this.pipelineErrorTargetId || '').trim();
    return /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(id);
  }

  /** Refresh / Link commit while a job is running, failed, or needs USC recovery. */
  get showJobActions() {
    return this.showLinkCommitButton;
  }

  get showBuildRefresh() {
    return (this.buildStepStatus || '').toLowerCase() === 'in progress';
  }

  get showDeployRefresh() {
    return (this.deployStepStatus || '').toLowerCase() === 'in progress';
  }

  get showCommitRefresh() {
    return (this.commitStepStatus || '').toLowerCase() === 'in progress';
  }

  get showValidateRefresh() {
    return (this.validateStepStatus || '').toLowerCase() === 'in progress';
  }

  get showNextDeployRefresh() {
    return (this.nextDeployStepStatus || '').toLowerCase() === 'in progress';
  }

  get showOrgSelect() {
    // Available before a story exists — Org Intelligence improves discovery/requirements.
    return !!this.sessionId;
  }

  get showIntegrationSelect() {
    return this.showOrgSelect && this.integrationOptions.length > 0;
  }

  get orgSelectDisabled() {
    return this.orgOptions.length === 0;
  }

  /** Credential picker + Edit PAT / Update OI only after the pencil is clicked. */
  get showOrgContextEditor() {
    return this.isEditingOrgContext;
  }

  get showCancelOrgContextEdit() {
    return this.isEditingOrgContext && !!(this.connectedOrgId || this.selectedOrgId);
  }

  /** Edit PAT + Update OI appear only while the pencil editor is open. */
  get showOrgContextActionButtons() {
    return this.showOrgSelect && this.isEditingOrgContext;
  }

  parseStoryNumber(label) {
    if (!label) return '';
    const parts = String(label).split(' — ');
    return parts[0]?.trim() || label;
  }

  get linkedStoryNumber() {
    return this.storyName || this.parseStoryNumber(this.copadoUserStory);
  }

  get linkedStoryTitle() {
    return this.storyTitle || '';
  }

  async handleOpenLinkedStory(event) {
    if (event) {
      event.preventDefault();
    }
    if (!this.storyRecordId) return;
    try {
      const url = await this[NavigationMixin.GenerateUrl]({
        type: 'standard__recordPage',
        attributes: {
          recordId: this.storyRecordId,
          objectApiName: 'copado__User_Story__c',
          actionName: 'view'
        }
      });
      window.open(url, '_blank', 'noopener,noreferrer');
    } catch (error) {
      this.showError(error);
    }
  }

  async handleStartStoryEdit() {
    this.isChangingStory = true;
    try {
      await this.loadUserStories();
    } catch (error) {
      // Options may already be loaded; still show the editor.
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    window.setTimeout(() => {
      const combo = this.template.querySelector('[data-id="existing-story-combo"]');
      if (combo) {
        combo.focus();
      }
    }, 0);
  }

  handleCancelStoryEdit() {
    this.isChangingStory = false;
    this.selectedUserStoryId = this.storyRecordId || '';
  }

  handleChangeStory() {
    if (this.isChangingStory) {
      this.handleCancelStoryEdit();
      return;
    }
    this.handleStartStoryEdit();
  }

  get isOrgIntelligenceDisabled() {
    return this.isLoading || this.setupOpen || !this.selectedOrgId;
  }

  get orgIntelligenceButtonTitle() {
    return this.isOrgContextConnected
      ? 'Re-bind Org Intelligence to the selected Dev Org Credential, then verify the Copado AI integration matches'
      : 'Bind Org Intelligence to the selected Dev Org Credential using your per-user Copado AI PAT';
  }

  get selectedOrgLabel() {
    if (!this.selectedOrgId) {
      return '';
    }
    const match = (this.orgOptions || []).find((o) => o.value === this.selectedOrgId);
    return match?.label || this.selectedOrgId;
  }

  get connectedOrgLabel() {
    if (this.connectedOrgName) {
      return this.connectedOrgName;
    }
    if (!this.connectedOrgId) {
      return '';
    }
    const match = (this.orgOptions || []).find((o) => o.value === this.connectedOrgId);
    return match?.label || this.connectedOrgId;
  }

  get isOrgContextConnected() {
    return (this.orgContextStatus || '').toLowerCase() === 'connected';
  }

  get orgContextDisplay() {
    if (this.isOrgContextConnected) {
      return this.connectedOrgLabel || 'Connected';
    }
    // Prefill label (e.g. last-used / preferred dev1) — not green until Update OI succeeds.
    return this.selectedOrgLabel || 'Not connected';
  }

  get orgContextTitle() {
    if (!this.isOrgContextConnected) {
      if (!this.selectedOrgLabel) {
        return 'Select a Dev Org Credential you own, then click Update OI.';
      }
      return `${this.selectedOrgLabel} is selected but Org Intelligence is not bound yet. Click the pencil, then Update OI.`;
    }
    return `Connected to ${this.connectedOrgLabel || 'Dev'} via Copado Org Intelligence. Use the pencil to change.`;
  }

  get orgContextStatusClass() {
    return this.isOrgContextConnected
      ? 'status-value status-connected'
      : 'status-value status-disconnected';
  }

  get isBuildDisabled() {
    return this.isLoading || this.setupOpen || !this.hasStory;
  }

  get isDeployDisabled() {
    return (
      this.isLoading
      || !this.hasStory
      || !this.selectedOrgId
      || !this.hasBuildArtifacts
    );
  }

  get isStoryActionDisabled() {
    return this.isLoading || !this.hasStory;
  }

  get isCommitDisabled() {
    return (
      this.isLoading
      || !this.hasStory
      || !this.selectedOrgId
      || !this.hasBuildArtifacts
      || !this.deploySucceeded
    );
  }

  get isValidateDisabled() {
    return this.isLoading || !this.hasStory || !this.canValidate;
  }

  get isDeployNextDisabled() {
    const validateOk = (this.validateStepStatus || '').toLowerCase() === 'successful';
    return (
      this.isLoading
      || !this.hasStory
      || !this.nextEnvironmentId
      || !validateOk
    );
  }

  get isCheckDeploymentDisabled() {
    return this.isLoading || this.canCheckDeployment !== true;
  }

  get deployButtonLabel() {
    const env = (this.connectedOrgName || this.selectedOrgLabel || '').trim();
    return env ? `Deploy to ${env}` : 'Deploy to Dev';
  }

  get validateButtonLabel() {
    const env = (this.nextEnvironmentName || '').trim();
    return env ? `Validate to ${env}` : 'Validate to next';
  }

  get deployNextButtonLabel() {
    const env = (this.nextEnvironmentName || '').trim();
    return env ? `Deploy to ${env}` : 'Deploy to next';
  }

  get nextDeployStatusLabel() {
    const env = (this.nextEnvironmentName || '').trim();
    return env ? `Deploy to ${env}` : 'Deploy to next';
  }

  get isRefreshJobDisabled() {
    const validateInFlight =
      (this.validateStepStatus || '').toLowerCase() === 'in progress'
      || (this.nextDeployStepStatus || '').toLowerCase() === 'in progress';
    const stepInFlight =
      (this.buildStepStatus || '').toLowerCase() === 'in progress'
      || (this.deployStepStatus || '').toLowerCase() === 'in progress'
      || (this.commitStepStatus || '').toLowerCase() === 'in progress'
      || validateInFlight;
    return this.isLoading || (!this.lastJobId && !stepInFlight);
  }

  /** Recovery only — hide once USC is linked or while the job is still running. */
  get showLinkCommitButton() {
    // Deploy-only jobs never produce a git SHA — only show after Commit.
    if ((this.lastJobAction || '').toLowerCase() !== 'commit') {
      return false;
    }
    if (!this.lastJobId || !this.lastJobComplete || this.lastJobFailed) {
      return false;
    }
    const detail = (this.lastJobSummary || '').toLowerCase();
    if (
      detail.includes('already linked')
      || detail.includes('linked user story commit')
    ) {
      return false;
    }
    return (
      detail.includes('usc link failed')
      || detail.includes('skip usc link')
      || detail.includes('no sha found')
      || detail.includes('could not create')
    );
  }

  get lastJobStatusDisplay() {
    if (!this.lastJobId) {
      return 'None';
    }
    return this.lastJobStatus || 'Unknown';
  }

  /** True when the error/job Id is a Salesforce record Id (not mock/webhook placeholder). */
  get hasJobRecordLink() {
    const id = (this.pipelineErrorJobId || this.lastJobId || '').trim();
    return /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(id);
  }

  get jobStatusClass() {
    if (this.lastJobFailed) {
      return 'status-value score-low';
    }
    if (this.lastJobComplete) {
      return 'status-value score-good';
    }
    return 'status-value score-medium';
  }

  get jobStatusLinkClass() {
    return `${this.jobStatusClass} story-hotlink status-job-link`;
  }

  async handleOpenValidatePromotion(event) {
    if (event) {
      event.preventDefault();
    }
    await this.openPromotionRecordById(this.lastPromotionId);
  }

  async handleOpenPipelineError(event) {
    if (event) {
      event.preventDefault();
    }
    // Hard preference: Validate Failed + Promotion Id → always Promotion page.
    // Last_Job_Id is often the successful Promote JE; that must never be the target.
    if (
      this.hasPromotionRecordLink
      && (this.validateStepStatus || '').toLowerCase() === 'failed'
    ) {
      await this.openPromotionRecordById(this.lastPromotionId);
      return;
    }
    if (!this.hasPipelineErrorRecordLink) {
      return;
    }
    const recordId = this.pipelineErrorTargetId;
    if (this.usePromotionErrorLink) {
      await this.openPromotionRecordById(recordId);
      return;
    }
    await this.openJobExecutionById(recordId);
  }

  handleCopyPipelineError() {
    const text = (this.pipelineErrorDetail || '').trim();
    if (!text) {
      return;
    }
    this.copyTextToClipboard(text, 'Error copied');
  }

  handlePastePipelineErrorIntoChat() {
    const err = (this.pipelineErrorDetail || '').trim();
    if (!err) {
      return;
    }
    const story = this.linkedStoryNumber || this.storyName || 'this user story';
    const promo = this.lastPromotionId
      ? `Promotion ${this.lastPromotionId}`
      : 'the latest Promotion';
    const next = this.nextEnvironmentName || 'the next environment';
    this.inputMessage =
      `Validate to ${next} failed for ${story} (${promo}).\n\n`
      + `Here is the Copado deployment / validation error:\n\n`
      + `${err}\n\n`
      + `Please explain the root cause and tell me exactly what to change `
      + `(metadata, layout, package, or Builder steps) so Validate succeeds.`;
    this.scrollComposerIntoView();
    this.showToast(
      'Ready to send',
      'Error pasted into the chat box — review and click Send.',
      'info'
    );
  }

  async copyTextToClipboard(text, successLabel) {
    try {
      if (navigator?.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
      }
      this.showToast('Copied', successLabel || 'Copied to clipboard.', 'success');
    } catch (error) {
      this.showToast('Copy failed', 'Select the error text and copy manually.', 'warning');
    }
  }

  scrollComposerIntoView() {
    try {
      const el = this.template.querySelector('.composer-dock');
      if (el && typeof el.scrollIntoView === 'function') {
        el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      }
    } catch (ignore) {
      // best-effort
    }
  }

  /** @deprecated Prefer handleOpenPipelineError — kept for any older callers. */
  async handleOpenLastJob(event) {
    await this.handleOpenPipelineError(event);
  }

  async openPromotionRecordById(promotionId) {
    const id = (promotionId || '').trim();
    if (!id || id.startsWith('mock')) {
      return;
    }
    try {
      const url = await this[NavigationMixin.GenerateUrl]({
        type: 'standard__recordPage',
        attributes: {
          recordId: id,
          objectApiName: 'copado__Promotion__c',
          actionName: 'view'
        }
      });
      window.open(url, '_blank', 'noopener,noreferrer');
    } catch (error) {
      window.open('/' + id, '_blank', 'noopener,noreferrer');
    }
  }

  async openJobExecutionById(jobId) {
    const id = (jobId || '').trim();
    if (!id) {
      return;
    }
    try {
      const url = await this[NavigationMixin.GenerateUrl]({
        type: 'standard__recordPage',
        attributes: {
          recordId: id,
          objectApiName: 'copado__JobExecution__c',
          actionName: 'view'
        }
      });
      window.open(url, '_blank', 'noopener,noreferrer');
    } catch (error) {
      window.open('/' + id, '_blank', 'noopener,noreferrer');
    }
  }

  get hasChatSessions() {
    return this.chatSessions && this.chatSessions.length > 0;
  }

  get chatSessionsView() {
    const activeId = this.sessionId;
    return (this.chatSessions || []).map((chat) => ({
      ...chat,
      itemClass:
        chat.sessionId === activeId ? 'chat-item chat-item-active' : 'chat-item'
    }));
  }
}
