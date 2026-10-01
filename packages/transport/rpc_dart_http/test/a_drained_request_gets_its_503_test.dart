// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `stop()` promised a 503 to anything still pending and destroyed the connections
// it would travel on first:
//
//   1. httpServer.close()                  stop accepting
//   2. _drainRequests(transport, budget)    wait for what is running
//   3. httpServer.close(force: true)        CUT the connections
//   4. endpoint.close() -> transport.close()
//        "Complete any pending responses with 503."
//
// Measured with a 200 ms budget against a handler taking 30 s:
//
//   ClientException: Connection closed before full header was received
//
// The 503s are made at step 4 and step 3 has already killed the sockets. Both
// branches of `stop()` had it -- the no-drain one closed the endpoint after its own
// force close in the same way.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowContract extends RpcResponderContract {
  _SlowContract(this.handlerTakes) : super('Svc');

  final Duration handlerTakes;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(handlerTakes);
        return r;
      },
    );
  }
}

/// A port nobody holds: `RpcHttpServer` exposes no bound port.
Future<int> _freePort() async {
  final probe = await ServerSocket.bind('127.0.0.1', 0);
  final port = probe.port;
  await probe.close();
  return port;
}

/// Starts a server whose handler takes [handlerTakes], puts one request in flight,
/// stops with [drainTimeout], and returns what the client was told.
Future<String> _requestInFlightThenStop({
  required Duration? drainTimeout,
  required Duration handlerTakes,
}) async {
  final port = await _freePort();
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: port,
    onEndpointCreated: (e) =>
        e.registerServiceContract(_SlowContract(handlerTakes)),
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(() => server.stop().catchError((Object _) {}));

  // A raw POST, so what is asserted is the HTTP outcome rather than whatever the
  // rpc_dart caller makes of it.
  final client = http.Client();
  addTearDown(client.close);
  var outcome = 'STILL WAITING';
  final inFlight = client
      .post(
        Uri.parse('http://127.0.0.1:$port/Svc/slow'),
        headers: const {'content-type': 'application/grpc+proto'},
        body: RpcMessageFrame.encode(_codec.serialize('x'.rpc)),
      )
      .then((r) => outcome = 'HTTP ${r.statusCode}')
      .catchError((Object e) => outcome = e.runtimeType.toString());

  // Long enough that the request is established and the handler has started.
  await Future<void>.delayed(const Duration(milliseconds: 400));

  await server.stop(drainTimeout: drainTimeout);
  await inFlight.timeout(
    const Duration(seconds: 10),
    onTimeout: () => outcome = 'NEVER ANSWERED',
  );
  return outcome;
}

void main() {
  // WITNESS. Before: ClientException, the connection closed under the response.
  test(
    'a request still running when the drain budget expires gets 503',
    () async {
      final outcome = await _requestInFlightThenStop(
        drainTimeout: const Duration(milliseconds: 200),
        handlerTakes: const Duration(seconds: 30),
      );

      expect(
        outcome,
        'HTTP 503',
        reason:
            'the transport promises a 503 to everything still pending, and a '
            'reset instead tells the peer nothing it can act on',
      );
    },
  );

  // WITNESS, the other branch. `stop()` with no budget is the documented immediate
  // cut, and it closed the endpoint after its own force close in the same way.
  test('a request running at a stop() with no drain budget gets 503', () async {
    final outcome = await _requestInFlightThenStop(
      drainTimeout: null,
      handlerTakes: const Duration(seconds: 30),
    );

    expect(outcome, 'HTTP 503');
  });

  // CONTROL. A handler that finishes INSIDE the budget still gets its real answer,
  // so the two 503s above are the drain cutting a straggler and not the server
  // having stopped answering.
  test(
    'CONTROL: a handler that finishes inside the budget answers 200',
    () async {
      final outcome = await _requestInFlightThenStop(
        drainTimeout: const Duration(seconds: 3),
        handlerTakes: const Duration(milliseconds: 100),
      );

      expect(outcome, 'HTTP 200');
    },
  );
}
