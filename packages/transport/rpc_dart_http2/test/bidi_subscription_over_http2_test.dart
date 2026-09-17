// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidirectional SUBSCRIPTION over real HTTP/2: the caller opens the channel,
// listens, and sends nothing. This is the transport where it is least obvious —
// the shape maps onto HEADERS then DATA, and a caller with no message must
// still get its HEADERS on the wire for the peer to see a stream at all.
//
// Measured with the core dispatch ablated and restored:
//
//   silent (ablated)   0 HANG      control   3 DONE
//   silent (fixed)     3 DONE      control   3 DONE

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
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
  late RpcHttp2Server server;
  late RpcHttp2CallerTransport client;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    await client.close();
    await server.stop();
  });

  test('WITNESS: a silent caller receives over real HTTP/2', () async {
    final got = await _drive(caller, _never()).timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          fail('a bidi subscription never reached the server over HTTP/2'),
    );
    expect(got, ['p0', 'p1', 'p2']);
  });

  test('GUARD: a request stream that closes at once still works', () async {
    final got = await _drive(caller, const Stream<RpcString>.empty());
    expect(got, ['p0', 'p1', 'p2']);
  });
}
