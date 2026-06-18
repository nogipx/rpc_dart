// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web-safe smoke test: exercises the WebSocket caller/responder transports and
// the underlying frame multiplexer over an in-memory WebSocketChannel pair.
//
// No dart:io anywhere -- this file must compile and run on dart2js (node /
// chrome) as well as the VM, proving the client transport is web-correct.
@TestOn('vm || browser || node')
library;

import 'dart:async';

import 'package:async/async.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('channel frame round-trips with 32-bit header (JS-safe)', () {
    // Large streamId near the 32-bit boundary to catch >32-bit shift bugs.
    const streamId = 0x7FFFFFFF;
    final payload = Uint8List.fromList(
      List<int>.generate(300, (i) => i & 0xFF),
    );

    final encoded = RpcChannelFrame.encodeData(
      streamId: streamId,
      payload: payload,
      endOfStream: true,
    );
    final (frames, consumed) = RpcChannelFrame.decodeAll(encoded);

    expect(consumed, encoded.length);
    expect(frames, hasLength(1));
    expect(frames.single.streamId, streamId);
    expect(frames.single.endOfStream, isTrue);
    expect(frames.single.payload, payload);
  });

  test(
    'caller -> responder round-trip over in-memory WebSocket pair',
    () async {
      final (clientWs, serverWs) = _wsPair();

      final caller = RpcWebSocketCallerTransport(clientWs);
      final responder = RpcWebSocketResponderTransport(serverWs);

      final received = <RpcTransportMessage>[];
      final sub = responder.incomingMessages.listen(received.add);

      final streamId = caller.createStream();
      await caller.sendMetadata(
        streamId,
        RpcMetadata([const RpcHeader('x-test', 'web')]),
      );
      final grpcFrame = RpcMessageFrame.encode(
        Uint8List.fromList([1, 2, 3, 4]),
      );
      await caller.sendMessage(streamId, grpcFrame, endStream: true);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, hasLength(2));
      expect(received.first.metadata?.headers.first.value, 'web');
      expect(received[1].payload, grpcFrame);
      expect(received[1].isEndOfStream, isTrue);

      await sub.cancel();
      await caller.close();
      await responder.close();
    },
  );

  test(
    'responder -> caller round-trip over in-memory WebSocket pair',
    () async {
      final (clientWs, serverWs) = _wsPair();

      final caller = RpcWebSocketCallerTransport(clientWs);
      final responder = RpcWebSocketResponderTransport(serverWs);

      final incoming = <RpcTransportMessage>[];
      final sub = caller.incomingMessages.listen(incoming.add);

      final streamId = responder.createStream();
      final grpcFrame = RpcMessageFrame.encode(
        Uint8List.fromList([5, 6, 7, 8, 9]),
      );
      await responder.sendMessage(streamId, grpcFrame, endStream: true);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(incoming, hasLength(1));
      expect(incoming.single.payload, grpcFrame);
      expect(incoming.single.streamId, streamId);

      await sub.cancel();
      await caller.close();
      await responder.close();
    },
  );

  test('caller close cancels subscription without deadlock', () async {
    final (clientWs, serverWs) = _wsPair();
    final caller = RpcWebSocketCallerTransport(clientWs);
    final responder = RpcWebSocketResponderTransport(serverWs);

    // A late listener attaching after close must not hang.
    await caller.close();
    expect(caller.isClosed, isTrue);
    await responder.close();
  });
}

/// Builds a pair of in-memory [WebSocketChannel]s wired back-to-back.
///
/// No dart:io: pure [StreamChannelController] plumbing, so it runs on dart2js.
(WebSocketChannel, WebSocketChannel) _wsPair() {
  final clientToServer = StreamController<Object?>();
  final serverToClient = StreamController<Object?>();

  final client = _MemoryWebSocketChannel(
    incoming: serverToClient.stream,
    outgoing: clientToServer.sink,
  );
  final server = _MemoryWebSocketChannel(
    incoming: clientToServer.stream,
    outgoing: serverToClient.sink,
  );
  return (client, server);
}

class _MemoryWebSocketChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _MemoryWebSocketChannel({
    required Stream<Object?> incoming,
    required StreamSink<Object?> outgoing,
  }) : stream = incoming,
       sink = _MemoryWebSocketSink(outgoing);

  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _MemoryWebSocketSink extends DelegatingStreamSink<Object?>
    implements WebSocketSink {
  _MemoryWebSocketSink(super.sink);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => super.close();
}
