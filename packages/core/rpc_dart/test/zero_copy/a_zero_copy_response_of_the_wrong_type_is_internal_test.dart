// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A zero-copy response whose object is not the type the caller expects -- a
// caller and responder that disagree about a contract -- reached the caller as
// a raw TypeError. A serialized response that cannot be decoded has been
// INTERNAL since round 631; zero-copy is the same failure and now says so the
// same way, on both the unary path and the streaming one.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _AnswersAnInt extends RpcResponderContract {
  _AnswersAnInt() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcInt>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => RpcInt(1),
    );
    addServerStreamMethod<RpcString, RpcInt>(
      methodName: 's',
      handler: (r, {RpcContext? context}) => Stream.value(RpcInt(1)),
    );
  }
}

void main() {
  late RpcCallerEndpoint caller;

  setUp(() {
    final (client, server) = RpcChannelTransport.memoryPair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_AnswersAnInt())
      ..start();
    caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });
  });

  final isInternal = isA<RpcStatusException>().having(
    (e) => e.statusCode,
    'status',
    RpcStatus.internal,
  );

  test('unary', () async {
    await expectLater(
      caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'u',
        request: 'x'.rpc,
      ),
      throwsA(isInternal),
    );
  });

  test('server stream', () async {
    await expectLater(
      caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'S',
            methodName: 's',
            request: 'x'.rpc,
          )
          .toList(),
      throwsA(isInternal),
    );
  });
}
