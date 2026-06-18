// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web-safe client smoke test.
//
// Exercises the LogCollectorOutput CLIENT path (construction, buffering, flush,
// pipelined ack-driven drain) over an in-memory WebSocketChannel pair wired to
// a real LogCollectorServiceResponder. No dart:io anywhere -- it MUST compile
// and run on dart2js (node), proving the log client is web-correct. Mobile and
// Flutter-Web apps embed exactly this client.
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
  test('client library imports and constructs on JS without dart:io', () {
    // If this file compiles on -p node, the whole client import chain
    // (LogCollectorOutput -> contracts -> rpc_dart -> rpc_dart_websocket
    // non-server files) is web-safe.
    final out = LogCollectorOutput(
      uri: Uri.parse('ws://127.0.0.1:9'),
      device: DeviceInfo(name: 'JSDevice', app: 'JSApp'),
      channelFactory: (_) =>
          Completer<WebSocketChannel>().future, // never ready
    );
    expect(out.sessionId, isNotEmpty);
    expect(out.isConnected, isFalse);
    out.dispose();
  });

  test('buffers records while offline, never blocking write', () {
    final out = LogCollectorOutput(
      uri: Uri.parse('ws://127.0.0.1:9'),
      device: DeviceInfo(name: 'JSDevice', app: 'JSApp'),
      bufferSize: 5,
      // Channel that never becomes ready -> client stays offline.
      channelFactory: (_) => Completer<WebSocketChannel>().future,
    );

    final controller = LogController(
      minLevel: RpcLogLevel.debug,
      outputs: [out],
    );
    final log = controller.scope('web');

    for (var i = 0; i < 20; i++) {
      log.info('msg $i');
    }

    // Bounded buffer: capped at bufferSize, write never threw or hung.
    expect(out.isConnected, isFalse);
    expect(out.bufferedCount, lessThanOrEqualTo(5));
    expect(out.inFlightCount, 0);

    out.dispose();
  });

  test(
    'connects, handshakes and flushes buffered records to the collector',
    () async {
      final received = <LogCollectorRecord>[];
      LogCollectorHandshake? handshake;

      // In-memory WS pair: server side runs a real responder endpoint.
      WebSocketChannel? serverChannel;

      Future<WebSocketChannel> factory(Uri uri) async {
        final (client, server) = _wsPair();
        serverChannel = server;
        // Wire the server side: responder endpoint with the log contract.
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

      final out = LogCollectorOutput(
        uri: Uri.parse('ws://memory'),
        device: DeviceInfo(name: 'JSDevice', app: 'JSApp'),
        channelFactory: factory,
      );

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [out],
      );
      final log = controller.scope('web.service');

      // Emit before and after the connection settles.
      log.info('early one');
      log.info('early two');

      await _pumpUntil(
        () => out.isConnected,
        timeout: const Duration(seconds: 5),
      );
      expect(handshake?.deviceName, startsWith('JSDevice/'));

      log.info('late three');

      await _pumpUntil(
        () => received.length >= 3,
        timeout: const Duration(seconds: 5),
      );

      final messages = received
          .map((r) => r.payload['message'] as String?)
          .toList();
      expect(messages, containsAll(['early one', 'early two', 'late three']));
      // Order preserved.
      expect(
        messages.indexOf('early one'),
        lessThan(messages.indexOf('early two')),
      );
      expect(out.bufferedCount, 0);

      out.dispose();
      await serverChannel?.sink.close();
    },
  );
}

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

/// Builds a pair of in-memory [WebSocketChannel]s wired back-to-back.
/// Pure stream_channel plumbing -- no dart:io, runs on dart2js.
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
