// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A characterisation of package:http2, kept because round 347 spent a round
// getting it wrong and the next reader should not have to.
//
// `rpc_http2_caller_transport.dart` says, above its close path:
//
//   terminate() ... is the right primitive on a dead connection anyway --
//   finish() on one throws from package:http2 into the root zone.
//
// That is exactly right, and round 347 still misread it: it chased the
// `unawaited(_connection.terminate())` on the line below as the source, on the
// grounds that `unawaited` detaches the future from the `try` around it. Three
// measurements later —
//
//   unawaited(terminate()) after finish()          StateError in the zone
//   terminate().catchError(...) after finish()     StateError in the zone
//   finish() and NOTHING else                      StateError in the zone
//
// — the third says it: `finish()` is the source, it throws AFTER its own future
// has completed, and no handler at the call site can see it. `.catchError` on
// terminate cannot help because terminate was never involved.
//
// So the transport's `try { await finish().timeout(...) } catch` is correct for
// what it CAN catch, and the zone throw is out of its reach. See B-35.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<RpcHttp2Server> _serve() async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  return server;
}

/// Runs [body] in a guarded zone and returns whatever escaped to it.
Future<List<Object>> escaped(Future<void> Function() body) async {
  final out = <Object>[];
  final settled = Completer<void>();
  // The zone's body is deliberately not awaited here: `settled` is what this
  // waits on, so an error that kills the body still lets the assertion run.
  unawaited(
    runZonedGuarded(() async {
          await body();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!settled.isCompleted) settled.complete();
        }, (error, stack) => out.add(error)) ??
        Future<void>.value(),
  );
  await settled.future.timeout(const Duration(seconds: 20));
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return out;
}

void main() {
  test(
    'finish() alone throws into the zone',
    () async {
      final server = await _serve();
      addTearDown(server.stop);

      final out = await escaped(() async {
        final socket = await Socket.connect('127.0.0.1', server.port);
        final conn = http2.ClientTransportConnection.viaSocket(socket);
        await conn.finish();
      });

      expect(
        out,
        isNotEmpty,
        reason:
            'if this stops throwing, the transport comment above close() is '
            'stale and B-35 can be closed',
      );
      expect(out.first, isA<StateError>());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a transport close reports nothing to the application',
    () async {
      // The property that actually matters, and the reason B-35 is a lead rather
      // than an incident: the transport's own close path does NOT reach the state
      // above, so no application sees this today.
      final server = await _serve();
      addTearDown(server.stop);

      final out = await escaped(() async {
        final t = await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: server.port,
        );
        final caller = RpcCallerEndpoint(transport: t);
        final reply = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Echo',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 10));
        expect(reply.value, 'x');

        await caller.close();
        await t.close();
        // Twice: the second runs against a connection the first tore down.
        await t.close();
      });

      expect(out, isEmpty, reason: 'closing a transport must stay silent');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
