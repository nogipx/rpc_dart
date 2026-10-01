// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every per-stream map on the caller transport is reported through `health()`
// because growth in one is the observable symptom of an entry added and never
// removed. `halfClosedLocal` was the only one NOT reported — and it is the one
// whose add in `sendMessage` happens AFTER an await, so a release landing in that
// window leaves an entry nothing removes again (B-184).
//
// This asserts the invariant across ALL of them rather than the race in
// particular: after calls that have completed, nothing per-stream may remain.
//
// WHAT ITS `halfClosedLocal` ROW IS NOT. Ablating BOTH removal paths for that map
// (`releaseStreamId` and the inline release) changes nothing here, which means the
// shapes below never populate it — unary and server-stream carry their half-close
// some other way. So that row is a VACUOUS zero for these shapes and guards
// nothing; it is kept only for the `containsKey` half, which is what was actually
// missing. A rig that fills the map is what B-184's remaining item needs.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Tick',
      handler: (r, {RpcContext? context}) async* {
        yield r;
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// The per-stream maps `health()` reports, by name.
const _perStream = [
  'activeStreams',
  'pendingSubscriptions',
  'pendingParsers',
  'halfClosedLocal',
  'fcOutstanding',
  'outgoingPumps',
  'streamControllers',
];

void main() {
  test(
    'every per-stream map returns to zero after completed calls',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
      );
      await server.start();
      addTearDown(() => server.stop().catchError((Object _) {}));

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      // Both shapes, several times: one unary call leaves little behind by
      // accident, and a repeat is what turns a leak into a trend.
      for (var i = 0; i < 5; i++) {
        final reply = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 10));
        expect(reply.value, 'x$i');

        final ticks = await caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Tick',
              request: 'y$i'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .toList()
            .timeout(const Duration(seconds: 10));
        expect(ticks, hasLength(2));
      }

      // Let any detached teardown settle; a leak does not go away with time and a
      // late removal is not one.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final details = (await transport.health()).details;
      for (final key in _perStream) {
        expect(
          details[key],
          0,
          reason:
              '$key holds an entry after every call completed — a per-stream map '
              'that grows is how a connection leaks over its lifetime',
        );
        // And the key must EXIST: a map nobody reports is a leak nobody can see,
        // which is how halfClosedLocal came to be the unreported one.
        expect(
          details.containsKey(key),
          isTrue,
          reason: '$key is not reported',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
