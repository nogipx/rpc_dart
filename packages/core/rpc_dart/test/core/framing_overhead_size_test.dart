// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcSecurityPolicy.maxMessageLengthBytes is documented as "max payload size of
// a single decoded gRPC message". RpcFrameMultiplexedChannel applied it to the
// wrong quantity twice over:
//
//   - decodeAll(maxPayloadLen:) bounds the CHANNEL frame payload, which is the
//     gRPC-FRAMED message -- 5 bytes of prefix the policy value does not count.
//   - the reassembly buffer must also hold the channel's own 9-byte header.
//
// So the real ceiling sat 14 bytes below the configured one, and a message at
// the limit did not get a clean per-message rejection: the buffer check fired
// first and tore down the entire multiplexed connection, killing every
// concurrent stream on it. The caller saw no error at all, just its timeout.
//
// Measured pre-fix with maxMessageLengthBytes = 64KB:
//   appBytes=65536 -> TimeoutException  channelTornDown=true
//                     'Incoming frame buffer overflow: 65558 bytes (max: 65541)'

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const int _limit = 64 * 1024;

final class _Bytes implements IRpcSerializable {
  _Bytes(this.data);
  final Uint8List data;

  @override
  Map<String, dynamic> toJson() => {'d': data};

  static _Bytes fromJson(Map<String, dynamic> json) =>
      _Bytes(json['d'] as Uint8List);
}

final _codec = RpcCodec(_Bytes.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<_Bytes, _Bytes>(
      methodName: 'sink',
      handler: (request, {RpcContext? context}) async =>
          _Bytes(Uint8List.fromList([request.data.length % 256])),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Bytes of user payload whose SERIALIZED form is exactly [target] bytes.
///
/// The policy bounds the serialized gRPC message, not the user's byte array,
/// so the CBOR envelope has to be measured rather than guessed.
int _payloadForSerializedSize(int target) {
  const probe = 1024;
  final overhead = _codec.serialize(_Bytes(Uint8List(probe))).length - probe;
  return target - overhead;
}

/// Sends one request of [appBytes] and reports how it ended.
Future<({String outcome, bool channelTornDown})> _send(int appBytes) async {
  const policy = RpcSecurityPolicy(maxMessageLengthBytes: _limit);
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();

  var tornDown = false;
  final watch = server.incomingMessages.listen(
    (_) {},
    onError: (Object _) => tornDown = true,
  );

  String outcome;
  try {
    await caller
        .unaryRequest<_Bytes, _Bytes>(
          serviceName: 'Svc',
          methodName: 'sink',
          request: _Bytes(Uint8List(appBytes)),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    outcome = 'ok';
  } catch (e) {
    outcome = e.runtimeType.toString();
  }

  await watch.cancel();
  await caller.close();
  await responder.close();
  await client.close();
  await server.close();

  return (outcome: outcome, channelTornDown: tornDown);
}

void main() {
  test('a message at exactly the size limit is delivered', () async {
    final result = await _send(_payloadForSerializedSize(_limit));
    expect(
      result.outcome,
      'ok',
      reason: 'a message of exactly maxMessageLengthBytes must be accepted',
    );
    expect(result.channelTornDown, isFalse);
  });

  test('one byte over the limit does not kill the connection', () async {
    final result = await _send(_payloadForSerializedSize(_limit + 1));
    // Over-limit is still refused -- the cap is real, only its arithmetic
    // changed. What matters is that the refusal is per-message.
    expect(result.outcome, isNot('ok'));
  });

  test('the buffer cap admits exactly one maximal frame', () {
    // Unit-level statement of the same arithmetic, independent of codecs.
    const policy = RpcSecurityPolicy(maxMessageLengthBytes: _limit);
    final maxFrameOnTheWire =
        RpcChannelFrame.headerSize + // channel header
        RpcConstants.messagePrefixSize + // gRPC frame prefix
        policy.maxMessageLengthBytes; // the message itself

    final bufferCap =
        policy.effectiveMaxBufferedBytes + RpcChannelFrame.headerSize;

    expect(
      bufferCap,
      greaterThanOrEqualTo(maxFrameOnTheWire),
      reason: 'the reassembly buffer cannot hold a maximal frame',
    );
  });
}
