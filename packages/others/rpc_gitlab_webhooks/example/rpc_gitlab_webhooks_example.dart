import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_gitlab_webhooks/rpc_gitlab_webhooks.dart';

/// Example showing the full bridge with an in-memory transport.
///
/// In production, replace the in-memory transport with rpc_dart_websocket:
///
///   Server:
///     final rpcServer = RpcWebSocketServer.createWithContracts(
///       connections: wsConnectionStream,
///       contracts: [responder],
///     );
///     await rpcServer.start();
///
///   Client:
///     final transport = RpcWebSocketCallerTransport.connect(Uri.parse('ws://host:port'));
///     final callerEndpoint = RpcCallerEndpoint(transport: transport);
///     final caller = GitlabWebhookCaller(callerEndpoint);
void main() async {
  // ── Wire up in-memory transport (simulates WebSocket) ────────────────────
  final (serverTransport, clientTransport) = RpcInMemoryTransport.pair();

  // ── Server side ──────────────────────────────────────────────────────────

  // Component 1: receives HTTP POST payloads from GitLab
  final webhookHandler = GitlabWebhookHandler(secretToken: 'my-gitlab-secret');

  // Component 2: bridges handler events → RPC streams
  final responder = GitlabWebhookResponder(handler: webhookHandler);

  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
  responderEndpoint.registerServiceContract(responder);
  responderEndpoint.start();

  // ── Client side ──────────────────────────────────────────────────────────

  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
  final caller = GitlabWebhookCaller(callerEndpoint);

  // Subscribe to push events, filtered to a specific project
  final pushSub = caller
      .pushEvents(GitlabSubscribeRequest(projectPaths: ['mygroup/myrepo']))
      .listen((event) {
    print('[push] ${event.projectPath} @ ${event.ref} by ${event.userName}');
  });

  // Subscribe to all pipeline events (no filter)
  final pipelineSub = caller
      .pipelineEvents(const GitlabSubscribeRequest.all())
      .listen((event) {
    print('[pipeline] ${event.projectPath} #${event.pipelineId} — ${event.status}');
  });

  // ── Simulate incoming GitLab webhooks ────────────────────────────────────

  // Push event — should be received by pushSub
  webhookHandler.handleRawPayload(
    eventHeader: 'Push Hook',
    body: '''
    {
      "object_kind": "push",
      "ref": "refs/heads/main",
      "before": "aaa",
      "after": "bbb",
      "user_name": "Alice",
      "total_commits_count": 3,
      "project": { "path_with_namespace": "mygroup/myrepo" }
    }
    ''',
  );

  // Push event for another project — should be filtered out
  webhookHandler.handleRawPayload(
    eventHeader: 'Push Hook',
    body: '''
    {
      "object_kind": "push",
      "ref": "refs/heads/dev",
      "before": "ccc",
      "after": "ddd",
      "user_name": "Bob",
      "total_commits_count": 1,
      "project": { "path_with_namespace": "othergroup/other-repo" }
    }
    ''',
  );

  // Pipeline event — should be received by pipelineSub
  webhookHandler.handleRawPayload(
    eventHeader: 'Pipeline Hook',
    body: '''
    {
      "object_kind": "pipeline",
      "object_attributes": {
        "id": 42,
        "ref": "main",
        "status": "success",
        "source": "push",
        "sha": "abc123"
      },
      "project": { "path_with_namespace": "mygroup/myrepo" }
    }
    ''',
  );

  // Let streams drain
  await Future.delayed(Duration(milliseconds: 100));

  await pushSub.cancel();
  await pipelineSub.cancel();
  webhookHandler.dispose();

  exit(0);
}
