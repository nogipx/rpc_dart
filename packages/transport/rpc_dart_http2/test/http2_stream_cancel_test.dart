// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Cancelling a stream mid-flight used to corrupt the HTTP/2 connection.
//
// The cancellation notice rides on a metadata frame with endStream: true, but
// by cancellation time the caller has already half-closed -- a server-stream
// does so right after its single request. HTTP/2 rejects a second
// end-of-stream with "Open state expected (was: StreamState.HalfClosedLocal)",
// thrown ASYNCHRONOUSLY out of its stream handler, so it never surfaced at the
// call site and no test caught it; the call appeared to succeed while the
// connection was left poisoned.
//
// The notice now goes out as RST_STREAM via IRpcStreamReset.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final class _StreamingContract extends RpcResponderContract {
  _StreamingContract() : super('Cancel');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'many',
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < 50; i++) {
          yield '$i'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

void main() {
  test('cancelling a server stream does not poison the connection', () async {
    final zoneErrors = <Object>[];

    await runZonedGuarded(() async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (endpoint) =>
            endpoint.registerServiceContract(_StreamingContract()),
      );
      await server.start();

      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        logger: LogScope.noop,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      // take(1) abandons the stream after the first response.
      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Cancel',
            methodName: 'many',
            request: 'go'.rpc,
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
          )
          .take(1)
          .toList();
      expect(got, hasLength(1));

      // Give the cancellation path time to reach the wire.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await caller.close();
      await server.stop();
    }, (error, stack) => zoneErrors.add(error));

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      zoneErrors,
      isEmpty,
      reason:
          'cancellation must not raise async transport errors, got: '
          '${zoneErrors.map((e) => e.toString()).toSet().join(" | ")}',
    );
  });
}
