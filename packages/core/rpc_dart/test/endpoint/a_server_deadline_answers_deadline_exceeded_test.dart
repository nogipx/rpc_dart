// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the server's copy of the caller's deadline fires, it answers
// DEADLINE_EXCEEDED, once, as gRPC does. A cooperative handler used to unwind
// with its token's CANCELLED, and a server stream often sent nothing: a peer
// relying on the server's answer read the wrong status or waited forever.
//
// The rpc_dart caller races its own timer against that trailer; it must raise
// RpcDeadlineExceededException whichever lands first.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Cooperative extends RpcResponderContract {
  _Cooperative() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        for (var i = 0; i < 100; i++) {
          context?.cancellationToken?.throwIfCancelled();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return r;
      },
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 's',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 100; i++) {
          context?.cancellationToken?.throwIfCancelled();
          yield r;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  }
}

/// Every grpc-status a raw client reads for [method] with a 200 ms timeout.
Future<List<String>> _statuses(String method) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Cooperative())
    ..start();
  final id = client.createStream();
  final seen = <String>[];
  final sub = client.getMessagesForStream(id).listen((m) {
    final s = m.metadata?.getHeaderValue('grpc-status');
    if (s != null) seen.add(s);
  }, onError: (Object _) {});
  addTearDown(() async {
    await sub.cancel();
    await responder.close();
    await client.close();
    await server.close();
  });
  await client.sendMetadata(
    id,
    RpcMetadata([
      ...RpcMetadata.forClientRequest('Svc', method).headers,
      const RpcHeader('grpc-timeout', '200m'),
    ], methodPath: '/Svc/$method'),
  );
  await client.sendMessage(
    id,
    RpcMessageFrame.encode(_codec.serialize('q'.rpc)),
    endStream: true,
  );
  // Past the deadline and the handler's own unwinding, in 20 ms steps.
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return seen;
}

void main() {
  group('the server answers its deadline once, DEADLINE_EXCEEDED', () {
    test('unary', () async {
      expect(await _statuses('u'), ['${RpcStatus.deadlineExceeded}']);
    });

    test('server-stream', () async {
      expect(await _statuses('s'), ['${RpcStatus.deadlineExceeded}']);
    });
  });

  test('a caller reads a DEADLINE_EXCEEDED trailer as its own '
      'deadline', () async {
    // The trailer arrives long before the caller's own timer would fire, so
    // the type comes from the mapping and not from the race.
    final (client, server) = RpcChannelTransport.memoryPair();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(caller.close);
    server.incomingMessages.listen((m) {
      if (m.metadata?.methodPath == null) return;
      unawaited(
        server.sendMetadata(
          m.streamId,
          RpcMetadata.forTrailer(RpcStatus.deadlineExceeded),
          endStream: true,
        ),
      );
    });
    await expectLater(
      caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        request: 'q'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.withTimeout(const Duration(seconds: 30)),
      ),
      throwsA(isA<RpcDeadlineExceededException>()),
    );
  });
}
