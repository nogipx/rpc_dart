// Integration tests for rpc_gitlab_webhooks over a real dart:io WebSocket server.
import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_gitlab_webhooks/rpc_gitlab_webhooks.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Boots a real dart:io HTTP/WebSocket server on a random port.
Future<_WsTestServer> _startWsServer(
  GitlabWebhookHandler webhookHandler,
) async {
  final controller = StreamController<WebSocketChannel>.broadcast();
  final httpServer = await HttpServer.bind('127.0.0.1', 0);

  httpServer.transform(WebSocketTransformer()).listen((ws) {
    controller.add(IOWebSocketChannel(ws));
  });

  final rpcServer = RpcWebSocketServer.createWithContracts(
    connections: controller.stream,
    contracts: [GitlabWebhookResponder(handler: webhookHandler)],
  );
  await rpcServer.start();

  return _WsTestServer(httpServer, rpcServer, controller);
}

class _WsTestServer {
  final HttpServer httpServer;
  final RpcWebSocketServer rpcServer;
  final StreamController<WebSocketChannel> _controller;

  _WsTestServer(this.httpServer, this.rpcServer, this._controller);

  Uri get url => Uri.parse('ws://127.0.0.1:${httpServer.port}');

  Future<void> stop() async {
    await rpcServer.stop();
    await _controller.close();
    await httpServer.close(force: true);
  }
}

/// Creates a connected [GitlabWebhookCaller] and waits for the WS handshake.
Future<GitlabWebhookCaller> connectCaller(Uri url) async {
  final channel = WebSocketChannel.connect(url);
  await channel.ready;
  final transport = RpcWebSocketCallerTransport(channel);
  final endpoint = RpcCallerEndpoint(transport: transport);
  return GitlabWebhookCaller(endpoint);
}

/// Subscribes to [stream], fires [emitEvents], then collects up to [count]
/// events within [timeout]. Returns what was collected.
Future<List<T>> collectEvents<T>(
  Stream<T> stream,
  void Function() emitEvents, {
  int count = 1,
  Duration timeout = const Duration(seconds: 5),
}) async {
  // take(count) auto-completes the stream after receiving enough items.
  final future = stream.take(count).toList();
  await Future.delayed(const Duration(milliseconds: 30));
  emitEvents();
  return future.timeout(timeout);
}

// ── Payload builders ─────────────────────────────────────────────────────────

String pushPayload({
  String project = 'mygroup/myrepo',
  String ref = 'refs/heads/main',
  String userName = 'Alice',
}) =>
    '''
{
  "object_kind": "push",
  "ref": "$ref",
  "before": "aaa",
  "after": "bbb",
  "user_name": "$userName",
  "total_commits_count": 2,
  "project": { "path_with_namespace": "$project" }
}
''';

String mergeRequestPayload({String project = 'mygroup/myrepo'}) =>
    '''
{
  "object_kind": "merge_request",
  "user": { "name": "Bob" },
  "object_attributes": {
    "iid": 7,
    "title": "Fix bug",
    "action": "open",
    "source_branch": "fix",
    "target_branch": "main",
    "state": "opened",
    "url": "https://gitlab.example.com/mr/7"
  },
  "project": { "path_with_namespace": "$project" }
}
''';

String pipelinePayload({
  String project = 'mygroup/myrepo',
  String status = 'success',
  String ref = 'main',
}) =>
    '''
{
  "object_kind": "pipeline",
  "object_attributes": {
    "id": 99,
    "ref": "$ref",
    "status": "$status",
    "source": "push",
    "sha": "deadbeef"
  },
  "project": { "path_with_namespace": "$project" }
}
''';

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late GitlabWebhookHandler handler;
  late _WsTestServer server;

  setUp(() async {
    handler = GitlabWebhookHandler(secretToken: 'test-secret');
    server = await _startWsServer(handler);
  });

  tearDown(() async {
    handler.dispose();
    await server.stop();
  });

  // ── GitlabEvent model ────────────────────────────────────────────────────

  group('GitlabEvent parsing', () {
    test('push payload parses correctly', () {
      handler.handleRawPayload(eventHeader: 'Push Hook', body: pushPayload());
      // No exception = pass
    });

    test('unknown event_kind falls back to GitlabUnknownEvent', () {
      handler.handleRawPayload(
        eventHeader: 'Something New Hook',
        body:
            '{"object_kind": "new_thing", "project": {"path_with_namespace": "a/b"}}',
      );
    });

    test('invalid JSON returns 400', () {
      final status = handler.handleRawPayload(
        eventHeader: 'Push Hook',
        body: 'not-json',
      );
      expect(status, HttpStatus.badRequest);
    });
  });

  // ── GitlabSubscribeRequest filtering ────────────────────────────────────

  group('GitlabSubscribeRequest.matches', () {
    test('no filter matches everything', () {
      const req = GitlabSubscribeRequest.all();
      expect(req.matches(0, 'any/project'), isTrue);
      expect(req.matches(0, 'any/project', ref: 'main'), isTrue);
    });

    test('project filter accepts matching project', () {
      final req = GitlabSubscribeRequest(projectPaths: ['a/b']);
      expect(req.matches(0, 'a/b'), isTrue);
    });

    test('project filter rejects other project', () {
      final req = GitlabSubscribeRequest(projectPaths: ['a/b']);
      expect(req.matches(0, 'c/d'), isFalse);
    });

    test('ref filter accepts matching ref', () {
      final req = GitlabSubscribeRequest(refs: ['main']);
      expect(req.matches(0, 'a/b', ref: 'main'), isTrue);
    });

    test('ref filter rejects other ref', () {
      final req = GitlabSubscribeRequest(refs: ['main']);
      expect(req.matches(0, 'a/b', ref: 'dev'), isFalse);
    });

    test('combined filter: project matches, ref mismatches → reject', () {
      final req = GitlabSubscribeRequest(projectPaths: ['a/b'], refs: ['main']);
      expect(req.matches(0, 'a/b', ref: 'feature'), isFalse);
    });

    test('combined filter: both match → accept', () {
      final req = GitlabSubscribeRequest(projectPaths: ['a/b'], refs: ['main']);
      expect(req.matches(0, 'a/b', ref: 'main'), isTrue);
    });
  });

  // ── WebSocket RPC: allEvents ─────────────────────────────────────────────

  group('allEvents over WebSocket', () {
    test('receives push event', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.allEvents(const GitlabSubscribeRequest.all()),
        () => handler.handleRawPayload(
          eventHeader: 'Push Hook',
          body: pushPayload(),
        ),
      );

      expect(events, hasLength(1));
      final push = events.first as GitlabPushEvent;
      expect(push.userName, 'Alice');
      expect(push.ref, 'refs/heads/main');
      expect(push.projectPath, 'mygroup/myrepo');
    });

    test('receives multiple event types', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.allEvents(const GitlabSubscribeRequest.all()),
        () {
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(),
          );
          handler.handleRawPayload(
            eventHeader: 'Merge Request Hook',
            body: mergeRequestPayload(),
          );
          handler.handleRawPayload(
            eventHeader: 'Pipeline Hook',
            body: pipelinePayload(),
          );
        },
        count: 3,
      );

      expect(events[0], isA<GitlabPushEvent>());
      expect(events[1], isA<GitlabMergeRequestEvent>());
      expect(events[2], isA<GitlabPipelineEvent>());
    });
  });

  // ── WebSocket RPC: typed streams ─────────────────────────────────────────

  group('pushEvents over WebSocket', () {
    test('receives push event with correct fields', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.pushEvents(const GitlabSubscribeRequest.all()),
        () => handler.handleRawPayload(
          eventHeader: 'Push Hook',
          body: pushPayload(userName: 'Alice', ref: 'refs/heads/main'),
        ),
      );

      expect(events.single.userName, 'Alice');
      expect(events.single.ref, 'refs/heads/main');
      expect(events.single.commitCount, 2);
    });

    test('ignores non-push events', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.pushEvents(const GitlabSubscribeRequest.all()),
        () {
          // MR first, then push — expect only push
          handler.handleRawPayload(
            eventHeader: 'Merge Request Hook',
            body: mergeRequestPayload(),
          );
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(),
          );
        },
      );

      expect(events, hasLength(1));
      expect(events.single, isA<GitlabPushEvent>());
    });

    test('project filter: delivers matching, skips other', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.pushEvents(
          GitlabSubscribeRequest(projectPaths: ['mygroup/myrepo']),
        ),
        () {
          // other project first
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(project: 'other/repo'),
          );
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(project: 'mygroup/myrepo'),
          );
        },
      );

      expect(events, hasLength(1));
      expect(events.single.projectPath, 'mygroup/myrepo');
    });

    test('ref filter: delivers matching ref only', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.pushEvents(GitlabSubscribeRequest(refs: ['refs/heads/main'])),
        () {
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(ref: 'refs/heads/feature'),
          );
          handler.handleRawPayload(
            eventHeader: 'Push Hook',
            body: pushPayload(ref: 'refs/heads/main'),
          );
        },
      );

      expect(events, hasLength(1));
      expect(events.single.ref, 'refs/heads/main');
    });
  });

  group('pipelineEvents over WebSocket', () {
    test('receives pipeline event with correct fields', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.pipelineEvents(const GitlabSubscribeRequest.all()),
        () => handler.handleRawPayload(
          eventHeader: 'Pipeline Hook',
          body: pipelinePayload(status: 'failed', ref: 'develop'),
        ),
      );

      expect(events.single.status, 'failed');
      expect(events.single.ref, 'develop');
      expect(events.single.pipelineId, 99);
    });
  });

  group('mergeRequestEvents over WebSocket', () {
    test('receives MR event with correct fields', () async {
      final caller = await connectCaller(server.url);
      final events = await collectEvents(
        caller.mergeRequestEvents(const GitlabSubscribeRequest.all()),
        () => handler.handleRawPayload(
          eventHeader: 'Merge Request Hook',
          body: mergeRequestPayload(),
        ),
      );

      expect(events.single.mrIid, 7);
      expect(events.single.title, 'Fix bug');
      expect(events.single.action, 'open');
      expect(events.single.authorName, 'Bob');
    });
  });

  // ── Multiple clients ─────────────────────────────────────────────────────

  group('multiple clients', () {
    test('two clients each receive events independently', () async {
      final callerA = await connectCaller(server.url);
      final callerB = await connectCaller(server.url);

      // Both listen before events are fired
      final futureA = callerA
          .pushEvents(const GitlabSubscribeRequest.all())
          .take(1)
          .toList();
      final futureB = callerB
          .pushEvents(const GitlabSubscribeRequest.all())
          .take(1)
          .toList();

      await Future.delayed(const Duration(milliseconds: 50));
      handler.handleRawPayload(eventHeader: 'Push Hook', body: pushPayload());

      final results = await Future.wait([
        futureA.timeout(const Duration(seconds: 5)),
        futureB.timeout(const Duration(seconds: 5)),
      ]);

      expect(results[0], hasLength(1));
      expect(results[1], hasLength(1));
    });

    test('clients with different filters receive different events', () async {
      final callerAll = await connectCaller(server.url);
      final callerFiltered = await connectCaller(server.url);

      final futureAll = callerAll
          .pushEvents(const GitlabSubscribeRequest.all())
          .take(2)
          .toList();
      final futureFiltered = callerFiltered
          .pushEvents(GitlabSubscribeRequest(projectPaths: ['mygroup/myrepo']))
          .take(1)
          .toList();

      await Future.delayed(const Duration(milliseconds: 50));
      handler.handleRawPayload(
        eventHeader: 'Push Hook',
        body: pushPayload(project: 'mygroup/myrepo'),
      );
      handler.handleRawPayload(
        eventHeader: 'Push Hook',
        body: pushPayload(project: 'other/repo'),
      );

      final results = await Future.wait([
        futureAll.timeout(const Duration(seconds: 5)),
        futureFiltered.timeout(const Duration(seconds: 5)),
      ]);

      expect(results[0], hasLength(2)); // all events pass
      expect(results[1], hasLength(1)); // only mygroup/myrepo
      expect(results[1].first.projectPath, 'mygroup/myrepo');
    });
  });

  // ── Signature validation ─────────────────────────────────────────────────

  group('signature validation', () {
    test('valid token returns 200', () async {
      final req = _FakeHttpRequest(
        body: pushPayload(),
        headers: {
          'x-gitlab-token': 'test-secret',
          'x-gitlab-event': 'Push Hook',
        },
      );
      final status = await handler.handleHttpRequest(req);
      expect(status, HttpStatus.ok);
    });

    test('wrong token returns 401', () async {
      final req = _FakeHttpRequest(
        body: pushPayload(),
        headers: {
          'x-gitlab-token': 'wrong-secret',
          'x-gitlab-event': 'Push Hook',
        },
      );
      final status = await handler.handleHttpRequest(req);
      expect(status, HttpStatus.unauthorized);
    });

    test('missing token returns 401', () async {
      final req = _FakeHttpRequest(
        body: pushPayload(),
        headers: {'x-gitlab-event': 'Push Hook'},
      );
      final status = await handler.handleHttpRequest(req);
      expect(status, HttpStatus.unauthorized);
    });

    test('handler without secretToken accepts any request', () async {
      final noAuthHandler = GitlabWebhookHandler();
      addTearDown(noAuthHandler.dispose);

      final req = _FakeHttpRequest(
        body: pushPayload(),
        headers: {'x-gitlab-event': 'Push Hook'},
      );
      final status = await noAuthHandler.handleHttpRequest(req);
      expect(status, HttpStatus.ok);
    });
  });
}

// ── Fake HttpRequest for signature tests ─────────────────────────────────────

class _FakeHttpRequest implements HttpRequest {
  final String _body;
  final Map<String, String> _headers;

  _FakeHttpRequest({required String body, required Map<String, String> headers})
    : _body = body,
      _headers = {
        for (final e in headers.entries) e.key.toLowerCase(): e.value,
      };

  @override
  HttpHeaders get headers => _FakeHttpHeaders(_headers);

  @override
  String get method => 'POST';

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.value(Uint8List.fromList(_body.codeUnits)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not implemented in _FakeHttpRequest',
  );
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> _map;
  _FakeHttpHeaders(this._map);

  @override
  String? value(String name) => _map[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not implemented in _FakeHttpHeaders',
  );
}
