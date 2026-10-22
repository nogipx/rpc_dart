// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CBOR decoder refuses a map whose keys share one hashCode past a cap
// (CborKeyCollisionException). A peer's message refused that way must reach
// the other side as RESOURCE_EXHAUSTED, like the item budget, and never reach
// the handler -- in both directions. The codec here throws the refusal itself,
// so the test checks the mapping, not the cap.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/codec/special_cbor.dart'
    show CborKeyCollisionException;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Encodes like [_codec] and refuses every decode as the cap would.
final class _RefusingCodec implements IRpcCodec<RpcString> {
  @override
  Uint8List serialize(RpcString message) => _codec.serialize(message);

  @override
  RpcString deserialize(Uint8List bytes) => throw CborKeyCollisionException(16);
}

final class _Svc extends RpcResponderContract {
  _Svc(this.requestCodec) : super('Svc');
  final IRpcCodec<RpcString> requestCodec;
  int handled = 0;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async {
        handled++;
        return r;
      },
      requestCodec: requestCodec,
      responseCodec: _codec,
    );
  }
}

Future<(RpcCallerEndpoint, _Svc)> _pair(
  IRpcCodec<RpcString> serverCodec,
) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final svc = _Svc(serverCodec);
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(svc)
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller, svc);
}

Future<Object?> _errorOf(Future<RpcString> call) async {
  try {
    await call.timeout(const Duration(seconds: 5));
    return null;
  } catch (e) {
    return e;
  }
}

final _resourceExhausted = isA<RpcStatusException>().having(
  (e) => e.statusCode,
  'statusCode',
  RpcStatus.resourceExhausted,
);

void main() {
  test(
    'a request the decoder refuses is RESOURCE_EXHAUSTED, unhandled',
    () async {
      final (caller, svc) = await _pair(_RefusingCodec());
      final error = await _errorOf(
        caller.unary<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        ),
      );
      expect(error, _resourceExhausted);
      expect(svc.handled, 0, reason: 'the handler saw a refused request');
    },
  );

  test('a response the decoder refuses is RESOURCE_EXHAUSTED', () async {
    final (caller, _) = await _pair(_codec);
    final error = await _errorOf(
      caller.unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _RefusingCodec(),
      ),
    );
    expect(error, _resourceExhausted);
  });

  test('GUARD the same call with a decoding codec succeeds', () async {
    final (caller, svc) = await _pair(_codec);
    final reply = await caller.unary<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(reply.value, 'x');
    expect(svc.handled, 1);
  });
}
