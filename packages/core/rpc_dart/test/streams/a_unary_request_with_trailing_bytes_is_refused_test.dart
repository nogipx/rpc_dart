// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary request is one message. Two whole ones were refused (INTERNAL,
// "More than one request"), but one whole message followed by the start of a
// second, in the same chunk, ran the handler and answered OK with the extra
// bytes left in the parser.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');
  int calls = 0;
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        calls++;
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends a unary request whose single DATA chunk is [body], and returns the
/// grpc-status the responder sent and how often the handler ran.
Future<(String?, int)> _unary(List<int> body) async {
  final chan = RawPeerChannel();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: false,
  );
  final echo = _Echo();
  final responder = RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(echo)
    ..start();
  addTearDown(() async {
    await responder.close();
    await transport.close();
  });
  chan
    ..feed(
      RpcChannelFrame.encodeMetadata(
        streamId: 1,
        metadata: RpcMetadata.forClientRequest('Svc', 'echo'),
      ),
    )
    ..feed(
      RpcChannelFrame.encodeData(
        streamId: 1,
        payload: Uint8List.fromList(body),
        endOfStream: true,
      ),
    );
  String? status;
  for (var i = 0; i < 50 && status == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final data in chan.sent) {
      final frame = RpcChannelFrame.decode(data);
      final s = frame?.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (frame?.streamId == 1 && s != null) status = s;
    }
  }
  return (status, echo.calls);
}

void main() {
  final frame = RpcMessageFrame.encode(_codec.serialize('x'.rpc));

  test('WITNESS one message and the start of a second is refused', () async {
    final (status, calls) = await _unary([...frame, 7]);
    expect(status, '${RpcStatus.internal.code}');
    expect(calls, 0);
  });

  test('GUARD one whole message is answered OK', () async {
    final (status, calls) = await _unary(frame);
    expect(status, '${RpcStatus.ok.code}');
    expect(calls, 1);
  });
}
