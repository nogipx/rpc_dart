// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcDataTransferMode.auto, as its doc states it: on a transport that can pass
// objects, a unary call does -- codecs or not, so the message limit does not
// apply -- while `codec` serializes and enforces it.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _limit = 64 * 1024;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Len',
      handler: (r, {RpcContext? context}) async => '${r.value.length}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<String> _call(RpcDataTransferMode mode) async {
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
  try {
    final r = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Len',
      request: ('x' * (_limit + 1024)).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: mode,
    );
    return 'ok ${r.value}';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

void main() {
  test('auto passes an over-limit unary request by reference', () async {
    expect(await _call(RpcDataTransferMode.auto), 'ok ${_limit + 1024}');
  });

  test('codec serializes it and enforces the limit', () async {
    expect(
      await _call(RpcDataTransferMode.codec),
      'status ${RpcStatus.resourceExhausted}',
    );
  });
}
