// Developer Console → Execute Anonymous
// Prerequisites: Use Mock API = false; Named Credential Copado_AI_API configured.
// Replace CREDENTIAL_ID with a validated Dev Org Credential Id (copado__Org__c).
// Optional: set preferredIntegrationId to your User Level integration UUID.

String credentialId = 'CREDENTIAL_ID';
String orgName = 'dev1';
String preferredIntegrationId = null; // e.g. User Level UUID from My Integrations

CopadoAiApiService.WorkspaceResult ws = CopadoAiApiService.ensureBuilderWorkspace();
System.debug('workspaceId=' + ws.workspaceId);

CopadoAiApiService.DialogueResult dlg = CopadoAiApiService.createDialogue(
  ws.workspaceId,
  'Org Intelligence Probe'
);
System.debug('dialogueId=' + dlg.dialogueId);

List<CopadoAiApiService.IntegrationInfo> integrations =
  CopadoAiApiService.listActiveCopadoIntegrations(ws.workspaceId);
System.debug('integrations=' + JSON.serialize(integrations));
if (String.isBlank(preferredIntegrationId)) {
  for (CopadoAiApiService.IntegrationInfo info : integrations) {
    if (info.connected == true && info.name != null
      && info.name.toLowerCase().contains('user level')) {
      preferredIntegrationId = info.id;
      break;
    }
  }
}

CopadoAiApiService.OrgIntelligenceResult probe =
  CopadoAiApiService.ensureOrgIntelligence(
    ws.workspaceId,
    credentialId,
    orgName,
    dlg.dialogueId,
    true,
    preferredIntegrationId
  );

System.debug('success=' + probe.success);
System.debug('status=' + probe.status);
System.debug('integrationId=' + probe.integrationId);
System.debug('message=' + probe.message);
System.debug('probeAnswer=' + probe.probeAnswer);
System.debug('rawIntegrationsJson=' + probe.rawIntegrationsJson);
System.debug('rawConfigureJson=' + probe.rawConfigureJson);
System.debug('rawCheckStatusJson=' + probe.rawCheckStatusJson);
