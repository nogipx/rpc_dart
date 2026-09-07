// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttp2Server passed no ServerSettings, so every connection advertised
// package:http2's default MAX_CONCURRENT_STREAMS of 1000 no matter what
// RpcSecurityPolicy.maxActiveStreams said. Measured both ways:
//
//   policy 7    -> advertised 1000        (143x what the server will honour)
//   policy 4096 -> 1100 concurrent calls gave 1000 dispatched, 100 refused
//                  with status 8
//
// Two separate defects from one missing argument. Below 1000 the server LIES:
// a conforming client paces itself by the advertisement, opens streams it is
// then refused, and -- RESOURCE_EXHAUSTED being retryable -- retries into the
// same wall; real gRPC clients queue above the limit and would have succeeded.
// Above 1000 the knob is DEAD: `maxActiveStreams` meant 4096 on websocket and
// isolate and 1000 here, silently, which is the "a knob an operator sets and
// stops looking at" shape that got three others removed in round 118.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';

/// SETTINGS_MAX_CONCURRENT_STREAMS.
const _maxConcurrentStreams = 0x3;

final class _Svc extends RpcResponderContract {
  _Svc(this._onPark) : super('Svc');

  final void Function() _onPark;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Never finishes, so every accepted call holds its stream.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'park',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {context}) async* {
        _onPark();
        yield 'open'.rpc;
        await Future<void>.delayed(const Duration(minutes: 5));
      },
    );
  }
}

/// Speaks the HTTP/2 preface on a raw socket and decodes the server's SETTINGS.
///
/// Deliberately byte-level: package:http2 exposes no accessor for the peer's
/// settings, and going through it would test its bookkeeping rather than what
/// this server actually puts on the wire.
Future<Map<int, int>> readServerSettings(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final buffer = <int>[];
  final settings = Completer<Map<int, int>>();

  socket.listen((chunk) {
    buffer.addAll(chunk);
    var offset = 0;
    // Frame header: 3-byte length, 1-byte type, 1-byte flags, 4-byte stream.
    while (buffer.length - offset >= 9) {
      final length =
          (buffer[offset] << 16) |
          (buffer[offset + 1] << 8) |
          buffer[offset + 2];
      final type = buffer[offset + 3];
      final flags = buffer[offset + 4];
      if (buffer.length - offset - 9 < length) break;
      final payload = buffer.sublist(offset + 9, offset + 9 + length);
      offset += 9 + length;

      // type 0x4 = SETTINGS; flag bit 0 is ACK, which carries no payload.
      if (type == 0x4 && (flags & 0x1) == 0 && !settings.isCompleted) {
        final parsed = <int, int>{};
        for (var i = 0; i + 6 <= payload.length; i += 6) {
          parsed[(payload[i] << 8) | payload[i + 1]] =
              (payload[i + 2] << 24) |
              (payload[i + 3] << 16) |
              (payload[i + 4] << 8) |
              payload[i + 5];
        }
        settings.complete(parsed);
      }
    }
    buffer.removeRange(0, offset);
  }, onError: (Object _) {});

  socket.add(Uint8List.fromList(_preface.codeUnits));
  socket.add(Uint8List.fromList([0, 0, 0, 0x4, 0, 0, 0, 0, 0]));
  await socket.flush();

  final result = await settings.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => <int, int>{},
  );
  socket.destroy();
  return result;
}

/// Opens [attempts] parking calls and returns how many the handler dispatched.
Future<({int dispatched, int refused})> _openParkedCalls(
  RpcHttp2Server server,
  int attempts,
  int Function() dispatchedSoFar,
) async {
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
    logger: LogScope.noop,
  );
  final caller = RpcCallerEndpoint(transport: client);
  final subs = <StreamSubscription<RpcString>>[];
  var refused = 0;

  for (var i = 0; i < attempts; i++) {
    final settled = Completer<void>();
    try {
      subs.add(
        caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'park',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen(
              (_) {
                if (!settled.isCompleted) settled.complete();
              },
              onError: (Object _) {
                refused++;
                if (!settled.isCompleted) settled.complete();
              },
            ),
      );
      await settled.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => refused++,
      );
    } catch (_) {
      refused++;
    }
  }

  final result = (dispatched: dispatchedSoFar(), refused: refused);
  for (final sub in subs) {
    unawaited(sub.cancel());
  }
  await caller.close();
  return result;
}

void main() {
  test(
    'WITNESS: the advertised stream limit is the policy limit',
    () async {
      var parked = 0;
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 7),
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(() => parked++)),
      );
      await server.start();
      addTearDown(server.stop);

      final settings = await readServerSettings(server.port);

      expect(
        settings[_maxConcurrentStreams],
        7,
        reason:
            'the server advertised ${settings[_maxConcurrentStreams]} while it '
            'refuses everything past 7',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('the announcement stays honest at the edges of the field', () {
    // SETTINGS_MAX_CONCURRENT_STREAMS is a uint32 and RpcSecurityPolicy has no
    // assertions, so the policy field can hold anything an operator types. Once
    // it started going on the wire, the out-of-range values stopped being
    // merely odd. Read back at the byte level, before the clamp:
    //
    //   policy -1    -> advertised 4294967295  <- "unlimited", while the
    //                                             pipeline refuses EVERY stream
    //   policy 2^32  -> advertised 0           <- "open nothing", while the
    //   policy 2^40  -> advertised 0              server would serve billions
    //
    // The first is the very defect the announcement was added to fix, back at
    // the sign boundary. The second is what `1 << 32` in a config does.
    Future<int?> advertisedFor(int limit) async {
      var parked = 0;
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityPolicy: RpcSecurityPolicy(maxActiveStreams: limit),
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(() => parked++)),
      );
      await server.start();
      addTearDown(server.stop);
      final settings = await readServerSettings(server.port);
      return settings[_maxConcurrentStreams];
    }

    test('a negative limit announces 0, not "unlimited"', () async {
      expect(
        await advertisedFor(-1),
        0,
        reason:
            'a negative limit refuses every stream, so anything above 0 '
            'announces room that does not exist',
      );
    });

    test('a limit past the field announces the maximum, not 0', () async {
      expect(await advertisedFor(4294967296), 4294967295);
      expect(await advertisedFor(1 << 40), 4294967295);
    });

    test('GUARD: representable limits are untouched', () async {
      // Load-bearing: a clamp that also moved ordinary values would break the
      // witness above it, quietly.
      expect(await advertisedFor(1), 1);
      expect(await advertisedFor(0), 0);
      expect(await advertisedFor(4096), 4096);
      expect(await advertisedFor(4294967295), 4294967295);
    });
  });

  test(
    'WITNESS: maxActiveStreams above 1000 is no longer a dead knob',
    () async {
      // package:http2 enforces its OWN advertisement, so before the fix this
      // capped at 1000 whatever the policy said.
      var parked = 0;
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        // The default policy: 4096.
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(() => parked++)),
      );
      await server.start();
      addTearDown(server.stop);

      final result = await _openParkedCalls(server, 1100, () => parked);

      expect(
        result.dispatched,
        1100,
        reason:
            'only ${result.dispatched} of 1100 reached a handler '
            '(${result.refused} refused): the transport capped the policy',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('GUARD: the limit is still ENFORCED, not merely announced', () {
    test('a small policy still bounds concurrent handlers', () async {
      // Load-bearing in the opposite direction: advertising a number must not
      // become the only thing that stops a peer. If the announcement replaced
      // enforcement, a peer that ignores SETTINGS would get as many as it asked
      // for.
      var parked = 0;
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 3),
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(() => parked++)),
      );
      await server.start();
      addTearDown(server.stop);

      final result = await _openParkedCalls(server, 10, () => parked);

      expect(result.dispatched, lessThanOrEqualTo(3));
      expect(
        result.refused,
        greaterThan(0),
        reason: 'the calls past the ceiling must fail, not hang',
      );
    });

    test('ordinary calls still work', () async {
      // The settings argument is new plumbing on every connection; a broken
      // one would show up here first.
      var parked = 0;
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) =>
            e.registerServiceContract(_Svc(() => parked++)),
      );
      await server.start();
      addTearDown(server.stop);

      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        logger: LogScope.noop,
      );
      final caller = RpcCallerEndpoint(transport: client);

      final response = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'hello'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(response.value, 'hello');

      await caller.close();
    });
  });
}
