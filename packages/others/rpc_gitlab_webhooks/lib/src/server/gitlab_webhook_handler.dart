import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/gitlab_event.dart';
import '../models/subscribe_request.dart';

/// Parses incoming GitLab webhook HTTP requests and broadcasts
/// typed [GitlabEvent]s to subscribers.
///
/// This is a pure component with no HTTP framework dependency.
/// Wire it into your HTTP server manually (dart:io, Shelf, etc.).
///
/// Example with dart:io:
/// ```dart
/// final handler = GitlabWebhookHandler(secretToken: 'my-secret');
/// final server = await HttpServer.bind('0.0.0.0', 8080);
/// server.listen((req) async {
///   if (req.method == 'POST' && req.uri.path == '/webhook') {
///     final response = await handler.handleHttpRequest(req);
///     req.response.statusCode = response;
///     await req.response.close();
///   }
/// });
/// ```
final class GitlabWebhookHandler {
  final String? secretToken;

  // Broadcast streams per event type
  final StreamController<GitlabEvent> _allController =
      StreamController<GitlabEvent>.broadcast();

  GitlabWebhookHandler({this.secretToken});

  /// Broadcast stream of all parsed GitLab events.
  Stream<GitlabEvent> get events => _allController.stream;

  /// Handle a dart:io [HttpRequest].
  ///
  /// Returns the HTTP status code to send back (200 or 4xx).
  Future<int> handleHttpRequest(HttpRequest request) async {
    // Verify token if configured
    if (secretToken != null) {
      final token = request.headers.value('x-gitlab-token');
      if (token != secretToken) return HttpStatus.unauthorized;
    }

    final body = await utf8.decodeStream(request);
    return handleRawPayload(
      eventHeader: request.headers.value('x-gitlab-event') ?? '',
      body: body,
    );
  }

  /// Handle a raw webhook payload.
  ///
  /// [eventHeader] is the value of `X-Gitlab-Event` header.
  /// Returns 200 on success, 400 on parse error.
  int handleRawPayload({required String eventHeader, required String body}) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;

      // Inject event_type derived from header for the factory to use
      final kind = _headerToKind(eventHeader);
      if (kind != null) {
        json.putIfAbsent('event_type', () => kind);
      }

      final event = GitlabEvent.fromJson(json);
      _allController.add(event);
      return HttpStatus.ok;
    } catch (_) {
      return HttpStatus.badRequest;
    }
  }

  /// Filtered stream based on a [GitlabSubscribeRequest].
  Stream<GitlabEvent> filteredStream(GitlabSubscribeRequest request) {
    return _allController.stream.where((event) {
      final ref = switch (event) {
        GitlabPushEvent e => e.ref,
        GitlabPipelineEvent e => e.ref,
        GitlabJobEvent e => e.ref,
        _ => null,
      };
      return request.matches(event.projectId, event.projectPath, ref: ref);
    });
  }

  void dispose() {
    _allController.close();
  }

  // Maps X-Gitlab-Event header value to object_kind string
  static String? _headerToKind(String header) {
    return switch (header.toLowerCase()) {
      'push hook' => 'push',
      'tag push hook' => 'tag_push',
      'merge request hook' => 'merge_request',
      'pipeline hook' => 'pipeline',
      'issue hook' => 'issue',
      'note hook' || 'confidential note hook' => 'note',
      'job hook' || 'build hook' => 'build',
      'release hook' => 'release',
      'deployment hook' => 'deployment',
      _ => null,
    };
  }
}
