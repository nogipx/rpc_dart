// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A zero-copy method (no codecs) registered on a transport that cannot carry
// objects is refused UNIMPLEMENTED. A call whose frames arrive back to back
// got that trailer twice: a frame landing while the first was being sent found
// no responder and was refused again. Two terminal statuses on one stream is a
// protocol violation for any peer that keeps stream state.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _ZeroCopy extends RpcResponderContract {
  _ZeroCopy() : super('Z');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'cs',
      handler: (requests, {RpcContext? context}) async => 'x'.rpc,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (requests, {RpcContext? context}) => requests,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ss',
      handler: (r, {RpcContext? context}) => Stream.value(r),
    );
  }
}

void main() {
  test('each refused zero-copy call gets one trailer', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_ZeroCopy())
      ..start();
    addTearDown(() async {
      await responder.close();
      await client.close();
      await server.close();
    });

    // Counted on BOTH routes: once the first trailer ends the stream's own
    // route, a second one arrives only on the transport-wide stream.
    final statuses = <String, List<String>>{};
    final methodOf = <int, String>{};
    void record(RpcTransportMessage m) {
      final s = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      final method = methodOf[m.streamId];
      if (s != null && method != null) (statuses[method] ??= []).add(s);
    }

    client.incomingMessages.listen(record, onError: (Object _) {});
    Uint8List frame(String s) =>
        RpcMessageFrame.encode(_codec.serialize(s.rpc));
    for (final method in ['cs', 'bidi', 'ss']) {
      final id = client.createStream();
      methodOf[id] = method;
      client.getMessagesForStream(id).listen(record, onError: (Object _) {});
      await client.sendMetadata(id, RpcMetadata.forClientRequest('Z', method));
      // Back to back, not awaited, as a pipelining caller sends them.
      unawaited(client.sendMessage(id, frame('a')));
      unawaited(client.sendMessage(id, frame('b')));
      unawaited(client.finishSending(id));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(statuses, {
      'cs': ['${RpcStatus.unimplemented}'],
      'bidi': ['${RpcStatus.unimplemented}'],
      'ss': ['${RpcStatus.unimplemented}'],
    });
    expect(responder.activeResponderCount, 0);
  });
}
