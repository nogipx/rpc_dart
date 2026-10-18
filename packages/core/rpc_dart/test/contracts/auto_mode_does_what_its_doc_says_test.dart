// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcDataTransferMode.auto, as its doc states it: on a transport that can pass
// objects, every call shape does -- codecs or not, so the message limit does
// not apply -- while `codec` serializes and enforces it.

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
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'LenStream',
      handler: (r, {RpcContext? context}) async* {
        yield '${r.value.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class _Caller extends RpcCallerContract {
  _Caller(RpcCallerEndpoint endpoint, RpcDataTransferMode mode)
    : super('Svc', endpoint, dataTransferMode: mode);
}

_Caller _rig(RpcDataTransferMode mode) {
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
  return _Caller(caller, mode);
}

final _request = ('x' * (_limit + 1024)).rpc;

Future<String> _unary(RpcDataTransferMode mode) async {
  try {
    final r = await _rig(mode).callUnary<RpcString, RpcString>(
      methodName: 'Len',
      request: _request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return 'ok ${r.value}';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

Future<String> _serverStream(RpcDataTransferMode mode) async {
  try {
    final r = await _rig(mode)
        .callServerStream<RpcString, RpcString>(
          methodName: 'LenStream',
          request: _request,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .single;
    return 'ok ${r.value}';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

void main() {
  test('auto passes an over-limit unary request by reference', () async {
    expect(await _unary(RpcDataTransferMode.auto), 'ok ${_limit + 1024}');
  });

  test('codec serializes it and enforces the limit', () async {
    expect(
      await _unary(RpcDataTransferMode.codec),
      'status ${RpcStatus.resourceExhausted}',
    );
  });

  test('auto passes an over-limit server-stream request too', () async {
    expect(
      await _serverStream(RpcDataTransferMode.auto),
      'ok ${_limit + 1024}',
    );
  });

  test('codec serializes the server-stream request', () async {
    expect(
      await _serverStream(RpcDataTransferMode.codec),
      'status ${RpcStatus.resourceExhausted}',
    );
  });
}
