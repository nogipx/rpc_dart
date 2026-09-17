// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidirectional SUBSCRIPTION over a real socket: the caller opens the
// channel, listens, and sends nothing. Round 373 fixed that in core and proved
// it on an in-process pair; a real transport builds its own metadata frame, so
// the claim had to be confirmed on the wire.
//
// Measured with the core dispatch ablated and restored:
//
//   silent (ablated)   0 HANG      control   3 DONE
//   silent (fixed)     3 DONE      control   3 DONE
//
// So the defect was genuinely present here, not merely untested.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'push',
      handler: (requests, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield 'p$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Never produces and never closes: a subscription.
Stream<RpcString> _never() => StreamController<RpcString>().stream;

Future<List<String>> _drive(
  RpcCallerEndpoint caller,
  Stream<RpcString> requests,
) async {
  final got = <String>[];
  await for (final r in caller.bidirectionalStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'push',
    requests: requests,
    requestCodec: _codec,
    responseCodec: _codec,
  )) {
    got.add(r.value);
  }
  return got;
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;
  late RpcWebSocketCallerTransport client;
  late RpcCallerEndpoint caller;

  setUp(() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    await client.close();
    await server.stop();
    await http.close(force: true);
  });

  test('WITNESS: a silent caller receives over a real socket', () async {
    final got = await _drive(caller, _never()).timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail(
        'a bidi subscription never reached the server over a real socket',
      ),
    );
    expect(got, ['p0', 'p1', 'p2']);
  });

  test('GUARD: a request stream that closes at once still works', () async {
    final got = await _drive(caller, const Stream<RpcString>.empty());
    expect(got, ['p0', 'p1', 'p2']);
  });
}
