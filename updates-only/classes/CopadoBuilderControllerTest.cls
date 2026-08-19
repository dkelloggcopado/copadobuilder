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
      + 'Test edge cases and bulk imports in the org.'
  );
  System.assert(session.score > 0, 'Score should increase after user input');

  CopadoBuilderController.ActionResult storyResult = CopadoBuilderController.createCopadoStory(
    session.sessionId,
    false,
    null
  );
  System.assertEquals(true, storyResult.success, storyResult.message);

  CopadoBuilderController.ActionResult buildResult = CopadoBuilderController.buildCode(session.sessionId);
  System.assertEquals(true, buildResult.success, buildResult.message);

  CopadoBuilderController.ActionResult reviewResult = CopadoBuilderController.reviewCode(session.sessionId);
  System.assertEquals(true, reviewResult.success, reviewResult.message);

  CopadoBuilderController.ActionResult testResult = CopadoBuilderController.createTests(session.sessionId);
  System.assertEquals(true, testResult.success, testResult.message);

  List<CopadoAiApiService.OrgInfo> orgs = CopadoBuilderController.listSafeDevOrgs(session.sessionId);
  System.assert(!orgs.isEmpty(), 'Should return safe dev orgs');

  CopadoBuilderController.ActionResult deniedDeploy = CopadoBuilderController.deployToDev(
    session.sessionId,
    orgs[0].orgId,
    false
  );
  System.assertEquals(false, deniedDeploy.success);

  CopadoBuilderController.ActionResult deployResult = CopadoBuilderController.deployToDev(
    session.sessionId,
    orgs[0].orgId,
    true
  );
  System.assertEquals(true, deployResult.success, deployResult.message);

  List<CopadoBuilderController.StoryHistoryDto> history = CopadoBuilderController.getStoryHistory();
  System.assert(!history.isEmpty(), 'History should include completed story');
  Test.stopTest();
  }

  @IsTest
  static void testGuardrails() {
  CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();

  CopadoBuilderController.ActionResult buildWithoutStory = CopadoBuilderController.buildCode(session.sessionId);
  System.assertEquals(false, buildWithoutStory.success);

  CopadoBuilderController.ActionResult deployWrongOrg = CopadoBuilderController.deployToDev(
    session.sessionId,
    'org-qa-002',
    true
  );
  System.assertEquals(false, deployWrongOrg.success);
  }

  @IsTest
  static void testMySessionsAndOpen() {
    CopadoBuilderController.SessionState session = CopadoBuilderController.startSession();
    CopadoBuilderController.sendMessage(
      session.sessionId,
      'Track customer sentiment on Account with a checkbox field.'
    );

    List<CopadoBuilderController.StoryHistoryDto> mine = CopadoBuilderController.getMySessions();
    System.assert(!mine.isEmpty(), 'Current user should see their chats');
    System.assertEquals(session.sessionId, mine[0].sessionId);

    CopadoBuilderController.SessionState opened = CopadoBuilderController.openSession(session.sessionId);
    System.assertEquals(session.sessionId, opened.sessionId);
    System.assert(!opened.messages.isEmpty(), 'Opened chat should include messages');
  }
}
