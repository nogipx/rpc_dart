// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `maxActiveStreams` was inert on this caller: it referenced the field nowhere.
// 12 concurrent calls against a parked server, ceiling 4:
//
//                    admitted  refused  peak concurrent server requests
//   core (channel)      4         8
//   http2               4         8
//   HTTP/1.1           12         0                 12          <- before
//
// The lead's counter-hypothesis was that the HttpClient connection pool already
// bounds this, making the limit meaningless rather than missing. It does not:
// every one of the 12 was open at the server at once, because dart:io's default
// `maxConnectionsPerHost` is unlimited.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Handlers park here, so every admitted call still holds its slot when the
/// next one asks for one.
var _park = Completer<void>();

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      handler: (request, {RpcContext? context}) async {
        await _park.future;
        return 'pong'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A caller bounded at [ceiling] against a responder that is not bounded.
Future<RpcCallerEndpoint> _caller(int ceiling) async {
  final responderTransport = RpcHttpResponderTransport(
    // Deliberately far above the caller's, so a refusal can only be the
    // caller's own ceiling.
    securityPolicy: const RpcSecurityPolicy(maxActiveStreams: 1024),
  );
  final responder = RpcResponderEndpoint(transport: responderTransport);
  responder.registerServiceContract(_Svc());
  responder.start();
  final server = await shelf_io.serve(
    responderTransport.handler,
    '127.0.0.1',
    0,
  );

  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
    policy: RpcSecurityPolicy(maxActiveStreams: ceiling),
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    if (!_park.isCompleted) _park.complete();
    await caller.close();
    await transport.close();
    await responder.close();
    await server.close(force: true);
  });
  return caller;
}

Future<String> _call(RpcCallerEndpoint caller) async {
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'park',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: RpcDataTransferMode.codec,
    );
    return 'ok';
  } on RpcStatusException catch (e) {
    return 'status=${e.statusCode}';
  }
}

/// Fires [n] calls at once and returns their outcomes.
Future<List<String>> _burst(RpcCallerEndpoint caller, int n) async {
  final calls = [for (var i = 0; i < n; i++) _call(caller)];
  await Future<void>.delayed(const Duration(milliseconds: 400));
  if (!_park.isCompleted) _park.complete();
  return Future.wait(calls).timeout(const Duration(seconds: 10));
}

void main() {
  setUp(() => _park = Completer<void>());

  // WITNESS. Without the ceiling all 12 are admitted.
  test('a burst past the ceiling is refused, RESOURCE_EXHAUSTED', () async {
    final caller = await _caller(4);
    final outcomes = await _burst(caller, 12);

    expect(
      outcomes.where((o) => o == 'ok').length,
      4,
      reason: 'the ceiling is 4, and the siblings admit exactly 4',
    );
    expect(
      outcomes
          .where((o) => o == 'status=${RpcStatus.resourceExhausted}')
          .length,
      8,
      reason:
          'RESOURCE_EXHAUSTED, matching core and http2 — a transient limit the '
          'caller can back off from, not a mistake it made',
    );
  });

  // CONTROL. The refusal must be the CEILING, not the burst, the parked handler
  // or the server: the same 12 calls against a high ceiling all succeed.
  test(
    'CONTROL: the same burst under a high ceiling is fully admitted',
    () async {
      final caller = await _caller(64);

      expect(await _burst(caller, 12), everyElement('ok'));
    },
  );

  // GUARD against the ratchet, which is the failure a concurrency test cannot
  // see: a ceiling charged and never released passes the witness above and then
  // refuses ordinary traffic for the life of the process.
  test(
    'GUARD: the slot comes back — 12 sequential calls at a ceiling of 4',
    () async {
      final caller = await _caller(4);
      _park.complete();

      for (var i = 0; i < 12; i++) {
        expect(await _call(caller), 'ok', reason: 'call ${i + 1}');
      }
    },
  );
}
