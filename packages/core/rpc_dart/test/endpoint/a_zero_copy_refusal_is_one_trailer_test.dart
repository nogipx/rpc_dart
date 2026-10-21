// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A zero-copy method (no codecs) on a transport that cannot carry objects is
// refused UNIMPLEMENTED per call where registration could not refuse it: a
// transport that reconnects may carry objects once connected. A call whose
// frames arrive back to back must get that trailer once: a frame landing while
// the first is being sent finds no responder, and refusing it again puts two
// terminal statuses on one stream, a protocol violation for any peer that
// keeps stream state.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Reports no zero-copy support, and may reconnect, so registration admits a
/// zero-copy contract and each call is refused instead.
final class _MayReconnect extends RpcChannelTransport
    implements IRpcReconnectOutcome {
  _MayReconnect({required super.channel, required super.isClient});

  @override
  IRpcReconnectOutcome get reconnectOutcome => this;

  @override
  Future<RpcHealthStatus> awaitReconnect() => health();
}

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
    final (clientChannel, serverChannel) = RpcFrameMultiplexedChannel.pair();
    final client = RpcChannelTransport(channel: clientChannel, isClient: true);
    final server = _MayReconnect(channel: serverChannel, isClient: false);
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
      'cs': ['${RpcStatus.unimplemented.code}'],
      'bidi': ['${RpcStatus.unimplemented.code}'],
      'ss': ['${RpcStatus.unimplemented.code}'],
    });
    expect(responder.activeResponderCount, 0);
  });
}
