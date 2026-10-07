// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A stream of small items to a consumer slower than the producer, on the
// default policy. The sender was paced by the byte window alone, which admits
// far more ten-byte messages than the receiver's depth bound of 1024, so the
// stream failed with RESOURCE_EXHAUSTED a little past item 1024. A socket read
// carries many frames, all parsed before the consumer runs, so a fast consumer
// tripped it too.
//
// Both directions: a server stream to a slow reader, and a client stream to a
// slow handler, which the responder pipeline meters on its own path.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _slow = Duration(microseconds: 500);

/// Below the default, so a burst of one socket read exceeds it and the counts
/// stay small; the mechanism does not depend on the value.
const _policy = RpcSecurityPolicy(maxBufferedMessagesPerStream: 1024);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'count',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        final n = int.parse(r.value);
        for (var i = 0; i < n; i++) {
          yield 'i$i'.rpc;
        }
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
          await Future<void>.delayed(_slow);
        }
        return '$n'.rpc;
      },
    );
  }
}

Future<RpcCallerEndpoint> _connect() async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    policy: _policy,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
    policy: _policy,
  );
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await server.stop();
    await http.close(force: true);
  });
  return caller;
}

Stream<RpcString> _count(RpcCallerEndpoint caller, int n) =>
    caller.serverStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'count',
      request: '$n'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test(
    'WITNESS 10000 small items reach a fast reader',
    () async {
      final caller = await _connect();

      final got = await _count(caller, 10000).length;

      expect(got, 10000);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS a slow reader gets every item',
    () async {
      final caller = await _connect();

      var got = 0;
      await for (final _ in _count(caller, 3000)) {
        got++;
        await Future<void>.delayed(_slow);
      }

      expect(got, 3000);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a slow handler gets every uploaded item',
    () async {
      final caller = await _connect();
      final call = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'collect',
        requestCodec: _codec,
        responseCodec: _codec,
      );

      final response = await call(
        Stream.fromIterable([for (var i = 0; i < 3000; i++) 'i$i'.rpc]),
      );

      expect(response.value, '3000');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
