// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Reconnect coverage for RpcWebSocketCallerTransport.
//
// The caller transport keeps a STABLE [incomingMessages] broadcast stream
// across reconnects: subscribers attached before the drop must keep receiving
// messages after reconnect() re-establishes the underlying socket. The
// rpc_dart_log client redesign depends on exactly this guarantee.
//
// To simulate a real socket drop in-process we drive the reconnect factory
// against a mutable target URL: stop the first ephemeral dart:io server, bind
// a fresh one, and point the factory at it before calling reconnect().
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================================
// A minimal raw-echo WS server: every grpc data frame received on a stream is
// echoed straight back on the SAME streamId. This keeps the reconnect tests
// focused on transport-level survival without dragging in the full endpoint.
// ============================================================================

// A self-contained raw echo server that does NOT use RpcWebSocketServer: it
// wires a responder transport per socket and mirrors data frames. This is the
// simplest way to prove the caller transport's incomingMessages survives a
// reconnect end-to-end.
class _RawEchoServer {
  _RawEchoServer(this._httpServer);

  final HttpServer _httpServer;
  final _transports = <RpcWebSocketResponderTransport>[];
  final _subs = <StreamSubscription<RpcTransportMessage>>[];

  Uri get url =>
      Uri.parse('ws://${_httpServer.address.host}:${_httpServer.port}');

  static Future<_RawEchoServer> start() async {
    final httpServer = await HttpServer.bind('127.0.0.1', 0);
    final server = _RawEchoServer(httpServer);
    httpServer.transform(WebSocketTransformer()).listen((ws) {
      server._accept(IOWebSocketChannel(ws));
    });
    return server;
  }

  void _accept(WebSocketChannel channel) {
    final transport = RpcWebSocketResponderTransport(channel);
    _transports.add(transport);
    final sub = transport.incomingMessages.listen((msg) async {
      final payload = msg.payload;
      if (payload != null) {
        // Echo the data frame back on the same stream id.
        await transport.sendMessage(
          msg.streamId,
          payload,
          endStream: msg.isEndOfStream,
        );
      }
    });
    _subs.add(sub);
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    for (final t in _transports) {
      await t.close();
    }
    _transports.clear();
    await _httpServer.close(force: true);
  }
}

void main() {
  group('RpcWebSocketCallerTransport reconnect', () {
    test(
      'reconnect re-establishes the connection and reports healthy',
      () async {
        final server = await _RawEchoServer.start();
        addTearDown(server.stop);

        final transport = await RpcWebSocketCallerTransport.connect(server.url);
        addTearDown(transport.close);

        // Sanity: an echo round-trips before any drop.
        final firstEcho = _waitForEcho(transport);
        final sid1 = transport.createStream();
        await transport.sendMessage(
          sid1,
          RpcMessageFrame.encode(Uint8List.fromList([1, 2, 3])),
          endStream: true,
        );
        expect(
          (await firstEcho.timeout(const Duration(seconds: 5))).streamId,
          equals(sid1),
        );

        final status = await transport.reconnect().timeout(
          const Duration(seconds: 5),
        );
        expect(
          status.isHealthy,
          isTrue,
          reason: 'reconnect to a live server must report healthy',
        );
        expect(transport.isClosed, isFalse);
      },
    );

    test('stable incomingMessages stream survives reconnect for pre-existing '
        'subscribers', () async {
      final server = await _RawEchoServer.start();
      addTearDown(server.stop);

      final transport = await RpcWebSocketCallerTransport.connect(server.url);
      addTearDown(transport.close);

      // Subscriber attached BEFORE the reconnect. It must keep delivering
      // after reconnect() swaps the underlying socket.
      final received = <int>[];
      final sub = transport.incomingMessages.listen((m) {
        if (m.payload != null) received.add(m.streamId);
      });
      addTearDown(sub.cancel);

      // Reconnect (same transport object, same stream, fresh socket).
      final status = await transport.reconnect().timeout(
        const Duration(seconds: 5),
      );
      expect(status.isHealthy, isTrue);

      // A request issued AFTER reconnect reaches the server and the echo comes
      // back on the very same, pre-existing subscriber.
      final sid = transport.createStream();
      await transport.sendMessage(
        sid,
        RpcMessageFrame.encode(Uint8List.fromList([9, 8, 7])),
        endStream: true,
      );

      await _pumpUntil(
        () => received.contains(sid),
        timeout: const Duration(seconds: 5),
        reason: 'echo after reconnect must reach the original subscriber',
      );

      expect(received, contains(sid));
    });

    test(
      'reconnect to a FRESHLY-bound server after the first one drops',
      () async {
        // First server: connect, prove echo, then tear it down entirely.
        var server = await _RawEchoServer.start();
        var targetUrl = server.url;

        Future<WebSocketChannel> openChannel() async {
          final ch = WebSocketChannel.connect(targetUrl);
          await ch.ready;
          return ch;
        }

        final transport = RpcWebSocketCallerTransport(
          await openChannel(),
          reconnectFactory: openChannel,
        );
        addTearDown(transport.close);

        // Pre-existing subscriber that must survive the server swap.
        final received = <int>[];
        final sub = transport.incomingMessages.listen((m) {
          if (m.payload != null) received.add(m.streamId);
        });
        addTearDown(sub.cancel);

        // Echo works against server #1.
        final firstEcho = _waitForEcho(transport);
        final sid1 = transport.createStream();
        await transport.sendMessage(
          sid1,
          RpcMessageFrame.encode(Uint8List.fromList([1])),
          endStream: true,
        );
        await firstEcho.timeout(const Duration(seconds: 5));

        // Drop server #1 entirely, then stand up server #2 on a new port.
        await server.stop();
        server = await _RawEchoServer.start();
        targetUrl = server.url;
        addTearDown(server.stop);

        // Reconnect: factory now points at server #2.
        final status = await transport.reconnect().timeout(
          const Duration(seconds: 5),
        );
        expect(
          status.isHealthy,
          isTrue,
          reason: 'reconnect to a freshly-bound server must succeed',
        );

        // A request after reconnect reaches server #2 and the echo returns on
        // the original (stable) subscriber.
        final sid2 = transport.createStream();
        await transport.sendMessage(
          sid2,
          RpcMessageFrame.encode(Uint8List.fromList([2])),
          endStream: true,
        );

        await _pumpUntil(
          () => received.contains(sid2),
          timeout: const Duration(seconds: 5),
          reason: 'echo from server #2 must reach the original subscriber',
        );

        expect(
          received,
          contains(sid2),
          reason: 'stable stream survived a full server swap',
        );
      },
    );

    test(
      'full RPC call succeeds after reconnect (endpoint-level recovery)',
      () async {
        // Here we use RpcWebSocketServer + endpoints to prove a real unary call
        // works after a reconnect against a freshly-bound server.
        var harness = await _ContractHarness.start();
        var targetUrl = harness.url;

        Future<WebSocketChannel> openChannel() async {
          final ch = WebSocketChannel.connect(targetUrl);
          await ch.ready;
          return ch;
        }

        final transport = RpcWebSocketCallerTransport(
          await openChannel(),
          reconnectFactory: openChannel,
        );
        final caller = RpcCallerEndpoint(transport: transport);
        addTearDown(() async {
          await caller.close();
        });

        // Works before drop.
        final before = await caller
            .unaryRequest<EchoRequest, EchoResponse>(
              serviceName: serviceName,
              methodName: 'Unary',
              request: const EchoRequest('before', count: 1),
              requestCodec: _reqCodec,
              responseCodec: _resCodec,
            )
            .timeout(const Duration(seconds: 5));
        expect(before.text, equals('reply:before'));

        // Drop server, bind a fresh one, point the factory at it.
        await harness.stop();
        harness = await _ContractHarness.start();
        targetUrl = harness.url;
        addTearDown(harness.stop);

        final status = await transport.reconnect().timeout(
          const Duration(seconds: 5),
        );
        expect(status.isHealthy, isTrue);

        // A request after reconnect reaches the new server.
        final after = await caller
            .unaryRequest<EchoRequest, EchoResponse>(
              serviceName: serviceName,
              methodName: 'Unary',
              request: const EchoRequest('after', count: 2),
              requestCodec: _reqCodec,
              responseCodec: _resCodec,
            )
            .timeout(const Duration(seconds: 5));
        expect(after.text, equals('reply:after'));
        expect(after.index, equals(2));
      },
    );

    test(
      'reconnect without a factory reports degraded (not configured)',
      () async {
        final server = await _RawEchoServer.start();
        addTearDown(server.stop);

        // Constructed WITHOUT a reconnect factory.
        final ch = WebSocketChannel.connect(server.url);
        await ch.ready;
        final transport = RpcWebSocketCallerTransport(ch);
        addTearDown(transport.close);

        final status = await transport.reconnect().timeout(
          const Duration(seconds: 5),
        );
        expect(status.isHealthy, isFalse);
        expect(status.details['supported'], isFalse);
      },
    );

    test('server-initiated graceful drop does NOT permanently close a '
        'reconnect-capable transport (regression)', () async {
      // Regression for the auto-close-on-drop bug: when the peer closes the
      // socket gracefully (FIN), the underlying stream completes with onDone.
      // A transport WITH a reconnect factory must stay un-closed so that a
      // later reconnect() can recover. Without the fix, the onDone cascade
      // flipped isClosed to true and reconnect() returned "Transport closed".
      var server = await _RawEchoServer.start();
      var targetUrl = server.url;

      Future<WebSocketChannel> openChannel() async {
        final ch = WebSocketChannel.connect(targetUrl);
        await ch.ready;
        return ch;
      }

      final transport = RpcWebSocketCallerTransport(
        await openChannel(),
        reconnectFactory: openChannel,
      );
      addTearDown(transport.close);

      // Round-trip once so the connection is fully established.
      final firstEcho = _waitForEcho(transport);
      final sid = transport.createStream();
      await transport.sendMessage(
        sid,
        RpcMessageFrame.encode(Uint8List.fromList([1])),
        endStream: true,
      );
      await firstEcho.timeout(const Duration(seconds: 5));

      // Graceful server-side close (responder transports close -> client sees
      // a clean onDone, not an abrupt error).
      await server.stop();

      // Give the onDone cascade time to propagate.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        transport.isClosed,
        isFalse,
        reason: 'reconnect-capable transport must survive a graceful drop',
      );

      // And it can actually recover.
      server = await _RawEchoServer.start();
      targetUrl = server.url;
      addTearDown(server.stop);

      final status = await transport.reconnect().timeout(
        const Duration(seconds: 5),
      );
      expect(
        status.isHealthy,
        isTrue,
        reason: 'reconnect after a graceful drop must succeed',
      );
    });

    test('reconnect after close reports closed', () async {
      final server = await _RawEchoServer.start();
      addTearDown(server.stop);

      final transport = await RpcWebSocketCallerTransport.connect(server.url);
      await transport.close();

      final status = await transport.reconnect().timeout(
        const Duration(seconds: 5),
      );
      expect(status.isHealthy, isFalse);
      expect(transport.isClosed, isTrue);
    });
  });
}

// ============================================================================
// Helpers
// ============================================================================

/// Waits for the next echoed data frame on [transport.incomingMessages].
Future<RpcTransportMessage> _waitForEcho(IRpcTransport transport) {
  return transport.incomingMessages
      .firstWhere((m) => m.payload != null)
      .timeout(const Duration(seconds: 5));
}

/// Polls [check] until true or [timeout] elapses, failing with [reason].
Future<void> _pumpUntil(
  bool Function() check, {
  required Duration timeout,
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// ============================================================================
// Contract models / harness reused for the endpoint-level reconnect test.
// ============================================================================

class EchoRequest implements IRpcSerializable {
  final String text;
  final int count;

  const EchoRequest(this.text, {this.count = 1});

  @override
  Map<String, dynamic> toJson() => {'text': text, 'count': count};

  static EchoRequest fromJson(Map<String, dynamic> json) =>
      EchoRequest(json['text'] as String, count: json['count'] as int);
}

class EchoResponse implements IRpcSerializable {
  final String text;
  final int index;

  const EchoResponse(this.text, this.index);

  @override
  Map<String, dynamic> toJson() => {'text': text, 'index': index};

  static EchoResponse fromJson(Map<String, dynamic> json) =>
      EchoResponse(json['text'] as String, json['index'] as int);
}

const _reqCodec = RpcCodec<EchoRequest>(EchoRequest.fromJson);
const _resCodec = RpcCodec<EchoResponse>(EchoResponse.fromJson);

const serviceName = 'ws.Reconnect';

final class _ReconnectResponder extends RpcResponderContract {
  _ReconnectResponder()
    : super(serviceName, dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    addUnaryMethod<EchoRequest, EchoResponse>(
      methodName: 'Unary',
      requestCodec: _reqCodec,
      responseCodec: _resCodec,
      handler: (req, {context}) async =>
          EchoResponse('reply:${req.text}', req.count),
    );
  }
}

class _ContractHarness {
  _ContractHarness(this._httpServer, this._connCtl, this._rpcServer);

  final HttpServer _httpServer;
  final StreamController<WebSocketChannel> _connCtl;
  final RpcWebSocketServer _rpcServer;

  Uri get url =>
      Uri.parse('ws://${_httpServer.address.host}:${_httpServer.port}');

  static Future<_ContractHarness> start() async {
    final connCtl = StreamController<WebSocketChannel>();
    final httpServer = await HttpServer.bind('127.0.0.1', 0);
    httpServer.transform(WebSocketTransformer()).listen((ws) {
      if (!connCtl.isClosed) connCtl.add(IOWebSocketChannel(ws));
    });

    final rpcServer = RpcWebSocketServer.createWithContracts(
      connections: connCtl.stream,
      contracts: [_ReconnectResponder()..setup()],
    );
    await rpcServer.start();

    return _ContractHarness(httpServer, connCtl, rpcServer);
  }

  Future<void> stop() async {
    await _rpcServer.stop();
    await _connCtl.close();
    await _httpServer.close(force: true);
  }
}
