// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response the caller's codec cannot decode is a call that failed INTERNAL,
// as an undecodable request is on the server: it reaches the caller as an
// RpcStatusException, which is what `on RpcException` and the status-keyed
// interceptors read. The codec's own exception type is not part of the API.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A server that answers every call with one well-framed message no codec can
/// read, then OK.
RpcCallerEndpoint _againstGarbage() {
  final (client, server) = RpcChannelTransport.memoryPair();
  final caller = RpcCallerEndpoint(transport: client);
  final seen = <int>{};
  server.incomingMessages.listen((m) {
    if (m.metadata?.methodPath == null || !seen.add(m.streamId)) return;
    unawaited(() async {
      await server.sendMetadata(
        m.streamId,
        RpcMetadata.forServerInitialResponse(),
      );
      await server.sendMessage(
        m.streamId,
        RpcMessageFrame.encode(Uint8List.fromList([0xff, 0x00, 0x13])),
      );
      await server.sendMetadata(
        m.streamId,
        RpcMetadata.forTrailer(0),
        endStream: true,
      );
    }());
  });
  addTearDown(caller.close);
  return caller;
}

Matcher get _internal => isA<RpcStatusException>().having(
  (e) => e.statusCode,
  'statusCode',
  RpcStatus.internal,
);

void main() {
  test('unary', () async {
    await expectLater(
      _againstGarbage().unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        request: 'q'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      throwsA(_internal),
    );
  });

  test('client-stream', () async {
    await expectLater(
      _againstGarbage().clientStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      )(Stream.fromIterable(['q'.rpc])),
      throwsA(_internal),
    );
  });

  test('server-stream', () async {
    await expectLater(
      _againstGarbage()
          .serverStream<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 'M',
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList(),
      throwsA(_internal),
    );
  });

  test('bidi', () async {
    await expectLater(
      _againstGarbage()
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 'M',
            requests: Stream.fromIterable(['q'.rpc]),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList(),
      throwsA(_internal),
    );
  });
}
