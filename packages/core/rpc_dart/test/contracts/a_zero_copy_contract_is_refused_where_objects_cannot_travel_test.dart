// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

/// A method registered without codecs travels as objects. On a transport that
/// carries only bytes it can never be served, so registering it fails at once
/// rather than every call answering UNIMPLEMENTED.
void main() {
  RpcResponderEndpoint responderOn({required bool objects}) {
    final RpcChannelTransport server;
    if (objects) {
      (_, server) = RpcChannelTransport.memoryPair();
    } else {
      final (_, channel) = RpcFrameMultiplexedChannel.pair();
      server = RpcChannelTransport(channel: channel, isClient: false);
    }
    final responder = RpcResponderEndpoint(transport: server);
    addTearDown(responder.close);
    return responder;
  }

  test('a byte-only transport refuses a zero-copy contract', () {
    final responder = responderOn(objects: false);

    expect(
      () => responder.registerServiceContract(_NoCodecs()),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.message,
          'message',
          contains('cannot carry objects'),
        ),
      ),
    );
    expect(responder.registeredContracts, isEmpty);
  });

  test('a byte-only transport takes the same contract with codecs', () {
    final responder = responderOn(objects: false);

    responder.registerServiceContract(_WithCodecs());

    expect(responder.registeredContracts.keys, ['S']);
  });

  test('a transport that carries objects takes the zero-copy contract', () {
    final responder = responderOn(objects: true);

    responder.registerServiceContract(_NoCodecs());

    expect(responder.registeredContracts.keys, ['S']);
  });
}

final class _NoCodecs extends RpcResponderContract {
  _NoCodecs() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {context}) async => request,
    );
  }
}

final class _WithCodecs extends RpcResponderContract {
  _WithCodecs() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {context}) async => request,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
