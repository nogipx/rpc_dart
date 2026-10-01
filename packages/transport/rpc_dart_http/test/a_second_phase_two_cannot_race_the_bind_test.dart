// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `afterModulesStart`'s guard read `_httpServer`, which is assigned AFTER the
// bind's await — so two concurrent callers both passed it, both built an endpoint
// over the SAME transport, and the one that lost the bind ran a catch that closed
// that shared transport and nulled `_endpoint`. The socket stayed bound,
// `isRunning` reported true, and every call was answered UNAVAILABLE: a total
// outage behind a health check that says the port is fine.
//
// The slot is claimed synchronously now. The same shape exists on the HTTP/2
// server, where the symptom is the opposite — see its own test.
//
// THE PORT MUST BE FIXED. With `port: 0` each concurrent bind gets its own
// ephemeral port, nothing fails, and the path under test never runs.
@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
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
  }
}

/// A port nothing listens on, so a second bind to it fails rather than getting
/// one of its own.
Future<int> _freePort() async {
  final s = await ServerSocket.bind('127.0.0.1', 0);
  final port = s.port;
  await s.close();
  return port;
}

typedef _Run = ({bool isRunning, int endpoints, String answer});

Future<_Run> _start({required int phaseTwo}) async {
  final port = await _freePort();
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: port,
    onEndpointCreated: (e) {
      e.registerServiceContract(_Echo());
      e.start();
    },
  );
  addTearDown(() => server.stop().catchError((Object _) {}));

  await server.start();
  await Future.wait(
    List.generate(
      phaseTwo,
      (_) => server.afterModulesStart().catchError((Object _) {}),
    ),
  );

  final transport = RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:$port');
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
  });

  String answer;
  try {
    final reply = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    answer = 'ok:${reply.value}';
  } on RpcStatusException catch (e) {
    answer = 'status ${e.statusCode}';
  }

  return (
    isRunning: server.isRunning,
    endpoints: server.endpoints.length,
    answer: answer,
  );
}

void main() {
  test(
    'WITNESS phase two without phase one NAMES the mistake',
    () async {
      // `_transport!` crashed with `Null check operator used on a null value`,
      // which says nothing about the two-phase ordering it is about. Same after a
      // stop(), which clears the transport.
      final server = RpcHttpServer(
        host: '127.0.0.1',
        port: await _freePort(),
        onEndpointCreated: (e) {},
      );

      await expectLater(
        server.afterModulesStart(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('start()'), contains('afterModulesStart()')),
          ),
        ),
      );

      // And the claim was released, so the ordinary sequence still works after the
      // mistake is corrected — the reason the throw happens before the claim is set.
      await server.start();
      await server.afterModulesStart();
      addTearDown(() => server.stop().catchError((Object _) {}));
      expect(server.isRunning, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL one phase-two serves calls',
    () async {
      // Without this the witness below cannot tell the race from a broken rig.
      final r = await _start(phaseTwo: 1);

      expect(r.answer, 'ok:x');
      expect(r.endpoints, 1);
      expect(r.isRunning, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS two concurrent phase-twos still serve calls',
    () async {
      final r = await _start(phaseTwo: 2);

      expect(
        r.answer,
        'ok:x',
        reason:
            'the loser closed the transport the winner was serving on, so every '
            'call came back UNAVAILABLE while the socket stayed bound',
      );
      expect(
        r.endpoints,
        1,
        reason: 'the loser nulled _endpoint, so the server reported none',
      );
      expect(r.isRunning, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
