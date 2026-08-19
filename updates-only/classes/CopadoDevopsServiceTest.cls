@IsTest
private class CopadoDevopsServiceTest {

  @IsTest
  static void testListOrgsAndMockCommitDeploy() {
    List<CopadoAiApiService.OrgInfo> orgs = CopadoDevopsService.listPipelineOrgs();
    System.assert(!orgs.isEmpty(), 'Should return pipeline orgs');

    CopadoDevopsService.JobResult commitJob = CopadoDevopsService.commitToUserStory(
      UserInfo.getUserId(),
      '{"files":[]}',
      'test commit',
      new List<String>{
        'force-app/main/default/objects/Account/fields/Favorite_Color__c.field-meta.xml'
      }
    );
    System.assertNotEquals(null, commitJob.jobId);
    System.assertEquals('mock', commitJob.method);

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
  }
}
