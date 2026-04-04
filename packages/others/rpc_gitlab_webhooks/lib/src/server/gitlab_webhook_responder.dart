import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../contract/gitlab_webhook_contract.dart';
import 'gitlab_webhook_handler.dart';

/// RPC responder that bridges [GitlabWebhookHandler] to RPC clients.
///
/// Register this with your [RpcResponderEndpoint]:
/// ```dart
/// final responder = GitlabWebhookResponder(handler: webhookHandler);
/// final endpoint = RpcResponderEndpoint(transport);
/// endpoint.registerContract(responder);
/// await endpoint.start();
/// ```
final class GitlabWebhookResponder extends RpcResponderContract
    implements IGitlabWebhookContract {
  final GitlabWebhookHandler handler;

  GitlabWebhookResponder({required this.handler})
      : super(IGitlabWebhookContract.serviceNameConst);

  @override
  String get serviceName => IGitlabWebhookContract.serviceNameConst;

  @override
  void setup() {
    addServerStreamMethod<GitlabSubscribeRequest, GitlabEvent>(
      methodName: IGitlabWebhookContract.allEventsMethod,
      handler: allEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: GitlabEvent.codec,
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabPushEvent>(
      methodName: IGitlabWebhookContract.pushEventsMethod,
      handler: pushEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabPushEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabMergeRequestEvent>(
      methodName: IGitlabWebhookContract.mergeRequestEventsMethod,
      handler: mergeRequestEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabMergeRequestEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabPipelineEvent>(
      methodName: IGitlabWebhookContract.pipelineEventsMethod,
      handler: pipelineEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabPipelineEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabIssueEvent>(
      methodName: IGitlabWebhookContract.issueEventsMethod,
      handler: issueEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabIssueEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabNoteEvent>(
      methodName: IGitlabWebhookContract.noteEventsMethod,
      handler: noteEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabNoteEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabJobEvent>(
      methodName: IGitlabWebhookContract.jobEventsMethod,
      handler: jobEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabJobEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabReleaseEvent>(
      methodName: IGitlabWebhookContract.releaseEventsMethod,
      handler: releaseEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabReleaseEvent.fromJson),
    );

    addServerStreamMethod<GitlabSubscribeRequest, GitlabDeploymentEvent>(
      methodName: IGitlabWebhookContract.deploymentEventsMethod,
      handler: deploymentEvents,
      requestCodec: GitlabSubscribeRequest.codec,
      responseCodec: RpcCodec(GitlabDeploymentEvent.fromJson),
    );
  }

  @override
  Stream<GitlabEvent> allEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request);

  @override
  Stream<GitlabPushEvent> pushEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabPushEvent).cast<GitlabPushEvent>();

  @override
  Stream<GitlabMergeRequestEvent> mergeRequestEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabMergeRequestEvent).cast<GitlabMergeRequestEvent>();

  @override
  Stream<GitlabPipelineEvent> pipelineEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabPipelineEvent).cast<GitlabPipelineEvent>();

  @override
  Stream<GitlabIssueEvent> issueEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabIssueEvent).cast<GitlabIssueEvent>();

  @override
  Stream<GitlabNoteEvent> noteEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabNoteEvent).cast<GitlabNoteEvent>();

  @override
  Stream<GitlabJobEvent> jobEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabJobEvent).cast<GitlabJobEvent>();

  @override
  Stream<GitlabReleaseEvent> releaseEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabReleaseEvent).cast<GitlabReleaseEvent>();

  @override
  Stream<GitlabDeploymentEvent> deploymentEvents(
    GitlabSubscribeRequest request, {
    RpcContext? context,
  }) =>
      handler.filteredStream(request).where((e) => e is GitlabDeploymentEvent).cast<GitlabDeploymentEvent>();
}
