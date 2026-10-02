// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A side that carries exactly one message -- the response of unary and
// client-stream, the request of unary and server-stream -- that receives a
// second one fails the call INTERNAL, as gRPC does. Accepting it silently left
// the two callers disagreeing on which one stood.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _frame(String s) => RpcMessageFrame.encode(_codec.serialize(s.rpc));

Matcher get _internal => isA<RpcStatusException>().having(
  (e) => e.statusCode,
  'statusCode',
  RpcStatus.internal,
);

/// A server that answers every call with [responses], then OK.
RpcCallerEndpoint _answering(List<String> responses) {
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
      for (final r in responses) {
        await server.sendMessage(m.streamId, _frame(r));
      }
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

final class _Slow extends RpcResponderContract {
  _Slow() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return r;
      },
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'down',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        yield r;
      },
    );
  }
}

/// Sends [chunks] as the request side of [path] and returns the grpc-status.
Future<String?> _sendRequests(String path, List<Uint8List> chunks) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Slow())
    ..start();
  addTearDown(responder.close);
  final id = client.createStream();
  final status = client
      .getMessagesForStream(id)
      .map((m) => m.metadata?.getHeaderValue('grpc-status'))
      .firstWhere((s) => s != null, orElse: () => null)
      .timeout(const Duration(seconds: 3), onTimeout: () => null);
  final parts = path.split('/');
  await client.sendMetadata(
    id,
    RpcMetadata.forClientRequest(parts[1], parts[2]),
  );
  for (var i = 0; i < chunks.length; i++) {
    await client.sendMessage(id, chunks[i], endStream: i == chunks.length - 1);
  }
  return status;
}

void main() {
  group('the caller', () {
    test('unary, two responses', () async {
      await expectLater(
        _answering(['one', 'two']).unaryRequest<RpcString, RpcString>(
          serviceName: 'S',
          methodName: 'M',
          request: 'q'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
        throwsA(_internal),
      );
    });

    test('client-stream, two responses', () async {
      await expectLater(
        _answering(['one', 'two']).clientStream<RpcString, RpcString>(
          serviceName: 'S',
          methodName: 'M',
          requestCodec: _codec,
          responseCodec: _codec,
        )(Stream.value('q'.rpc)),
        throwsA(_internal),
      );
    });

    test('CONTROL unary, one response', () async {
      final answer = await _answering(['one'])
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 'M',
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          );
      expect(answer.value, 'one');
    });
  });

  group('the responder', () {
    test('unary, two requests in one chunk', () async {
      expect(
        await _sendRequests('/Svc/echo', [
          Uint8List.fromList([..._frame('a'), ..._frame('b')]),
        ]),
        '${RpcStatus.internal}',
      );
    });

    test('unary, two requests in two frames', () async {
      expect(
        await _sendRequests('/Svc/echo', [_frame('a'), _frame('b')]),
        '${RpcStatus.internal}',
      );
    });

    test('server-stream, two requests', () async {
      expect(
        await _sendRequests('/Svc/down', [_frame('a'), _frame('b')]),
        '${RpcStatus.internal}',
      );
    });

    test('CONTROL unary, one request', () async {
      expect(await _sendRequests('/Svc/echo', [_frame('a')]), '0');
    });
  });
}
