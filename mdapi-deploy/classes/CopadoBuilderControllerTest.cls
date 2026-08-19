@IsTest
private class CopadoBuilderControllerTest {

  @IsTest
  static void testFullBuilderFlow() {
    Test.startTest();
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    System.assertNotEquals(null, session.sessionId);

    session = CopadoBuilderController.sendMessage(
      session.sessionId,
      'We need to build an Account validation flow because reps enter bad data. '
        + 'Acceptance criteria: given a new account, when annual revenue is blank, then show an error. '
        + 'Test edge cases and bulk imports in the org.',
      null,
      null
    );
    System.assert(session.score > 0, 'Score should increase after user input');

    CopadoBuilderController.ActionResult storyResult = CopadoBuilderController.createCopadoStory(
      session.sessionId,
      false,
      null,
      'proj-demo-001'
    );
    System.assertEquals(true, storyResult.success, storyResult.message);

    CopadoBuilderController.EnvironmentOptions envOpts =
      CopadoBuilderController.listSafeDevOrgs(session.sessionId, 'proj-demo-001');
    System.assertNotEquals(null, envOpts);
    System.assert(!envOpts.orgs.isEmpty(), 'Should return safe dev orgs');
    String envId = envOpts.orgs[0].orgId;

    CopadoBuilderController.ActionResult buildResult = CopadoBuilderController.buildCode(
      session.sessionId,
      envId,
      true
    );
    System.assertEquals(true, buildResult.success, buildResult.message);
    System.assert(
      String.isNotBlank(buildResult.session.lastBuildId)
        || (buildResult.session.buildArtifacts != null && !buildResult.session.buildArtifacts.isEmpty()),
      'Build should produce artifacts'
    );

    CopadoBuilderController.ActionResult reviewResult = CopadoBuilderController.reviewCode(session.sessionId);
    System.assertEquals(true, reviewResult.success, reviewResult.message);

    CopadoBuilderController.ActionResult testResult = CopadoBuilderController.createTests(session.sessionId);
    System.assertEquals(true, testResult.success, testResult.message);

    CopadoBuilderController.ActionResult deniedDeploy = CopadoBuilderController.deployToDev(
      session.sessionId,
      envId,
      false,
      false
    );
    System.assertEquals(false, deniedDeploy.success);

    CopadoBuilderController.ActionResult commitWithoutDeploy = CopadoBuilderController.commitFromDev(
      session.sessionId,
      envId,
      false
    );
    System.assertEquals(false, commitWithoutDeploy.success, 'Commit should fail before Deploy');

    CopadoBuilderController.ActionResult deployResult = CopadoBuilderController.deployToDev(
      session.sessionId,
      envId,
      true,
      false
    );
    System.assertEquals(true, deployResult.success, deployResult.message);
    System.assertNotEquals(null, deployResult.session.lastDeployJobId, 'Deploy should set lastDeployJobId');

    CopadoBuilderController.ActionResult commitResult = CopadoBuilderController.commitFromDev(
      session.sessionId,
      envId,
      false
    );
    System.assertEquals(true, commitResult.success, commitResult.message);
    System.assertNotEquals(null, commitResult.session.lastJobId, 'Commit should start a job');
    System.assertNotEquals(null, commitResult.session.lastCommitJobId, 'Commit should set lastCommitJobId');

    // Pipeline actions must not wipe story Summary (Story Score input).
    AI_Builder_Session__c afterCommit = [
      SELECT Summary__c, Score__c
      FROM AI_Builder_Session__c
      WHERE Id = :session.sessionId
    ];
    System.assert(
      String.isNotBlank(afterCommit.Summary__c) && afterCommit.Summary__c.length() >= 80,
      'Commit must not replace story Summary with a short job blurb'
    );
    System.assert(
      !afterCommit.Summary__c.toLowerCase().startsWith('commit started'),
      'Commit job summary must not overwrite story Summary__c'
    );

    CopadoBuilderController.ActionResult validateResult =
      CopadoBuilderController.validateToNextEnvironment(session.sessionId, true);
    System.assertEquals(true, validateResult.success, validateResult.message);
    System.assertEquals('Validating', validateResult.session.currentStep);
    System.assertNotEquals(null, validateResult.session.lastPromotionId);

    CopadoBuilderController.ActionResult jobRefresh =
      CopadoBuilderController.refreshJobStatus(session.sessionId);
    System.assertNotEquals(null, jobRefresh.message);

    List<CopadoBuilderController.StoryHistoryDto> history = CopadoBuilderController.getStoryHistory();
    System.assert(!history.isEmpty(), 'History should include completed story');
    Test.stopTest();
  }

  @IsTest
  static void testGuardrails() {
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();

    CopadoBuilderController.ActionResult buildWithoutStory = CopadoBuilderController.buildCode(
      session.sessionId,
      null,
      false
    );
    System.assertEquals(false, buildWithoutStory.success);

    CopadoBuilderController.ActionResult deployWrongOrg = CopadoBuilderController.deployToDev(
      session.sessionId,
      'org-prod-999',
      true,
      false
    );
    System.assertEquals(false, deployWrongOrg.success);
  }

  @IsTest
  static void testMySessionsAndOpen() {
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    CopadoBuilderController.sendMessage(
      session.sessionId,
      'Track customer sentiment on Account with a checkbox field.',
      null,
      null
    );

    List<CopadoBuilderController.StoryHistoryDto> mine = CopadoBuilderController.getMySessions();
    System.assert(!mine.isEmpty(), 'Current user should see their chats');
    System.assertEquals(session.sessionId, mine[0].sessionId);

    CopadoBuilderController.SessionState opened = CopadoBuilderController.openSession(session.sessionId);
    System.assertEquals(session.sessionId, opened.sessionId);
    System.assert(!opened.messages.isEmpty(), 'Opened chat should include messages');

    CopadoBuilderController.SessionState resumed = CopadoBuilderController.resumeOrStartSession();
    System.assertEquals(session.sessionId, resumed.sessionId, 'App open should resume latest chat');

    CopadoBuilderController.SessionState afterDelete =
      CopadoBuilderController.deleteSession(session.sessionId);
    System.assertNotEquals(null, afterDelete);
    System.assertNotEquals(
      null,
      afterDelete.sessionId,
      'Delete should leave the user on another/new session'
    );
    List<CopadoBuilderController.StoryHistoryDto> after = CopadoBuilderController.getMySessions();
    for (CopadoBuilderController.StoryHistoryDto row : after) {
      System.assertNotEquals(
        session.sessionId,
        row.sessionId,
        'Deleted session must not appear in My Chats'
      );
    }
  }

  @IsTest
  static void testOpenExistingStory() {
    Test.startTest();
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    CopadoBuilderController.ActionResult opened = CopadoBuilderController.openCopadoUserStory(
      session.sessionId,
      session.sessionId
    );
    System.assertEquals(true, opened.success, opened.message);
    System.assertNotEquals(null, opened.session);
    System.assert(opened.session.score >= 70, 'Opened story should be build-ready');
    System.assert(
      opened.session.missingInfo == null || opened.session.missingInfo.isEmpty()
        || !opened.session.missingInfo.contains('requirements clarity'),
      'Linked story body should clear basic missing-info flags'
    );
    // Reload must keep the scored body (not reset to ~0% from User-only scoring).
    CopadoBuilderController.SessionState reloaded =
      CopadoBuilderController.getSessionState(session.sessionId);
    System.assert(reloaded.score >= 70, 'Reloaded linked story must stay build-ready');
    Test.stopTest();
  }

  @IsTest
  static void testLinkedStoryScoreConsistentAcrossChats() {
    Test.startTest();
    CopadoBuilderController.SessionState chatA = CopadoBuilderController.startSession();
    CopadoBuilderController.SessionState chatB = CopadoBuilderController.startSession();
    Id sharedStoryId = chatA.sessionId;

    CopadoBuilderController.ActionResult openA =
      CopadoBuilderController.openCopadoUserStory(chatA.sessionId, sharedStoryId);
    System.assertEquals(true, openA.success, openA.message);
    Integer linkedScore = openA.session.score;
    System.assert(linkedScore >= 70, 'Linked story should be build-ready');

    // Extra chat text that previously changed keyword density / score per session.
    CopadoBuilderController.sendMessage(
      chatA.sessionId,
      'Also discuss production delete migrate account contact opportunity flow trigger '
        + 'edge cases validation bulk assert coverage exception guard scenarios.',
      null,
      null
    );

    CopadoBuilderController.ActionResult openB =
      CopadoBuilderController.openCopadoUserStory(chatB.sessionId, sharedStoryId);
    System.assertEquals(true, openB.success, openB.message);

    CopadoBuilderController.SessionState stateA =
      CopadoBuilderController.getSessionState(chatA.sessionId);
    CopadoBuilderController.SessionState stateB =
      CopadoBuilderController.getSessionState(chatB.sessionId);
    System.assertEquals(
      stateA.score,
      stateB.score,
      'Linked chats for the same User Story must share one Story Score'
    );
    System.assertEquals(
      linkedScore,
      stateA.score,
      'Extra chat messages must not change the linked User Story score'
    );

    // Sibling Score__c sync so My Chats matches Status.
    update new AI_Builder_Session__c(Id = chatB.sessionId, Score__c = 11);
    CopadoBuilderController.getSessionState(chatA.sessionId);
    AI_Builder_Session__c syncedB = [
      SELECT Score__c
      FROM AI_Builder_Session__c
      WHERE Id = :chatB.sessionId
    ];
    System.assertEquals(
      stateA.score,
      Integer.valueOf(syncedB.Score__c),
      'Opening one linked chat should sync Score__c on sibling chats'
    );
    Test.stopTest();
  }

  @IsTest
  static void testConnectOrgIntelligence() {
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    CopadoBuilderController.EnvironmentOptions envOpts =
      CopadoBuilderController.listSafeDevOrgs(session.sessionId, 'proj-demo-001');
    System.assert(!envOpts.orgs.isEmpty(), 'Need a mock Dev org');

    Test.startTest();
    List<CopadoAiApiService.IntegrationInfo> integrations =
      CopadoBuilderController.listOrgIntelligenceIntegrations(session.sessionId);
    System.assert(!integrations.isEmpty(), 'Mock integrations should list');
    CopadoBuilderController.ActionResult connected =
      CopadoBuilderController.connectOrgIntelligence(
        session.sessionId,
        envOpts.orgs[0].orgId,
        true,
        integrations[0].id
      );
    Test.stopTest();

    System.assertEquals(true, connected.success, connected.message);
    System.assertNotEquals(null, connected.orgIntelligence);
    System.assertNotEquals(null, connected.orgIntelligence.integrationId);
    System.assertEquals('Connected', connected.session.orgContextStatus);
    System.assert(
      String.isNotBlank(connected.orgIntelligence.integrationId),
      'Integration id should be set'
    );
    CopadoBuilderController.SessionState reloaded =
      CopadoBuilderController.getSessionState(session.sessionId);
    System.assertEquals('Connected', reloaded.orgContextStatus);
    System.assertEquals(
      connected.orgIntelligence.integrationId,
      reloaded.orgIntelligenceIntegrationId
    );
    System.assert(
      String.isNotBlank(connected.orgIntelligence.probeAnswer),
      'Mock probe should return an answer'
    );
  }

  @isTest
  static void testAgentRouting() {
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_BUILD,
      CopadoAiApiService.routeAssistant('Does the Builder_Deploy_Test__c field exist in my dev1 org?'),
      'Org metadata questions route to Build'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_PLAN,
      CopadoAiApiService.routeAssistant('Help me refine the acceptance criteria for this user story'),
      'Story/AC questions route to Plan'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_TEST,
      CopadoAiApiService.routeAssistant('Write an apex unit test with good coverage'),
      'Test questions route to Test'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_RELEASE,
      CopadoAiApiService.routeAssistant('Can you promote this to the next pipeline stage?'),
      'Promotion questions route to Release'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_OPERATE,
      CopadoAiApiService.routeAssistant('What is the root cause of this failed job? Do we need a rollback?'),
      'Incident questions route to Operate'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_PLAN,
      CopadoAiApiService.routeAssistant('How many user stories do we have in dev1 right now?'),
      'Backlog counts route to Plan'
    );
    System.assertEquals(
      true,
      CopadoAiApiService.isGovernanceBacklogQuestion(
        'How many user stories do we have in the governance org?'
      ),
      'Governance backlog detector'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_PLAN,
      CopadoAiApiService.routeAssistant(
        'Can you see Dev1 connected? Can you read the Copado org?'
      ),
      'Copado org readability routes to Plan'
    );
    System.assertEquals(
      CopadoAiApiService.ASSISTANT_BUILD,
      CopadoAiApiService.routeAssistant(''),
      'Blank defaults to Build'
    );
  }

  @isTest
  static void testOrgIntelligenceProbeValidation() {
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'I received a response from Copado AI but could not parse the assistant text. Raw preview: (empty body)'
      ),
      'Empty body must not count as Connected'
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'I still can\'t check that directly, my tools don\'t reach live Salesforce org metadata'
      ),
      'Tool denial must not count as Connected'
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe('ORG_INTELLIGENCE_UNAVAILABLE'),
      'Explicit unavailable token fails'
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'Missing instance_url'
      ),
      'Missing instance_url must not count as Connected'
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'Missing int_id in Salesforce integration'
      ),
      'Missing int_id must not count as Connected'
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'I have been unable to query live Salesforce metadata. The integration is returning a missing configuration error.'
      ),
      'Missing configuration denial must fail probe'
    );
    System.assertEquals(
      true,
      CopadoAiApiService.isSuccessfulOrgIntelligenceProbe(
        'Yes. Custom fields: Account.Builder_Deploy_Test__c, Account.Foo__c, Contact.Bar__c'
      ),
      'Real metadata answer succeeds'
    );
  }

  @isTest
  static void testBeginSalesforceOrgAuthMock() {
    CopadoAiApiService.SalesforceAuthResult auth = CopadoAiApiService.beginSalesforceOrgAuth(
      'ws-1',
      'Builder dev1',
      'SANDBOX',
      'https://example.salesforce.com/lightning'
    );
    System.assertEquals(true, auth.success);
    System.assert(String.isNotBlank(auth.authUrl), 'Mock auth URL expected');
  }

  @IsTest
  static void testApexUtilityDraftScoresHigh() {
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    String draft =
      '## Proposed User Story\n'
      + 'Title: Apex Temperature Converter Utility with Unit Tests\n'
      + 'As a: Salesforce Developer\n'
      + 'Want to: Have a reusable Apex utility class that converts temperatures\n'
      + 'So that: Temperature conversions can be performed consistently\n\n'
      + '### Acceptance Criteria\n'
      + 'All 6 static conversion methods are present and callable\n'
      + 'Negative Kelvin throws IllegalArgumentException\n'
      + 'All unit tests pass with 100% coverage\n\n'
      + '### Requirements Clarity\n'
      + 'Functional Requirements cover six static conversion methods\n'
      + 'Class declared as public with sharing\n\n'
      + '### Org Context\n'
      + 'No existing temperature conversion class was found in the connected org\n'
      + 'No conflicting flows or triggers were detected\n'
      + 'The class is net-new and introduces no duplicate functionality\n'
      + 'API version aligned to org standard: 62.0\n\n'
      + '### Test Scenarios\n'
      + 'Freezing point: 0C = 32F = 273.15K\n'
      + 'Negative Kelvin guard throws IllegalArgumentException\n';
    insert new AI_Builder_Message__c(
      Session__c = session.sessionId,
      Role__c = 'Assistant',
      Message__c = draft,
      Step__c = 'Discovery'
    );

    Test.startTest();
    CopadoBuilderController.SessionState state =
      CopadoBuilderController.getSessionState(session.sessionId);
    CopadoBuilderController.ActionResult improved =
      CopadoBuilderController.improveStory(session.sessionId);
    Test.stopTest();

    System.assert(
      state.score >= 75,
      'Full Apex draft with named sections should score build-ready, got ' + state.score
    );
    System.assert(
      state.missingInfo == null || state.missingInfo.isEmpty(),
      'Named sections should clear Missing Info, got ' + String.valueOf(state.missingInfo)
    );
    System.assertEquals(true, improved.success, improved.message);
    System.assert(
      improved.message != null && improved.message.toLowerCase().contains('already cover'),
      'Improve Story should recognize chat already has the details: ' + improved.message
    );
    System.assert(
      !improved.message.toLowerCase().contains('still missing'),
      'Improve Story must not ask for details already in chat'
    );
  }

  @IsTest
  static void testImproveStoryUpdatesLinkedUserStory() {
    if (!CopadoAiApiService.isMockMode()) {
      // Live mode needs a real Copado User Story Id; mock path validates the update flow.
      return;
    }
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    String draft =
      '## Proposed User Story\n'
      + 'Title: Add Favorite Copado Feature Picklist\n'
      + 'As a: Salesforce Admin\n'
      + 'Want to: Capture favorite Copado features on User\n'
      + 'So that: Product feedback is tracked\n\n'
      + '### Acceptance Criteria\n'
      + 'Picklist field exists on User with 16 values\n'
      + 'Field appears on User page layout\n\n'
      + '### Requirements Clarity\n'
      + 'Add Favorite_Copado_Feature__c picklist on User\n\n'
      + '### Org Context\n'
      + 'No existing Favorite_Copado_Feature__c field in org\n\n'
      + '### Test Scenarios\n'
      + 'User can select a picklist value and save\n';
    insert new AI_Builder_Message__c(
      Session__c = session.sessionId,
      Role__c = 'Assistant',
      Message__c = draft,
      Step__c = 'Discovery'
    );

    AI_Builder_Session__c row = [
      SELECT Id, Copado_User_Story__c, Story_Record_Id__c, Story_Name__c, Story_Title__c
      FROM AI_Builder_Session__c
      WHERE Id = :session.sessionId
      LIMIT 1
    ];
    Id fakeStoryId = UserInfo.getUserId();
    row.Story_Record_Id__c = String.valueOf(fakeStoryId);
    row.Story_Name__c = 'US-0000049';
    row.Story_Title__c = 'Add Favorite Copado Feature Picklist';
    row.Copado_User_Story__c =
      String.valueOf(fakeStoryId) + '||US-0000049||Add Favorite Copado Feature Picklist';
    row.Build_Package_Json__c =
      '{"files":[{"path":"force-app/main/default/objects/User.object","content":"<CustomObject/>"}]}';
    row.Last_Build_Id__c = 'bld-stale';
    row.Status__c = 'Code Built';
    update row;

    Test.startTest();
    CopadoBuilderController.ActionResult improved =
      CopadoBuilderController.improveStory(session.sessionId);
    Test.stopTest();

    System.assertEquals(true, improved.success, improved.message);
    System.assert(
      improved.message != null && improved.message.toLowerCase().contains('updated'),
      'Improve Story should update the linked User Story: ' + improved.message
    );

    AI_Builder_Session__c after = [
      SELECT Build_Package_Json__c, Last_Build_Id__c, Status__c
      FROM AI_Builder_Session__c
      WHERE Id = :session.sessionId
      LIMIT 1
    ];
    System.assertEquals(
      null,
      after.Build_Package_Json__c,
      'Improve Story should clear stale Build package JSON'
    );
    System.assertEquals(null, after.Last_Build_Id__c);
    System.assertEquals('Story Created', after.Status__c);

    List<AI_Builder_Message__c> systemMsgs = [
      SELECT Message__c
      FROM AI_Builder_Message__c
      WHERE Session__c = :session.sessionId
        AND Role__c = 'System'
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    System.assertEquals(1, systemMsgs.size());
    System.assert(
      systemMsgs[0].Message__c.contains('Updated linked Copado user story'),
      systemMsgs[0].Message__c
    );
    System.assert(
      systemMsgs[0].Message__c.containsIgnoreCase('cleared previous build artifacts')
        || systemMsgs[0].Message__c.containsIgnoreCase('click Build'),
      systemMsgs[0].Message__c
    );
  }

  @IsTest
  static void testInferMetadataListRequestsAndAuthBlockInjection() {
    String story =
      'Add Favorite_Color__c picklist on Account and put it on the page layout. '
      + 'Also create a Flow and update the Admin profile FLS.';
    String pkg =
      '{"files":['
      + '{"path":"force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml",'
      + '"content":"<CustomField/>"},'
      + '{"path":"force-app/main/default/layouts/Account-Account Layout.layout-meta.xml",'
      + '"content":"<Layout/>"},'
      + '{"path":"force-app/main/default/flows/Account_Color_Flow.flow-meta.xml",'
      + '"content":"<Flow/>"},'
      + '{"path":"force-app/main/default/profiles/Admin.profile-meta.xml",'
      + '"content":"<Profile/>"}'
      + ']}';

    List<CopadoAiApiService.MetadataListRequest> reqs =
      CopadoBuilderController.inferMetadataListRequests(story, pkg);
    Set<String> types = new Set<String>();
    for (CopadoAiApiService.MetadataListRequest req : reqs) {
      types.add(req.metadataType);
    }
    System.assert(types.contains('Layout'), String.valueOf(types));
    System.assert(types.contains('CustomField'), String.valueOf(types));
    System.assert(types.contains('Flow'), String.valueOf(types));
    System.assert(types.contains('Profile'), String.valueOf(types));

    Boolean layoutScopedToAccount = false;
    for (CopadoAiApiService.MetadataListRequest req : reqs) {
      if ('Layout'.equals(req.metadataType) && 'Account'.equals(req.objectApi)) {
        layoutScopedToAccount = true;
        System.assertEquals('Account-', req.namePrefix);
      }
    }
    System.assertEquals(true, layoutScopedToAccount, 'Layout should be scoped to Account');

    List<String> objects = CopadoBuilderController.inferObjectApisForMetadata(
      'Add field on My_Custom_Object__c and Account.Favorite_Color__c',
      null
    );
    System.assert(objects.contains('Account'), String.valueOf(objects));
    System.assert(objects.contains('My_Custom_Object__c'), String.valueOf(objects));

    Map<String, List<String>> live = new Map<String, List<String>>{
      'Layout' => new List<String>{ 'Account-Formato de cuentas' },
      'Profile' => new List<String>{ 'Admin' }
    };
    String auth = CopadoDevopsService.formatAuthoritativeLiveMetadataBlock(live);
    String normalized = CopadoDevopsService.normalizePackageMetadataWithContext(pkg, auth);
    System.assert(
      normalized.contains('Account-Formato de cuentas'),
      normalized
    );
    System.assert(
      !normalized.contains('Account-Account Layout'),
      normalized
    );
  }
}
