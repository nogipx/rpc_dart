// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Reconnect / no-loss integration test for LogCollectorOutput.
//
// Proves the end-to-end guarantee that reconnect (now delegated to
// RpcClientConnection) keeps the buffered, ordered record stream intact across
// a real drop + reconnect:
//   1. client connects to collector #1, handshakes, delivers records;
//   2. the connection DROPS (collector #1 server side closed) while the client
//      keeps emitting -> those records buffer, the client goes not-connected;
//   3. the client RECONNECTS to a FRESH collector #2 via the channelFactory,
//      re-handshakes and delivers ALL buffered records, IN ORDER, no loss,
//      no duplicates.
//
// Pure in-memory WebSocketChannel pair harness (no dart:io), mirroring
// client_web_smoke_test.dart, so it runs on vm and node.
@TestOn('vm || node || browser')
library;

import 'dart:async';

import 'package:async/async.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_dart_log/src/contract/log_responder.dart';
import 'package:rpc_dart_log/src/contract/messages.dart';

void main() {
  test('reconnects to a fresh collector and delivers all buffered records, '
      'in order, with no loss and no duplicates', () async {
    // Two independent collectors. The first dies mid-stream; the second
    // receives everything the client buffered while offline.
    final c1 = _Collector();
    final c2 = _Collector();

    var connectAttempt = 0;

    Future<WebSocketChannel> factory(Uri uri) async {
      connectAttempt++;
      // First (re)connect -> collector #1; every later attempt -> collector #2.
      final collector = connectAttempt == 1 ? c1 : c2;
      return collector.accept();
    }

    final out = LogCollectorOutput(
      uri: Uri.parse('ws://memory'),
      device: DeviceInfo(name: 'JSDevice', app: 'JSApp'),
      channelFactory: factory,
    );

    final controller = LogController(
      minLevel: RpcLogLevel.debug,
      outputs: [out],
    );
    final log = controller.scope('reconnect');

    // -- Phase 1: connect, handshake, deliver to collector #1 ----------------
    log.info('pre-1');
    log.info('pre-2');

    await _pumpUntil(
      () => out.isConnected,
      timeout: const Duration(seconds: 5),
    );
    expect(c1.handshake?.deviceName, startsWith('JSDevice/'));

    await _pumpUntil(
      () => c1.received.length >= 2,
      timeout: const Duration(seconds: 5),
    );
    expect(_messages(c1.received), ['pre-1', 'pre-2']);
    // All records acked -> client fully drained.
    await _pumpUntil(
      () => out.bufferedCount == 0 && out.inFlightCount == 0,
      timeout: const Duration(seconds: 5),
    );

    // -- Phase 2: DROP collector #1, keep emitting ---------------------------
    // Closing the server side closes the client's incoming stream, which
    // RpcClientConnection detects (onDone) and reacts to by reconnecting.
    await c1.dropServer();

    // The client must observe the drop and go not-connected.
    await _pumpUntil(
      () => !out.isConnected,
      timeout: const Duration(seconds: 5),
    );

    // Emit while offline. These MUST buffer and survive the reconnect.
    final offline = <String>[];
    for (var i = 0; i < 25; i++) {
      final m = 'offline-$i';
      offline.add(m);
      log.info(m);
    }
    // Records are buffered (not lost), nothing more reached collector #1.
    expect(out.bufferedCount + out.inFlightCount, greaterThan(0));
    expect(
      _messages(c1.received),
      ['pre-1', 'pre-2'],
      reason: 'no record may leak to the dead collector #1',
    );

    // -- Phase 3: RECONNECT to collector #2 ----------------------------------
    await _pumpUntil(
      () => out.isConnected,
      timeout: const Duration(seconds: 10),
    );
    // Re-handshake happened on the fresh collector.
    expect(c2.handshake, isNotNull, reason: 'client must re-handshake');
    expect(c2.handshake?.deviceName, startsWith('JSDevice/'));

    // ALL offline records delivered to collector #2.
    await _pumpUntil(
      () => c2.received.length >= offline.length,
      timeout: const Duration(seconds: 10),
    );
    await _pumpUntil(
      () => out.bufferedCount == 0 && out.inFlightCount == 0,
      timeout: const Duration(seconds: 5),
    );

    final got2 = _messages(c2.received);

    // No loss: every offline record arrived.
    expect(got2.toSet(), containsAll(offline));
    // No duplicates: collector #2 saw each exactly once.
    expect(
      got2.length,
      got2.toSet().length,
      reason: 'no record may be delivered twice',
    );
    // In order: offline records arrive in emission order.
    expect(
      got2,
      offline,
      reason: 'buffered records must arrive in emission order',
    );

    // Cross-boundary: already-acked pre-drop records were NOT re-sent.
    expect(got2, isNot(contains('pre-1')));
    expect(got2, isNot(contains('pre-2')));

    out.dispose();
    await c1.dispose();
    await c2.dispose();
  });
}

List<String> _messages(List<LogCollectorRecord> records) =>
    records.map((r) => r.payload['message'] as String).toList();

/// Spins the event loop until [cond] is true or [timeout] elapses.
Future<void> _pumpUntil(
  bool Function() cond, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A standalone in-memory log collector: stands up a real responder endpoint
/// on the server side of an in-memory WebSocket pair and records what it gets.
class _Collector {
  final received = <LogCollectorRecord>[];
  LogCollectorHandshake? handshake;

  StreamController<Object?>? _clientToServer;
  StreamController<Object?>? _serverToClient;
  WebSocketChannel? _serverChannel;

  /// Builds a fresh pair, wires the responder on the server side and returns
  /// the client channel for the LogCollectorOutput to connect over.
  WebSocketChannel accept() {
    final clientToServer = StreamController<Object?>();
    final serverToClient = StreamController<Object?>();
    _clientToServer = clientToServer;
    _serverToClient = serverToClient;

    final client = _MemoryWebSocketChannel(
      incoming: serverToClient.stream,
      outgoing: clientToServer.sink,
    );
    final server = _MemoryWebSocketChannel(
      incoming: clientToServer.stream,
      outgoing: serverToClient.sink,
    );
    _serverChannel = server;

    final transport = RpcWebSocketResponderTransport(server);
    final endpoint = RpcResponderEndpoint(transport: transport);
    endpoint.registerServiceContract(
      LogCollectorServiceResponder(
        onHandshake: (h) => handshake = h,
        onRecord: received.add,
      ),
    );
    endpoint.start();
    return client;
  }

  /// Closes the server side, dropping the connection and forcing the client's
  /// incoming stream to complete (onDone) -> RpcClientConnection reconnects.
  Future<void> dropServer() async {
    await _serverChannel?.sink.close();
    await _serverToClient?.close();
  }

  Future<void> dispose() async {
    await _serverChannel?.sink.close();
    await _serverToClient?.close();
    await _clientToServer?.close();
  }
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
