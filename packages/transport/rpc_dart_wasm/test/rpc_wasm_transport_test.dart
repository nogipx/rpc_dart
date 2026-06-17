// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';
import 'package:test/test.dart';

import 'support/fake_wasm_bridge.dart';

void main() {
  group('RpcWasmTransport', () {
    test('creates client/server transports with correct stream id parity', () {
      final pair = FakeWasmBridge.pair();
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
      final pair = FakeWasmBridge.pair();
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
      final pair = FakeWasmBridge.pair();
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
      final pair = FakeWasmBridge.pair();
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

    test('createStream yields unique increasing ids', () {
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final ids = List.generate(4, (_) => client.createStream());
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.every((id) => id.isOdd), isTrue);
      client.close();
    });

    test('getMessagesForStream filters by stream id', () async {
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
      );

      final s1 = client.createStream();
      final s2 = client.createStream();
      final got1 = <RpcTransportMessage>[];
      final got2 = <RpcTransportMessage>[];
      final sub1 = server.getMessagesForStream(s1).listen(got1.add);
      final sub2 = server.getMessagesForStream(s2).listen(got2.add);

      await client.sendMessage(s1, RpcMessageFrame.encode(Uint8List(1)));
      await client.sendMessage(s2, RpcMessageFrame.encode(Uint8List(2)));
      await client.sendMessage(s1, RpcMessageFrame.encode(Uint8List(3)));
      await Future<void>.delayed(Duration.zero);

      expect(got1.every((m) => m.streamId == s1), isTrue);
      expect(got2.every((m) => m.streamId == s2), isTrue);
      expect(got1.length, 2);
      expect(got2.length, 1);

      await sub1.cancel();
      await sub2.cancel();
      await client.close();
      await server.close();
    });

    test('send after close does not deliver to peer', () async {
      final pair = FakeWasmBridge.pair();
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
      await client.close();
      expect(client.isClosed, isTrue);

      // Must not throw and must not be delivered.
      await client.sendMessage(streamId, RpcMessageFrame.encode(Uint8List(1)));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      await sub.cancel();
      await server.close();
    });

    test('closing transport closes the underlying bridge', () async {
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      expect(pair.client.isClosed, isFalse);
      await client.close();
      expect(pair.client.isClosed, isTrue);
      await pair.server.close();
    });
  });

  group('bridge byte framing', () {
    test('each transport send maps to one bridge frame', () async {
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );

      final streamId = client.createStream();
      await client.sendMetadata(
        streamId,
        RpcMetadata.forClientRequest('Svc', 'M'),
      );
      await client.sendMessage(
        streamId,
        RpcMessageFrame.encode(Uint8List.fromList([9, 8, 7])),
        endStream: true,
      );

      // Metadata frame + message frame -> two byte frames on the wire.
      expect(pair.client.sent, hasLength(2));
      expect(pair.client.sent.every((f) => f.isNotEmpty), isTrue);

      await client.close();
      await pair.server.close();
    });

    test('frames round-trip byte-identical through the bridge', () async {
      final pair = FakeWasmBridge.pair();
      final client = RpcWasmTransport.fromBridge(
        bridge: pair.client,
        isClient: true,
      );
      final server = RpcWasmTransport.fromBridge(
        bridge: pair.server,
        isClient: false,
      );

      final payload = RpcMessageFrame.encode(
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
      );
      final got = Completer<RpcTransportMessage>();
      final sub = server.incomingMessages.listen((m) {
        if (m.payload != null) got.complete(m);
      });

      final streamId = client.createStream();
      await client.sendMessage(streamId, payload);

      final message = await got.future.timeout(const Duration(seconds: 1));
      expect(message.payload, payload);

      await sub.cancel();
      await client.close();
      await server.close();
    });
  });
}
