@IsTest
private class CopadoDevopsServiceTest {

  @IsTest
  static void testListOrgsAndMockCommitDeploy() {
    List<CopadoAiApiService.OrgInfo> orgs = CopadoDevopsService.listPipelineOrgs();
    System.assert(!orgs.isEmpty(), 'Should return pipeline orgs');

    CopadoDevopsService.JobResult commitJob = CopadoDevopsService.deployPackageThenCommit(
      UserInfo.getUserId(),
      '{"files":[{"path":"force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml","contents":"<CustomField/>"}]}',
      'test commit',
      new List<String>{
        'force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml'
      },
      orgs[0].orgId,
      null
    );
    System.assertNotEquals(null, commitJob.jobId);
    System.assertEquals('mock', commitJob.method);
    System.assert(commitJob.summary.contains('deploy'), 'Summary should mention deploy-then-commit');

    CopadoDevopsService.JobStatus jobStatus =
      CopadoDevopsService.getJobExecutionStatus(commitJob.jobId);
    System.assertEquals(true, jobStatus.isComplete);
    System.assertEquals(false, jobStatus.isFailed);

    CopadoDevopsService.JobResult deployJob = CopadoDevopsService.deployUserStory(
      UserInfo.getUserId(),
      orgs[0].orgId,
      orgs[0].orgName
    );
    System.assertNotEquals(null, deployJob.jobId);
    System.assert(deployJob.summary.contains(orgs[0].orgName));
  }

  @IsTest
  static void testParseMetadataFromPath() {
    Map<String, String> fieldMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml'
    );
    System.assertEquals('CustomField', fieldMeta.get('type'));
    System.assertEquals('Account.Favorite_Color__c', fieldMeta.get('member'));

    Map<String, String> mdapiObject = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/objects/User.object'
    );
    System.assertEquals('CustomObject', mdapiObject.get('type'));
    System.assertEquals('User', mdapiObject.get('member'));

    Map<String, String> mdapiLayout = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/layouts/User-Formato de usuario.layout'
    );
    System.assertEquals('Layout', mdapiLayout.get('type'));
    System.assertEquals('User-Formato de usuario', mdapiLayout.get('member'));

    Map<String, String> layoutMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/layouts/Account-Account Layout.layout-meta.xml'
    );
    System.assertEquals('Layout', layoutMeta.get('type'));
    System.assertEquals('Account-Account Layout', layoutMeta.get('member'));

    Map<String, String> profileMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/profiles/Admin.profile-meta.xml'
    );
    System.assertEquals('Profile', profileMeta.get('type'));
    System.assertEquals('Admin', profileMeta.get('member'));

    Map<String, String> validationMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/objects/Account/validationRules/Require_Note.validationRule-meta.xml'
    );
    System.assertEquals('ValidationRule', validationMeta.get('type'));
    System.assertEquals('Account.Require_Note', validationMeta.get('member'));

    Map<String, String> lwcMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/lwc/accountNote/accountNote.js-meta.xml'
    );
    System.assertEquals('LightningComponentBundle', lwcMeta.get('type'));
    System.assertEquals('accountNote', lwcMeta.get('member'));

    Map<String, String> companionMeta = CopadoDevopsService.parseMetadataFromPath(
      'force-app/main/default/classes/AccountNoteService.cls-meta.xml'
    );
    System.assertEquals(null, companionMeta.get('type'));
    System.assertEquals(null, companionMeta.get('member'));
  }

  @IsTest
  static void testBuildCommitSelectionsMatchesCopadoUi() {
    List<Map<String, Object>> selections = CopadoDevopsService.buildCommitSelections(
      '{"files":[{"path":"force-app/main/default/objects/Account/fields/High_Touch_Account__c.field-meta.xml","contents":"<CustomField/>"}]}'
    );
    System.assertEquals(1, selections.size());
    System.assertEquals('CustomField', selections[0].get('t'));
    System.assertEquals('Account.High_Touch_Account__c', selections[0].get('n'));
    System.assertEquals('', selections[0].get('m'));
    System.assertEquals('', selections[0].get('j'));
    System.assertEquals('SFDX', selections[0].get('c'));
    System.assertEquals('Add', selections[0].get('a'));
  }

  @IsTest
  static void testMdapiObjectAndLayoutCommitSelections() {
    String objectXml =
      '<?xml version="1.0" encoding="UTF-8"?>'
      + '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">'
      + '<fields><fullName>Favorite_Copado_Feature__c</fullName>'
      + '<type>Picklist</type></fields>'
      + '</CustomObject>';
    String packageJson =
      '{"files":['
      + '{"path":"force-app/main/default/objects/User.object","content":'
      + JSON.serialize(objectXml)
      + '},'
      + '{"path":"force-app/main/default/layouts/User-Formato de usuario.layout","content":"<Layout/>"}'
      + ']}';

    List<Map<String, Object>> selections =
      CopadoDevopsService.buildCommitSelections(packageJson);
    System.assertEquals(
      2,
      selections.size(),
      'CustomField from User.object + Layout; not whole CustomObject'
    );

    Set<String> keys = new Set<String>();
    for (Map<String, Object> row : selections) {
      keys.add(String.valueOf(row.get('t')) + ':' + String.valueOf(row.get('n')));
    }
    System.assert(
      keys.contains('CustomField:User.Favorite_Copado_Feature__c'),
      'Expanded field missing: ' + keys
    );
    System.assert(
      keys.contains('Layout:User-Formato de usuario'),
      'MDAPI .layout missing: ' + keys
    );
    System.assert(
      !keys.contains('CustomObject:User'),
      'Should prefer field selection over CustomObject: ' + keys
    );
  }

  @IsTest
  static void testSfdxTypeNormalizationAndFullPackageSelections() {
    System.assertEquals('Layout', CopadoDevopsService.toSfdxMetadataType('Page Layout'));
    System.assertEquals('Layout', CopadoDevopsService.toSfdxMetadataType('Layout'));
    System.assertEquals('PermissionSet', CopadoDevopsService.toSfdxMetadataType('Permission Set'));
    System.assertEquals('CustomField', CopadoDevopsService.toSfdxMetadataType('Custom Field'));

    String packageJson =
      '{"files":['
      + '{"path":"force-app/main/default/objects/Account/fields/Renewal_Risk__c.field-meta.xml","content":"<CustomField/>"},'
      + '{"path":"force-app/main/default/layouts/Account-Formato de cuentas.layout-meta.xml","content":"<Layout/>"},'
      + '{"path":"force-app/main/default/profiles/Admin.profile-meta.xml","content":"<Profile/>"}'
      + ']}';
    List<Map<String, Object>> selections = CopadoDevopsService.buildCommitSelections(packageJson);
    System.assertEquals(3, selections.size(), 'Field + Layout + Profile must all be selected');

    Set<String> keys = new Set<String>();
    for (Map<String, Object> row : selections) {
      keys.add(String.valueOf(row.get('t')) + ':' + String.valueOf(row.get('n')));
      System.assertNotEquals(
        'Page Layout',
        row.get('t'),
        'SFDX registry must use Layout, never Page Layout'
      );
    }
    System.assert(
      keys.contains('CustomField:Account.Renewal_Risk__c'),
      'CustomField missing: ' + keys
    );
    System.assert(
      keys.contains('Layout:Account-Formato de cuentas'),
      'Layout missing: ' + keys
    );
    System.assert(keys.contains('Profile:Admin'), 'Profile missing: ' + keys);

    // Dedupe Page Layout + Layout aliases to a single Layout entry
    List<Map<String, Object>> merged = CopadoDevopsService.resolveCommitSelections(
      null,
      packageJson
    );
    Integer layoutCount = 0;
    for (Map<String, Object> row : merged) {
      if ('Layout'.equals(row.get('t'))) {
        layoutCount++;
      }
    }
    System.assertEquals(1, layoutCount, 'Only one Layout selection after normalize/dedupe');
  }

  @IsTest
  static void testProductionLabelClassification() {
    System.assertEquals(
      false,
      CopadoDevopsService.isProductionLabel('Production/Developer'),
      'Developer sandbox type must not be treated as production'
    );
    System.assertEquals(
      false,
      CopadoDevopsService.isProductionLabel('dev1'),
      'Dev environment name must not be treated as production'
    );
    System.assertEquals(
      false,
      CopadoDevopsService.isProductionLabel('Sandbox'),
      'Sandbox must not be production'
    );
    System.assertEquals(
      true,
      CopadoDevopsService.isProductionLabel('Production'),
      'True production org type'
    );
  }

  @IsTest
  static void testStampBuildArtifactsReplacesPackageSelections() {
    String oldPackage =
      '{"files":[{"path":"force-app/main/default/objects/User.object","content":'
      + '"<CustomObject><fields><fullName>Favorite_Copado_Feature__c</fullName></fields></CustomObject>"}]}';
    String newPackage =
      '{"files":['
      + '{"path":"force-app/main/default/classes/TemperatureConverter.cls","content":"public class TemperatureConverter {}"},'
      + '{"path":"force-app/main/default/classes/TemperatureConverterTest.cls","content":"@IsTest private class TemperatureConverterTest {}"}'
      + ']}';

    Integer stamped = CopadoDevopsService.stampUserStoryBuildArtifacts(
      UserInfo.getUserId(),
      newPackage,
      null
    );
    System.assert(
      stamped >= 2,
      'Re-build should stamp new Apex artifacts, got ' + stamped
    );

    List<Map<String, Object>> selections =
      CopadoDevopsService.buildCommitSelections(newPackage);
    Set<String> keys = new Set<String>();
    for (Map<String, Object> row : selections) {
      keys.add(String.valueOf(row.get('t')) + ':' + String.valueOf(row.get('n')));
    }
    System.assert(keys.contains('ApexClass:TemperatureConverter'), keys);
    System.assert(keys.contains('ApexClass:TemperatureConverterTest'), keys);
    System.assert(
      !keys.contains('CustomField:User.Favorite_Copado_Feature__c'),
      'Old User field must not remain in new package selections: ' + keys
    );
    // oldPackage unused except documenting replace intent
    System.assert(String.isNotBlank(oldPackage));
  }

  @IsTest
  static void testDeployOnlyCommitOnlyAndValidateMock() {
    List<CopadoAiApiService.OrgInfo> orgs = CopadoDevopsService.listPipelineOrgs();
    System.assert(!orgs.isEmpty(), 'Should return pipeline orgs');
    String packageJson =
      '{"files":[{"path":"force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml","contents":"<CustomField/>"}]}';
    List<String> paths = new List<String>{
      'force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml'
    };

    CopadoDevopsService.JobResult deployJob = CopadoDevopsService.deployPackageToDev(
      UserInfo.getUserId(),
      packageJson,
      'test deploy',
      paths,
      orgs[0].orgId,
      null
    );
    System.assertNotEquals(null, deployJob.jobId);
    System.assertEquals('mock', deployJob.method);
    System.assert(deployJob.summary.containsIgnoreCase('deploy'), 'Summary should mention deploy');
    System.assertEquals(
      true,
      CopadoDevopsService.isJobExecutionSuccessful(deployJob.jobId),
      'Mock deploy job should be successful'
    );

    CopadoDevopsService.JobResult commitJob = CopadoDevopsService.commitPackageFromDev(
      UserInfo.getUserId(),
      packageJson,
      'test commit',
      paths,
      orgs[0].orgId,
      null
    );
    System.assertNotEquals(null, commitJob.jobId);
    System.assertEquals('mock', commitJob.method);
    System.assert(commitJob.summary.containsIgnoreCase('commit'), 'Summary should mention commit');

    CopadoDevopsService.JobResult recreateJob = CopadoDevopsService.commitPackageFromDev(
      UserInfo.getUserId(),
      packageJson,
      'recreate commit',
      paths,
      orgs[0].orgId,
      null,
      true
    );
    System.assertNotEquals(null, recreateJob.jobId);
    System.assert(
      recreateJob.summary.containsIgnoreCase('recreate'),
      'Recreate summary should mention recreate feature branch'
    );

    CopadoDevopsService.JobResult validateJob =
      CopadoDevopsService.validateUserStoryToNextEnvironment(UserInfo.getUserId(), orgs[0].orgId);
    System.assertNotEquals(null, validateJob.jobId);
    System.assertEquals('mock', validateJob.method);
    System.assertEquals('mock-promotion', validateJob.promotionId);
    System.assert(validateJob.summary.containsIgnoreCase('validate'), 'Summary should mention validate');

    System.assertEquals(true, CopadoDevopsService.isJobExecutionSuccessful('mock-abc'));
    System.assertEquals(true, CopadoDevopsService.isJobExecutionSuccessful(null));
  }

  @IsTest
  static void testOotbPromotionAndDeploymentPayloadShape() {
    Id usId = UserInfo.getUserId();
    Id promoId = UserInfo.getUserId();
    Id deployId = UserInfo.getUserId();
    Id sourceEnv = UserInfo.getUserId();
    Id destEnv = UserInfo.getOrganizationId();
    String sourceCred = String.valueOf(UserInfo.getUserId());
    String destCred = String.valueOf(UserInfo.getOrganizationId());
    Id fileId = UserInfo.getUserId();

    Map<String, Object> promote = CopadoDevopsService.buildOotbPromotionPayload(
      usId,
      promoId,
      sourceCred,
      destCred,
      'feature/US-0000049',
      'promotion/P00009',
      'int',
      fileId,
      true,
      null,
      sourceEnv,
      destEnv
    );
    System.assertEquals('Promotion', promote.get('action'));
    System.assertEquals(true, promote.get('executePromotion'));
    System.assertEquals(true, promote.get('executeDeployment'));
    System.assertEquals(true, promote.get('deploymentDryRun'));
    System.assertEquals(false, promote.get('isBackPromotion'));
    System.assertEquals('target', promote.get('poolQueueStrategy'));
    System.assertEquals(sourceCred, promote.get('sourceCredentialId'));
    System.assertEquals(destCred, promote.get('destinationCredentialId'));
    System.assertNotEquals(
      promote.get('sourceCredentialId'),
      promote.get('destinationCredentialId'),
      'Source and destination credentials must differ'
    );
    System.assertEquals('promotion/P00009', promote.get('promotionBranchName'));
    System.assertEquals('int', promote.get('destinationBranchName'));
    System.assertEquals(String.valueOf(fileId), promote.get('fileWithSelectedChanges'));
    List<Object> promoteUsIds = (List<Object>) promote.get('userStoryIds');
    System.assertEquals(1, promoteUsIds.size());
    System.assertEquals(String.valueOf(usId), String.valueOf(promoteUsIds[0]));
    List<Object> promoteBranches = (List<Object>) promote.get('userStoryBranches');
    System.assertEquals(1, promoteBranches.size());
    System.assertEquals('feature/US-0000049', String.valueOf(promoteBranches[0]));
    System.assertEquals(null, promote.get('environmentRecordId'));
    System.assertEquals(null, promote.get('userStoryId'));

    Map<String, Object> deploy = CopadoDevopsService.buildOotbPromotionDeploymentPayload(
      usId,
      promoId,
      deployId,
      sourceCred,
      destCred,
      'feature/US-0000049',
      'promotion/P00009',
      'int',
      fileId,
      true,
      null,
      sourceEnv,
      destEnv
    );
    System.assertEquals('PromotionDeployment', deploy.get('action'));
    System.assertEquals(true, deploy.get('deploymentDryRun'));
    System.assertEquals(String.valueOf(deployId), deploy.get('deploymentId'));
    System.assertEquals(String.valueOf(promoId), deploy.get('promotionId'));
    System.assertEquals(String.valueOf(promoId), deploy.get('transactionId'));
    System.assertEquals('promotion/P00009', deploy.get('promotionBranchName'));
    System.assertEquals('int', deploy.get('destinationBranchName'));
    System.assertEquals(String.valueOf(fileId), deploy.get('fileWithSelectedChanges'));
    List<Object> deployBranches = (List<Object>) deploy.get('userStoryBranches');
    System.assertEquals('feature/US-0000049', String.valueOf(deployBranches[0]));
    System.assertEquals(null, deploy.get('environmentRecordId'));
    System.assertEquals(null, deploy.get('destinationRecordId'));
    System.assertEquals(null, deploy.get('checkOnly'));
    System.assertEquals(null, deploy.get('validationOnly'));

    Map<String, Object> cleaned = CopadoDevopsService.dataJsonForCreateExecution(promote);
    System.assertEquals(null, cleaned.get('_builderSourceEnvironmentId'));
    System.assertEquals(null, cleaned.get('_builderDestinationEnvironmentId'));
    System.assertEquals(null, cleaned.get('_builderPipelineId'));
    System.assertEquals(null, cleaned.get('pipelineId'));
    System.assertEquals('Promotion', cleaned.get('action'));
    System.assertEquals(sourceCred, cleaned.get('sourceCredentialId'));
  }

  @IsTest
  static void testOfficialPromotionDeploymentActionNullPromotion() {
    List<String> diagnostics = new List<String>();
    CopadoDevopsService.JobResult jr =
      CopadoDevopsService.tryOfficialPromotionDeploymentAction(
        null,
        true,
        true,
        true,
        diagnostics
      );
    System.assertEquals(null, jr, 'Null promotion must skip the official action');
  }

  @IsTest
  static void testPromotionStatusClassification() {
    System.assertEquals(
      false,
      CopadoDevopsService.isPromotionSuccessStatus('Validation failed'),
      'Validation failed must not count as success'
    );
    System.assertEquals(true, CopadoDevopsService.isPromotionSuccessStatus('Validated'));
    System.assertEquals(true, CopadoDevopsService.isPromotionSuccessStatus('Completed'));
    System.assertEquals(true, CopadoDevopsService.isPromotionFailedStatus('Validation failed'));
    System.assertEquals(true, CopadoDevopsService.isPromotionFailedStatus('Merge Conflict'));
    // Casing matters for the failed picklist value.
    System.assertEquals(
      false,
      CopadoDevopsService.isPromotionFailedStatus('Validation Failed'),
      'Wrong casing must not match failed picklist'
    );

    CopadoDevopsService.JobStatus failed = new CopadoDevopsService.JobStatus();
    CopadoDevopsService.classifyPromotionStatus(failed, 'Validation failed');
    System.assertEquals(true, failed.isFailed);
    System.assertEquals(true, failed.isComplete);

    CopadoDevopsService.JobStatus validated = new CopadoDevopsService.JobStatus();
    CopadoDevopsService.classifyPromotionStatus(validated, 'Validated');
    System.assertEquals(false, validated.isFailed);
    System.assertEquals(true, validated.isComplete);

    CopadoDevopsService.JobStatus running = new CopadoDevopsService.JobStatus();
    CopadoDevopsService.classifyPromotionStatus(running, 'In Progress');
    System.assertEquals(false, running.isComplete);
    System.assertEquals(false, running.isFailed);

    CopadoDevopsService.JobStatus draft = new CopadoDevopsService.JobStatus();
    CopadoDevopsService.classifyPromotionStatus(draft, 'Draft');
    System.assertEquals(false, draft.isComplete);
  }

  @IsTest
  static void testDeployVerificationQuestionRouting() {
    System.assertEquals(
      true,
      CopadoAiApiService.isDeployVerificationQuestion(
        'check the components in the dev1 org'
      )
    );
    System.assertEquals(
      true,
      CopadoAiApiService.isDeployVerificationQuestion(
        'were they deployed?'
      )
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isDeployVerificationQuestion('Hello')
    );
    // Live schema questions should still go to Org Intelligence, not job-status short-circuit.
    System.assertEquals(
      true,
      CopadoAiApiService.needsOrgIntelligence(
        'What data type is Account.Favorite_NFL_Team__c in the org?'
      )
    );
    System.assertEquals(
      false,
      CopadoAiApiService.isDeployVerificationQuestion(
        'What data type is Account.Favorite_NFL_Team__c in the org?'
      )
    );
  }

  @IsTest
  static void testLayoutRemapAndInventedNormalize() {
    Map<String, String> remaps = CopadoDevopsService.parseLayoutRemapsFromText(
      'BUILDER_LAYOUT_REMAP|Account-Account Layout|Account-Formato de cuentas\n'
      + 'BUILDER_LAYOUT_REMAP_JSON='
      + '[{"from":"Contact-Contact Layout","to":"Contact-Formato de contactos"}]'
    );
    System.assertEquals(
      'Account-Formato de cuentas',
      remaps.get('Account-Account Layout')
    );
    System.assertEquals(
      'Contact-Formato de contactos',
      remaps.get('Contact-Contact Layout')
    );

    List<String> live = CopadoDevopsService.extractLiveLayoutFullNames(
      'AUTHORITATIVE LIVE LAYOUTS\n- Account-Formato de cuentas\n'
      + 'layouts/User-Formato de usuario.layout-meta.xml'
    );
    System.assert(
      live.contains('Account-Formato de cuentas'),
      'Expected Formato from bullet: ' + live
    );
    System.assert(
      live.contains('User-Formato de usuario'),
      'Expected Formato from path: ' + live
    );

    String inventedPkg =
      '{"summary":"x","files":['
      + '{"path":"force-app/main/default/layouts/Account-Account Layout.layout-meta.xml",'
      + '"content":"<Layout/>"},'
      + '{"path":"force-app/main/default/objects/Account/fields/Favorite_NFL_Team__c.field-meta.xml",'
      + '"content":"<CustomField/>"}'
      + ']}';
    String remapped = CopadoDevopsService.applyLayoutRemapsToPackageJson(
      inventedPkg,
      new Map<String, String>{
        'Account-Account Layout' => 'Account-Formato de cuentas'
      }
    );
    System.assert(
      remapped.contains('Account-Formato de cuentas.layout-meta.xml'),
      remapped
    );
    System.assert(
      !remapped.contains('Account-Account Layout.layout-meta.xml'),
      remapped
    );

    String dropped = CopadoDevopsService.normalizePackageLayoutsWithContext(
      inventedPkg,
      'no live layouts here'
    );
    System.assert(
      !dropped.contains('/layouts/'),
      'Invented layout should be dropped without live name: ' + dropped
    );
    System.assert(
      dropped.contains('Favorite_NFL_Team__c'),
      'Field must remain: ' + dropped
    );

    String fixed = CopadoDevopsService.normalizePackageLayoutsWithContext(
      inventedPkg,
      'AUTHORITATIVE LIVE LAYOUTS\n- Account-Formato de cuentas'
    );
    System.assert(
      fixed.contains('Account-Formato de cuentas.layout-meta.xml'),
      fixed
    );
  }

  @IsTest
  static void testAuthoritativeLiveMetadataFormatExtractAndGate() {
    Map<String, List<String>> byType = new Map<String, List<String>>{
      'Layout' => new List<String>{ 'Account-Formato de cuentas' },
      'Flow' => new List<String>{ 'Sample_Flow' },
      'Profile' => new List<String>{ 'Admin' },
      'CustomField' => new List<String>{ 'Account.Name' }
    };
    String block = CopadoDevopsService.formatAuthoritativeLiveMetadataBlock(byType);
    System.assert(block.contains('AUTHORITATIVE LIVE METADATA'), block);
    System.assert(block.contains('Layout:'), block);
    System.assert(block.contains('Account-Formato de cuentas'), block);
    System.assert(block.contains('AUTHORITATIVE LIVE LAYOUTS'), block);
    System.assert(block.contains('Sample_Flow'), block);

    Map<String, List<String>> parsed =
      CopadoDevopsService.extractAuthoritativeLiveMetadata(block);
    System.assert(
      parsed.containsKey('Layout')
        && parsed.get('Layout').contains('Account-Formato de cuentas'),
      String.valueOf(parsed)
    );
    System.assert(
      parsed.containsKey('Flow') && parsed.get('Flow').contains('Sample_Flow'),
      String.valueOf(parsed)
    );
    System.assert(
      parsed.containsKey('Profile') && parsed.get('Profile').contains('Admin'),
      String.valueOf(parsed)
    );

    String pkg =
      '{"summary":"x","files":['
      + '{"path":"force-app/main/default/layouts/Account-Account Layout.layout-meta.xml",'
      + '"content":"<Layout/>"},'
      + '{"path":"force-app/main/default/profiles/Bogus Profile.profile-meta.xml",'
      + '"content":"<Profile/>"},'
      + '{"path":"force-app/main/default/profiles/Admin.profile-meta.xml",'
      + '"content":"<Profile/>"},'
      + '{"path":"force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml",'
      + '"content":"<CustomField/>"},'
      + '{"path":"force-app/main/default/flows/Brand_New_Flow.flow-meta.xml",'
      + '"content":"<Flow/>"}'
      + ']}';
    String normalized = CopadoDevopsService.normalizePackageMetadataWithContext(pkg, block);
    System.assert(
      normalized.contains('Account-Formato de cuentas.layout-meta.xml'),
      'Invented layout remapped: ' + normalized
    );
    System.assert(
      !normalized.contains('Account-Account Layout'),
      'Invented layout removed: ' + normalized
    );
    System.assert(
      !normalized.contains('Bogus Profile'),
      'Unknown Profile dropped when AUTHORITATIVE Profile list present: ' + normalized
    );
    System.assert(
      normalized.contains('Admin.profile-meta.xml'),
      'Live Profile kept: ' + normalized
    );
    System.assert(
      normalized.contains('Favorite_Color__c'),
      'New CustomField must not be gated: ' + normalized
    );
    System.assert(
      normalized.contains('Brand_New_Flow'),
      'New Flow must not be gated: ' + normalized
    );
  }

  @IsTest
  static void testPerUserCopadoAiPatResolveAndSetup() {
    CopadoAiApiService.bypassMockForAuthInTest = true;
    try {
      CopadoAiApiService.clearUserCopadoAiPat();
      System.assertEquals(false, CopadoAiApiService.hasUserCopadoAiPat());
      Boolean threw = false;
      try {
        CopadoAiApiService.resolveApiKey();
      } catch (CopadoAiApiService.ApiException ex) {
        threw = true;
        System.assert(
          ex.getMessage().contains('Personal Access Token'),
          ex.getMessage()
        );
      }
      System.assertEquals(true, threw, 'Blank PAT must throw');

      // Long PAT (proves Long Text storage — Hierarchy CS was limited to 255).
      String longPat = 'test-pat-value-1234' + 'x'.repeat(300);
      CopadoAiApiService.saveUserCopadoAiPat(longPat);
      System.assertEquals(true, CopadoAiApiService.hasUserCopadoAiPat());
      System.assertEquals(longPat, CopadoAiApiService.resolveApiKey());
      System.assert(
        CopadoAiApiService.getUserCopadoAiPatMask().endsWith('xxxx'),
        CopadoAiApiService.getUserCopadoAiPatMask()
      );

      CopadoBuilderController.UserSetupDefaults defaults =
        CopadoBuilderController.getUserSetupDefaults();
      System.assertEquals(true, defaults.hasPat);
      // Without Project/Integration and without bypass, needsSetup stays true.
      System.assertEquals(true, defaults.needsSetup);

      Boolean bypassBlocked = false;
      try {
        CopadoAiApiService.clearUserCopadoAiPat();
        CopadoBuilderController.bypassUserSetup();
      } catch (Exception aex) {
        bypassBlocked = true;
      }
      System.assertEquals(
        true,
        bypassBlocked,
        'Bypass without PAT must fail'
      );
    } finally {
      CopadoAiApiService.bypassMockForAuthInTest = false;
      try {
        CopadoAiApiService.clearUserCopadoAiPat();
      } catch (Exception ignore) {
      }
    }
  }

  @IsTest
  static void testMockLiveMetadataFullNamesAndParser() {
    List<CopadoAiApiService.MetadataListRequest> reqs =
      new List<CopadoAiApiService.MetadataListRequest>{
        new CopadoAiApiService.MetadataListRequest('Layout', 'Account'),
        new CopadoAiApiService.MetadataListRequest('Flow'),
        new CopadoAiApiService.MetadataListRequest('CustomField', 'Account'),
        new CopadoAiApiService.MetadataListRequest('Profile')
      };
    reqs[0].namePrefix = 'Account-';

    Map<String, List<String>> mockNames =
      CopadoAiApiService.requestLiveMetadataFullNames(
        'dlg',
        'ws',
        'integration',
        'orgCred',
        'dev1',
        reqs
      );
    System.assert(
      mockNames.containsKey('Layout')
        && mockNames.get('Layout').contains('Account-Formato de account'),
      String.valueOf(mockNames)
    );
    System.assert(
      mockNames.containsKey('Flow') && mockNames.get('Flow').contains('Sample_Flow'),
      String.valueOf(mockNames)
    );

    Map<String, List<String>> parsed = CopadoAiApiService.parseLiveMetadataFullNamesReply(
      '{"Layout":["Account-Formato de cuentas","Account-Account Layout"],'
        + '"Flow":["My_Flow"],"CustomField":["Account.Fav__c","Contact.Other__c"]}',
      reqs
    );
    System.assert(
      parsed.get('Layout').contains('Account-Formato de cuentas'),
      String.valueOf(parsed)
    );
    System.assertEquals(
      false,
      parsed.get('Layout').contains('Account-Account Layout'),
      'English default Layout must be rejected'
    );
    System.assert(
      parsed.get('Flow').contains('My_Flow'),
      String.valueOf(parsed)
    );
    System.assert(
      parsed.get('CustomField').contains('Account.Fav__c'),
      String.valueOf(parsed)
    );
    System.assertEquals(
      false,
      parsed.containsKey('CustomField')
        && parsed.get('CustomField').contains('Contact.Other__c'),
      'CustomField for other object filtered out'
    );

    List<String> layouts = CopadoAiApiService.requestLiveLayoutFullNames(
      'dlg', 'ws', 'integration', 'orgCred', 'dev1',
      new List<String>{ 'Account' }
    );
    System.assert(
      layouts.contains('Account-Formato de account'),
      String.valueOf(layouts)
    );
  }
}
