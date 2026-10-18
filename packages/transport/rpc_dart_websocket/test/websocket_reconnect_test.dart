// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Reconnect coverage for RpcWebSocketCallerTransport under RpcClientConnection.
//
// The connection's transport keeps a STABLE [incomingMessages] stream across
// reconnects: subscribers attached before the drop must keep receiving
// messages after the connection builds a new websocket transport. The
// rpc_dart_log client depends on exactly this guarantee.
//
// The drop is a real one: the first server is stopped, a fresh one is bound
// on a NEW port, and the factory reads the current URL. Nothing calls
// forceReconnect(); the connection notices the socket end on its own.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// A self-contained raw echo server that does NOT use RpcWebSocketServer: it
// wires a responder transport per socket and echoes every data frame back on
// the SAME stream id, which keeps the test on the message stream itself.
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

/// A connected [RpcClientConnection] whose factory dials [url] as it reads at
/// each attempt.
Future<RpcClientConnection> _connection(Uri Function() url) async {
  final connection = RpcClientConnection(
    transportFactory: () => RpcWebSocketCallerTransport.connect(url()),
    backoff: const FixedBackoff(Duration(milliseconds: 50)),
  );
  addTearDown(connection.dispose);
  final online = _nextOnline(connection);
  connection.connect();
  await online;
  return connection;
}

Future<void> _nextOnline(RpcClientConnection connection) => connection.state
    .firstWhere((s) => s is RpcClientOnline)
    .timeout(const Duration(seconds: 10));

void main() {
  test('a pre-existing subscriber survives a swap to a freshly-bound '
      'server', () async {
    var server = await _RawEchoServer.start();
    var targetUrl = server.url;
    final connection = await _connection(() => targetUrl);
    final transport = connection.transport;

    // Subscriber attached BEFORE the drop.
    final received = <int>[];
    final sub = transport.incomingMessages.listen((m) {
      if (m.payload != null) received.add(m.streamId);
    });
    addTearDown(sub.cancel);

    final sid1 = transport.createStream();
    await transport.sendMessage(
      sid1,
      RpcMessageFrame.encode(Uint8List.fromList([1])),
      endStream: true,
    );
    await _pumpUntil(
      () => received.contains(sid1),
      timeout: const Duration(seconds: 5),
      reason: 'echo from server #1',
    );

    // Drop server #1 entirely, then stand up server #2 on a new port. Until it
    // is up the factory dials a port nothing listens on, so no attempt can
    // land on server #1 while it is shutting down.
    targetUrl = Uri.parse('ws://127.0.0.1:1');
    final online = _nextOnline(connection);
    await server.stop();
    server = await _RawEchoServer.start();
    targetUrl = server.url;
    addTearDown(server.stop);
    await online;

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
  });

  test('a full RPC call succeeds after a swap to a freshly-bound '
      'server', () async {
    var harness = await _ContractHarness.start();
    var targetUrl = harness.url;
    final connection = await _connection(() => targetUrl);
    final caller = RpcCallerEndpoint(transport: connection.transport);
    addTearDown(caller.close);

    Future<EchoResponse> call(String text, int count) => caller
        .unaryRequest<EchoRequest, EchoResponse>(
          serviceName: serviceName,
          methodName: 'Unary',
          request: EchoRequest(text, count: count),
          requestCodec: _reqCodec,
          responseCodec: _resCodec,
        )
        .timeout(const Duration(seconds: 5));

    expect((await call('before', 1)).text, equals('reply:before'));

    // As above: nothing to dial until server #2 is up.
    targetUrl = Uri.parse('ws://127.0.0.1:1');
    final online = _nextOnline(connection);
    await harness.stop();
    harness = await _ContractHarness.start();
    targetUrl = harness.url;
    addTearDown(harness.stop);
    await online;

    final after = await call('after', 2);
    expect(after.text, equals('reply:after'));
    expect(after.index, equals(2));
  });
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
