import 'package:rpc_dart/rpc_dart.dart';

import '../models/gitlab_event.dart';
import '../models/subscribe_request.dart';

export '../models/gitlab_event.dart';
export '../models/subscribe_request.dart';

/// RPC contract for receiving GitLab webhook events as typed streams.
///
/// The server side listens to incoming HTTP webhooks from GitLab,
/// parses them, and pushes them to connected clients via server-streaming RPC.
///
/// Each method is a server-stream: the client sends a [GitlabSubscribeRequest]
/// with optional filters and receives a continuous stream of typed events.
abstract interface class IGitlabWebhookContract implements IRpcContract {
  static const String serviceNameConst = 'GitlabWebhookService';

  // Method name constants
  static const String allEventsMethod = 'allEvents';
  static const String pushEventsMethod = 'pushEvents';
  static const String mergeRequestEventsMethod = 'mergeRequestEvents';
  static const String pipelineEventsMethod = 'pipelineEvents';
  static const String issueEventsMethod = 'issueEvents';
  static const String noteEventsMethod = 'noteEvents';
  static const String jobEventsMethod = 'jobEvents';
  static const String releaseEventsMethod = 'releaseEvents';
  static const String deploymentEventsMethod = 'deploymentEvents';

  /// Stream of all GitLab events (any type), optionally filtered.
  Stream<GitlabEvent> allEvents(GitlabSubscribeRequest request);

  /// Stream of push / tag push events.
  Stream<GitlabPushEvent> pushEvents(GitlabSubscribeRequest request);

  /// Stream of merge request events.
  Stream<GitlabMergeRequestEvent> mergeRequestEvents(GitlabSubscribeRequest request);

  /// Stream of pipeline events.
  Stream<GitlabPipelineEvent> pipelineEvents(GitlabSubscribeRequest request);

  /// Stream of issue events.
  Stream<GitlabIssueEvent> issueEvents(GitlabSubscribeRequest request);

  /// Stream of note (comment) events.
  Stream<GitlabNoteEvent> noteEvents(GitlabSubscribeRequest request);

  /// Stream of CI job events.
  Stream<GitlabJobEvent> jobEvents(GitlabSubscribeRequest request);

  /// Stream of release events.
  Stream<GitlabReleaseEvent> releaseEvents(GitlabSubscribeRequest request);

  /// Stream of deployment events.
  Stream<GitlabDeploymentEvent> deploymentEvents(GitlabSubscribeRequest request);
}
