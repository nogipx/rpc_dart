// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpServer starts in two phases -- start() builds the transport,
// afterModulesStart() creates the endpoint, starts it and binds the port --
// and stop() understood only the state that a fully successful pair leaves
// behind. It returned early on `!_isRunning`, and _isRunning is set on the
// line after the bind, so every partial state was unreachable to cleanup.
// Neither phase had an idempotency guard either, so a second call orphaned
// whatever the first had built.
//
// Measured, counting contract dispose() calls -- endpoint.close() disposes
// every registered contract via RpcResponderRegistry.disposeAll, so it is the
// library's own definition of "this endpoint was released":
//
//   bind fails, then stop() : disposed=[]   endpoints=1
//   afterModulesStart() x2  : disposed=[#1] -- endpoint #0 never released,
//                             and its listener stayed open, answering
//                             HTTP 503 on the first port forever
//
// Both sibling servers guard their start() with `if (_isRunning) return;` and
// close whatever exists in stop(); this one was the odd one out.
//
// Note on liveness checks: a bare Socket.connect to a dead loopback port is
// NOT a reliable probe here. Ephemeral source ports land in the same range, so
// connect() to a just-released port intermittently succeeds against itself --
// the same port measured `tcp=true` and `tcp=false` within one run. A real
// HTTP request is the observable that distinguishes "an RPC server answered"
// from "some socket accepted".

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract(this.tag, this.disposed) : super('Svc');

  final String tag;
  final List<String> disposed;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }

  @override
  void dispose() => disposed.add(tag);
}

/// A server whose every endpoint registers a contract that records its own
/// creation into [created] and its own disposal into [disposed]. Every entry
/// in [created] must end up in [disposed] once the server is stopped.
RpcHttpServer _build(int port, List<String> created, List<String> disposed) {
  return RpcHttpServer(
    host: '127.0.0.1',
    port: port,
    onEndpointCreated: (endpoint) {
      final tag = '#${created.length}';
      created.add(tag);
      endpoint.registerServiceContract(_Contract(tag, disposed));
    },
  );
}

/// Sends a real gRPC-shaped POST and reports the status, or null if nothing
/// answered. See the header note on why Socket.connect is not used.
Future<int?> _statusFrom(int port) async {
  final client = HttpClient();
  try {
    final req = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/Svc/echo'))
        .timeout(const Duration(seconds: 3));
    req.headers.set('content-type', 'application/grpc+json');
    req.add(const [0, 0, 0, 0, 0]);
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    return res.statusCode;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<String> _callOnce(int port) async {
  final transport = RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:$port');
  final caller = RpcCallerEndpoint(transport: transport);
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    await caller.close();
    await transport.close();
    return r.value;
  } on TimeoutException {
    // Deliberately not closed here: closing an endpoint with a timed-out call
    // still in flight raises RpcCancelledException into the root zone, which
    // takes the runner down instead of failing this test.
    return 'HUNG';
  }
}

void main() {
  test('a failed bind releases the endpoint it already created', () async {
    // "Address already in use" is the ordinary way this bind fails.
    final squatter = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(squatter.close);

    final created = <String>[];
    final disposed = <String>[];
    final server = _build(squatter.port, created, disposed);

    await server.start();
    await expectLater(server.afterModulesStart(), throwsA(isA<Object>()));
    await server.stop();

    expect(created, isNotEmpty, reason: 'the endpoint really was created');
    expect(
      disposed,
      created,
      reason:
          'the endpoint was created, handed the application its contracts and '
          'started, and then nothing could release it: stop() gave up on '
          '!_isRunning, which the bind never got far enough to set',
    );
    expect(
      server.endpoints,
      isEmpty,
      reason: 'a stopped server must not hand out a dead endpoint',
    );
  });

  test('afterModulesStart() twice does not leave a second listener', () async {
    final created = <String>[];
    final disposed = <String>[];
    final server = _build(0, created, disposed);

    await server.start();
    await server.afterModulesStart();
    final firstPort = server.actualPort!;

    await server.afterModulesStart();

    expect(
      server.actualPort,
      firstPort,
      reason:
          'the second call bound a second port and overwrote _httpServer, so '
          'nothing held the first listener any more',
    );
    expect(created, hasLength(1), reason: 'only one endpoint may be built');

    await server.stop();

    expect(disposed, created, reason: 'every endpoint built must be released');
    expect(
      await _statusFrom(firstPort),
      isNull,
      reason:
          'the orphaned listener stayed up after stop() and answered HTTP 503 '
          'to every request -- a dead server squatting on a live port',
    );
  });

  // GUARD, confirmed by the canary: this passes on both sides. start() twice
  // only ever duplicated the TRANSPORT, and a transport with no endpoint on it
  // holds no OS resource and no contract, so there is nothing observable to
  // fail. The guard on start() is there for consistency with both siblings and
  // to keep the second call from stranding a transport an endpoint is already
  // using; the test pins that adding it broke nothing.
  test('GUARD: start() twice builds one server, and it serves', () async {
    final created = <String>[];
    final disposed = <String>[];
    final server = _build(0, created, disposed);

    await server.start();
    await server.start();
    await server.afterModulesStart();
    addTearDown(server.stop);

    expect(await _callOnce(server.actualPort!), 'echo-ok');
    await server.stop();
    expect(disposed, created);
  });

  test(
    'a retry after a failed bind serves, and releases both attempts',
    () async {
      // The realistic sequel to the first test: the port is busy because the
      // previous instance has not let go, so the app waits and calls again.
      //
      // Half witness, half guard, and the canary says which is which:
      //  - "still serves" PASSES pre-fix. It is a guard, and a load-bearing one:
      //    RpcEndpointBase.close() closes the transport it was given, so an
      //    early version of this fix cleaned up the failed attempt, bound the
      //    retry successfully, and then answered 503 to every call. Trading a
      //    leak for silent unavailability would have been the worse bug.
      //  - "releases both attempts" FAILS pre-fix with ['#1'] against ['#0',
      //    '#1']: the abandoned first endpoint was never released, so an app
      //    retrying a busy port leaked one endpoint per attempt.
      final blocker = await ServerSocket.bind('127.0.0.1', 0);
      final port = blocker.port;

      final created = <String>[];
      final disposed = <String>[];
      final server = _build(port, created, disposed);

      await server.start();
      await expectLater(server.afterModulesStart(), throwsA(isA<Object>()));

      await blocker.close();
      await server.afterModulesStart().timeout(const Duration(seconds: 5));
      addTearDown(server.stop);

      expect(await _callOnce(port), 'echo-ok');

      await server.stop();
      expect(disposed, created, reason: 'both attempts must be released');
    },
  );

  test(
    'GUARD: the happy path still round-trips, restarts and stops twice',
    () async {
      final created = <String>[];
      final disposed = <String>[];
      final server = _build(0, created, disposed);

      await server.start();
      await server.afterModulesStart();
      final port = server.actualPort!;
      expect(await _callOnce(port), 'echo-ok');
      expect(server.isRunning, isTrue);

      await server.stop();
      expect(server.isRunning, isFalse);
      expect(await _statusFrom(port), isNull, reason: 'the port is released');

      await server.start();
      await server.afterModulesStart();
      addTearDown(server.stop);
      expect(await _callOnce(server.actualPort!), 'echo-ok');

      await server.stop();
      await server.stop().timeout(const Duration(seconds: 5));
      expect(disposed, created, reason: 'both runs released their endpoints');
    },
  );

  test('GUARD: stop() on a server that was never started is a no-op', () async {
    final server = _build(0, <String>[], <String>[]);
    await server.stop().timeout(const Duration(seconds: 5));
    expect(server.isRunning, isFalse);
    expect(server.endpoints, isEmpty);
  });
}
