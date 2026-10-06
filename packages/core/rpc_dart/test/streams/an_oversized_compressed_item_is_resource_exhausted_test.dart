// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A message over maxMessageLengthBytes is RESOURCE_EXHAUSTED on every
// transport. In-process transports compress whatever shrinks, so there the
// limit fires inside the decompressor -- and a decompressor's limit throw must
// still read as a size, not as a malformed payload.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _limit = 64 * 1024;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Big',
      handler: (r, {RpcContext? context}) async* {
        yield 'small'.rpc;
        yield ('b' * int.parse(r.value)).rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('an oversized stream item over memory is RESOURCE_EXHAUSTED', () async {
    final (client, server) = RpcChannelTransport.memoryPair(
      policy: const RpcSecurityPolicy(maxMessageLengthBytes: _limit),
    );
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Svc())
      ..start();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await responder.close();
    });

    final got = <String>[];
    Object? error;
    await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Big',
          request: '${_limit + 1024}'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .handleError((Object e) => error = e)
        .forEach((r) => got.add(r.value))
        .timeout(const Duration(seconds: 5));

    expect(got, ['small']);
    expect(
      error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.resourceExhausted,
      ),
    );
  });
}
