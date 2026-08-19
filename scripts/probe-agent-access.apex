// Developer Console → Execute Anonymous
// Dumps org feature_list + which agent workers this API key can start.
// Org Intelligence needs: POST /organizations/{id}/agents with agent=build → session_id.

System.debug('=== Organization (feature_list) ===');
Map<String, Object> org = CopadoAiApiService.readOrganization();
System.debug(JSON.serialize(org));

CopadoAiApiService.WorkspaceResult ws = CopadoAiApiService.ensureBuilderWorkspace();
System.debug('workspaceId=' + ws.workspaceId);

Map<String, Object> fullWs = null;
try {
  // Re-read workspace for assistants + capabilities
  HttpRequest req = new HttpRequest();
  CopadoAiApiService.Settings s = CopadoAiApiService.getSettings();
  req.setEndpoint(
    'callout:Copado_AI_API/organizations/' + s.organizationId
      + '/workspaces/' + ws.workspaceId
  );
  req.setMethod('GET');
  req.setHeader('Content-Type', 'application/json');
  // Per-user PAT from Copado_Builder_Auth__c (Builder setup modal)
  String pat = CopadoAiApiService.resolveApiKey();
  req.setHeader('X-Authorization', pat);
  req.setHeader('Api-Key', pat);
  HttpResponse wr = new Http().send(req);
  System.debug('=== Workspace ' + wr.getStatusCode() + ' ===');
  System.debug(wr.getBody() != null ? wr.getBody().left(4000) : '');
} catch (Exception ex) {
  System.debug('workspace read error=' + ex.getMessage());
}

CopadoAiApiService.DialogueResult dlg = CopadoAiApiService.createDialogue(
  ws.workspaceId,
  'Agent Access Probe'
);
System.debug('dialogueId=' + dlg.dialogueId);

List<String> agents = new List<String>{
  'build', 'plan', 'knowledge', 'test', 'release', 'operate'
};
System.debug('=== Agent worker start (POST /agents) ===');
for (String agent : agents) {
  Map<String, Object> result = CopadoAiApiService.tryStartAgentWorker(
    agent,
    ws.workspaceId,
    dlg.dialogueId,
    null
  );
  if (result != null && result.containsKey('session_id')) {
    System.debug('OK agent=' + agent + ' session_id=' + result.get('session_id'));
  } else {
    System.debug('FAIL agent=' + agent + ' ' + JSON.serialize(result));
  }
}
