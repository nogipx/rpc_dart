// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A close code is the only thing a WebSocket peer can say about why it went
// away, and one code on this platform is not the peer speaking at all: dart:io
// answers ANY socket error on an open connection by closing with
// `WebSocketStatus.protocolError` (1002). So a TCP reset — the commonest
// transient network failure there is — reaches a caller as a peer protocol
// judgement, which is deterministic and must not be retried.
//
// Driven through a real reset rather than a synthesized close code, because the
// claim is about what the PLATFORM does and a hand-sent 1002 would only measure
// the mapping table. The reset is produced by a byte relay that stops draining
// the client and then destroys the socket: closing a socket with unread bytes
// still in its receive queue is what makes the kernel send RST instead of FIN.
//
// The same rule is broken a second way five lines further down. The web half of
// this transport does not report a socket failure as a close at all — it reports
// an error on the stream — and that error was forwarded verbatim, so a caller
// received a `WebSocketChannelException` instead of a status. Nothing above can
// act on that: a retry interceptor keys off the gRPC code and an application
// catching `RpcStatusException` never sees it.
//
// The controls are the two endings that must not move: a peer that really sends
// 1011 is still a server fault, and a peer that vanishes without a close frame
// is still the ordinary connection-lost path. And the advisory report for a
// non-binary frame must still arrive as itself, or a discarded text frame would
// start reading as a dead connection.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A WebSocket endpoint that answers NOTHING, so a call stays in flight until
/// the connection ends the way the test chose.
Future<HttpServer> _silentServer(void Function(WebSocket) onOpen) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.listen((req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    ws.listen((_) {}, onError: (Object _) {}, onDone: () {});
    onOpen(ws);
  });
  return http;
}

/// A byte relay in front of a target port, so the client's socket can be RESET
/// rather than closed.
class _Relay {
  _Relay(this._server, this.port);

  final ServerSocket _server;
  final int port;
  Socket? _fromClient;
  StreamSubscription<void>? _clientSub;
  bool _resetting = false;

  static Future<_Relay> start(int target) async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final relay = _Relay(server, server.port);
    server.listen((client) async {
      relay._fromClient = client;
      final upstream = await Socket.connect('127.0.0.1', target);
      relay._clientSub = client.listen(
        upstream.add,
        onError: (Object _) {},
        onDone: () => upstream.destroy(),
      );
      upstream.listen(
        (d) {
          if (!relay._resetting) client.add(d);
        },
        onError: (Object _) {},
        onDone: () {},
      );
    });
    return relay;
  }

  /// Stops draining the client, so whatever it sends next stays in the kernel
  /// receive queue — which is the precondition for RST.
  void stopReading() => _clientSub?.pause();

  void reset() {
    _resetting = true;
    _fromClient?.destroy();
  }

  Future<void> stop() => _server.close();
}

typedef _Ending = ({int? closeCode, int? status, String? message});

Future<_Ending> _callThrough({
  required bool viaRelay,
  required Future<void> Function(_Relay? relay, WebSocket peer) end,
}) async {
  final opened = Completer<WebSocket>();
  final server = await _silentServer((ws) {
    if (!opened.isCompleted) opened.complete(ws);
  });
  final relay = viaRelay ? await _Relay.start(server.port) : null;

  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://127.0.0.1:${relay?.port ?? server.port}'),
  );
  final caller = RpcCallerEndpoint(
    transport: RpcWebSocketCallerTransport(channel),
  );
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await relay?.stop();
    await server.close(force: true);
  });

  await channel.ready;
  final peer = await opened.future.timeout(const Duration(seconds: 10));
  await Future<void>.delayed(const Duration(milliseconds: 100));

  // Before the call, so the request frames are what sits unread.
  relay?.stopReading();

  final call = caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'echo',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await end(relay, peer);

  try {
    await call.timeout(const Duration(seconds: 10));
    return (closeCode: channel.closeCode, status: null, message: null);
  } on RpcStatusException catch (e) {
    return (
      closeCode: channel.closeCode,
      status: e.statusCode,
      message: e.message,
    );
  }
}

void main() {
  test(
    'WITNESS: a reset connection fails the call as UNAVAILABLE',
    () async {
      final end = await _callThrough(
        viaRelay: true,
        end: (relay, _) async => relay!.reset(),
      );

      expect(
        end.closeCode,
        1002,
        reason:
            'the rig did not produce a reset, so the rest of this test measures '
            'nothing — check that closing with unread bytes still sends RST',
      );
      expect(
        end.status,
        RpcStatus.unavailable,
        reason:
            'INTERNAL is not retried, so the commonest transient network '
            'failure is permanent for the caller',
      );
      expect(
        end.message,
        isNot(contains('by peer')),
        reason:
            'the peer said nothing — dart:io chose 1002 locally, and the message '
            'sends a reader after something that never happened',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: a code the peer really sent must keep its meaning. Mapping 1002 to
  // UNAVAILABLE is only correct if it does not drag the rest of the table with
  // it.
  test(
    'CONTROL: a peer that really closes 1011 is still INTERNAL',
    () async {
      final end = await _callThrough(
        viaRelay: false,
        end: (_, peer) => peer.close(1011, 'server fault'),
      );

      expect(end.closeCode, 1011);
      expect(end.status, RpcStatus.internal);
      expect(end.message, contains('by peer'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: and the silent ending stays on the path reconnect() re-attaches on,
  // which is where three earlier tests broke when this file's rule was widened.
  test(
    'CONTROL: a peer that vanishes is still the connection-lost path',
    () async {
      final end = await _callThrough(
        viaRelay: false,
        end: (_, peer) => peer.close(),
      );

      expect(end.status, RpcStatus.unavailable);
      expect(
        end.message,
        isNot(contains('1002')),
        reason: 'a clean close must not be reported as a connection failure',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // The web half. `HtmlWebSocketChannel` reports a socket failure as an ERROR on
  // the stream rather than a close, so this asks the same question through a
  // channel that errors — which can be driven on the VM.
  test(
    'WITNESS: a raw channel error reaches the caller as a status',
    () async {
      final rig = _ErroringRig();
      final failure = await rig.callThenRaise(
        WebSocketChannelException('connection failed'),
      );

      expect(
        failure,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
        reason:
            'the caller received the channel package\'s own exception type, '
            'which carries no gRPC status for anything above to act on',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: an ADVISORY report must still arrive as itself. It says one frame
  // was discarded, not that the connection is gone, and wrapping it as a
  // transport failure would fail every call in flight over a working socket.
  test(
    'CONTROL: an advisory frame report is not turned into a failure',
    () async {
      final rig = _ErroringRig();
      final failure = await rig.callThenRaise(
        RpcWebSocketNonBinaryFrame('String'),
      );

      expect(failure, isNot(isA<RpcStatusException>()));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// A caller over a channel whose inbound stream can be made to raise.
class _ErroringRig {
  final _incoming = StreamController<Object?>();
  final _outgoing = StreamController<Object?>();

  Future<Object?> callThenRaise(Object error) async {
    _outgoing.stream.listen((_) {});
    final caller = RpcCallerEndpoint(
      transport: RpcWebSocketCallerTransport(
        _FakeChannel(_incoming.stream, _outgoing.sink),
      ),
    );
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
    });

    final call = caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _incoming.addError(error);

    try {
      await call.timeout(const Duration(seconds: 10));
      return null;
    } catch (e) {
      return e;
    }
  }
}

class _FakeChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _FakeChannel(this.stream, StreamSink<Object?> out) : sink = _FakeSink(out);

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

class _FakeSink implements WebSocketSink {
  _FakeSink(this._out);

  final StreamSink<Object?> _out;
  bool _closed = false;

  @override
  void add(Object? data) {
    if (!_closed) _out.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) => _out.addStream(stream);

  @override
  Future<void> get done => _out.done;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (_closed) return;
    _closed = true;
    await _out.close();
  }
}
