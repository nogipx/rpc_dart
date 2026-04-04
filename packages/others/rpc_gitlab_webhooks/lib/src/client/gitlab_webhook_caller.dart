import 'package:rpc_dart/rpc_dart.dart';

import '../contract/gitlab_webhook_contract.dart';

/// RPC caller (client) for receiving GitLab webhook events over WebSocket.
///
/// Example:
/// ```dart
/// final transport = await RpcWebSocketTransport.connect(Uri.parse('ws://localhost:4040'));
/// final endpoint = RpcCallerEndpoint(transport);
/// final caller = GitlabWebhookCaller(endpoint);
///
/// caller.pushEvents(GitlabSubscribeRequest(projectPaths: ['mygroup/myrepo']))
///   .listen((event) => print('Push: ${event.ref}'));
/// ```
final class GitlabWebhookCaller extends RpcCallerContract
    implements IGitlabWebhookContract {
  GitlabWebhookCaller(RpcCallerEndpoint endpoint)
      : super(IGitlabWebhookContract.serviceNameConst, endpoint);

  @override
  String get serviceName => IGitlabWebhookContract.serviceNameConst;

  @override
  Stream<GitlabEvent> allEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabEvent>(
      methodName: IGitlabWebhookContract.allEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: GitlabEvent.codec,
      context: context,
    );
  }

  @override
  Stream<GitlabPushEvent> pushEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabPushEvent>(
      methodName: IGitlabWebhookContract.pushEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabPushEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabMergeRequestEvent> mergeRequestEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabMergeRequestEvent>(
      methodName: IGitlabWebhookContract.mergeRequestEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabMergeRequestEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabPipelineEvent> pipelineEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabPipelineEvent>(
      methodName: IGitlabWebhookContract.pipelineEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabPipelineEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabIssueEvent> issueEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabIssueEvent>(
      methodName: IGitlabWebhookContract.issueEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabIssueEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabNoteEvent> noteEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabNoteEvent>(
      methodName: IGitlabWebhookContract.noteEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabNoteEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabJobEvent> jobEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabJobEvent>(
      methodName: IGitlabWebhookContract.jobEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabJobEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabReleaseEvent> releaseEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabReleaseEvent>(
      methodName: IGitlabWebhookContract.releaseEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabReleaseEvent.fromJson),
      context: context,
    );
  }

  @override
  Stream<GitlabDeploymentEvent> deploymentEvents(GitlabSubscribeRequest request, {RpcContext? context}) {
    return callServerStream<GitlabSubscribeRequest, GitlabDeploymentEvent>(
      methodName: IGitlabWebhookContract.deploymentEventsMethod,
      request: request,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabDeploymentEvent.fromJson),
      context: context,
    );
  }
}
