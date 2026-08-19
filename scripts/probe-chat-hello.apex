// Developer Console → Execute Anonymous
// Verifies: workspace exists, dialogue create, HELLO round-trip.
// Prerequisites: Use Mock API = false; Named Credential Copado_AI_API configured.

CopadoAiApiService.WorkspaceResult ws = CopadoAiApiService.ensureBuilderWorkspace();
System.debug('workspaceId=' + ws.workspaceId + ' name=' + ws.workspaceName);

Map<String, String> live = CopadoAiApiService.resolveLiveChatIds(
  ws.workspaceId,
  null,
  'Builder HELLO Probe'
);
System.debug('live=' + JSON.serialize(live));

CopadoAiApiService.DialogueResult reply = CopadoAiApiService.sendDialogueMessage(
  live.get('dialogueId'),
  'HELLO',
  null,
  'build',
  live.get('workspaceId')
);
System.debug('pending=' + reply.pending);
System.debug('requestId=' + reply.requestId);
System.debug('dialogueId=' + reply.dialogueId);
System.debug('message=' + reply.message);

if (reply.pending == true) {
  for (Integer i = 0; i < 15; i++) {
    String polled = CopadoAiApiService.pollAssistantText(
      reply.dialogueId,
      reply.requestId,
      reply.baselineMessageCount,
      reply.baselineAssistantText
    );
    System.debug('poll[' + i + ']=' + polled);
    if (String.isNotBlank(polled)) {
      break;
    }
  }
}
