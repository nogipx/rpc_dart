// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary request is the call's headers and then one frame that carries the
// request and half-closes. An empty end-of-stream frame after the request is
// one more frame on every unary call, on every transport.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

/// What the server receives for one unary call, frame by frame.
Future<List<String>> _requestFrames(
  (RpcChannelTransport, RpcChannelTransport) transports, {
  required bool codecs,
}) async {
  final (clientT, serverT) = transports;
  final frames = <String>[];
  final sub = serverT.incomingMessages.listen((m) {
    final kind = m.isMetadataOnly ? 'headers' : 'request';
    frames.add(m.isEndOfStream ? '$kind+end' : kind);
  });
  final responder = RpcResponderEndpoint(transport: serverT)
    ..registerServiceContract(_Echo())
    ..start();
  final caller = RpcCallerEndpoint(transport: clientT);
  try {
    final reply = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'echo',
      request: 'hi'.rpc,
      requestCodec: codecs ? _codec : null,
      responseCodec: codecs ? _codec : null,
    );
    expect(reply.value, 'hi');
  } finally {
    await sub.cancel();
    await caller.close();
    await responder.close();
  }
  return frames;
}

void main() {
  test('a serialized unary request half-closes with the request', () async {
    expect(await _requestFrames(RpcChannelTransport.pair(), codecs: true), [
      'headers',
      'request+end',
    ]);
  });

  test('a zero-copy unary request half-closes with the request', () async {
    expect(
      await _requestFrames(RpcChannelTransport.memoryPair(), codecs: false),
      ['headers', 'request+end'],
    );
  });
}
