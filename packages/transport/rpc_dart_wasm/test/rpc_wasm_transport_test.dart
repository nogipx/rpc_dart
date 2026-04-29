// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';
import 'package:test/test.dart';

void main() {
  group('RpcWasmTransport', () {
    test('creates client/server transports with correct stream id parity', () {
      final pair = _FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
      );

      expect(client.createStream().isOdd, isTrue);
      expect(server.createStream().isEven, isTrue);

      client.close();
      server.close();
    });

    test('delivers metadata and data over bridge', () async {
      final pair = _FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
      );
      final received = <RpcTransportMessage>[];
      final sub = server.incomingMessages.listen(received.add);

      final streamId = client.createStream();
      await client.sendMetadata(
        streamId,
        RpcMetadata([
          const RpcHeader('x-test', 'wasm'),
        ], methodPath: '/Test/Echo'),
      );
      final payload = RpcMessageFrame.encode(Uint8List.fromList([1, 2, 3]));
      await client.sendMessage(streamId, payload, endStream: true);

      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(2));
      expect(received[0].streamId, streamId);
      expect(received[0].metadata?.methodPath, '/Test/Echo');
      expect(received[0].metadata?.headers.single.value, 'wasm');
      expect(received[1].payload, payload);
      expect(received[1].isEndOfStream, isTrue);

      await sub.cancel();
      await client.close();
      await server.close();
    });

    test('finishSending emits end-of-stream marker', () async {
      final pair = _FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
      );
      final done = Completer<RpcTransportMessage>();
      final sub = server.incomingMessages.listen((message) {
        if (message.isEndOfStream) done.complete(message);
      });

      final streamId = client.createStream();
      await client.finishSending(streamId);

      final message = await done.future.timeout(const Duration(seconds: 1));
      expect(message.streamId, streamId);
      expect(message.isEndOfStream, isTrue);

      await sub.cancel();
      await client.close();
      await server.close();
    });

    test('reports no zero-copy support', () async {
      final pair = _FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );

      expect(client.supportsZeroCopy, isFalse);
      expect(
        client.sendDirectObject(client.createStream(), Object()),
        throwsUnsupportedError,
      );

      await client.close();
      await pair.server.close();
    });
  });
}

final class _FakeWasmBridge implements RpcWasmBridge {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
  late final _FakeWasmBridge _peer;
  bool _closed = false;

  static ({_FakeWasmBridge client, _FakeWasmBridge server}) pair() {
    final client = _FakeWasmBridge();
    final server = _FakeWasmBridge();
    client._peer = server;
    server._peer = client;
    return (client: client, server: server);
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed || _peer._incoming.isClosed) return;
    _peer._incoming.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}
