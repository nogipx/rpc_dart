// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_handleConnection` runs in the accept loop's event handler, which is the ROOT
// ZONE: an unhandled async error there kills the isolate. The file guards that
// everywhere it closes a socket — except on its own failure path, where a bare
// `channel.sink.close()` answered a failed setup by taking the server down with it
// whenever the close itself rejected.
//
// And a close rejecting is not exotic: it is the state a failed setup tends to
// leave a socket in.
//
// The witness drives both failures at once — a channel whose stream throws on
// listen (so setup fails) and whose sink throws on close (so the cleanup fails) —
// and then asserts the server is STILL SERVING. An unhandled error would surface
// as a test-level failure rather than as this expectation, so the assertion also
// has to show the server survived in a usable state, not merely that nothing was
// reported.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  test(
    'WITNESS: a setup that fails, with a close that also fails, leaves the server up',
    () async {
      final conns = StreamController<WebSocketChannel>();
      final server = RpcWebSocketServer.createWithContracts(
        connections: conns.stream,
        contracts: [_Echo()..setup()],
      );
      addTearDown(() async {
        await server.dispose().catchError((Object _) {});
        await conns.close();
      });
      await server.start();

      // Setup throws (the stream cannot be listened to) AND the cleanup throws
      // (the sink refuses to close) — the exact pairing the failure path hits.
      conns.add(_Hostile());
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        server.isRunning,
        isTrue,
        reason: 'the failed connection took the server with it',
      );

      // And it must still SERVE. "Still running" is a flag; answering a call is
      // the thing that says the isolate and the accept loop both survived.
      final (clientWs, serverWs) = _pair();
      conns.add(serverWs);
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(clientWs),
      );
      addTearDown(() => caller.close().catchError((Object _) {}));

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'echo',
            request: 'after'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(reply.value, 'echo:after');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: the same server with no hostile connection must serve identically.
  // Without it, "served one call" says nothing about whether the failure mattered.
  test(
    'CONTROL: with no failed setup the server serves the same call',
    () async {
      final conns = StreamController<WebSocketChannel>();
      final server = RpcWebSocketServer.createWithContracts(
        connections: conns.stream,
        contracts: [_Echo()..setup()],
      );
      addTearDown(() async {
        await server.dispose().catchError((Object _) {});
        await conns.close();
      });
      await server.start();

      final (clientWs, serverWs) = _pair();
      conns.add(serverWs);
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(clientWs),
      );
      addTearDown(() => caller.close().catchError((Object _) {}));

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'echo',
            request: 'plain'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(reply.value, 'echo:plain');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}

/// Fails on the way in and again on the way out.
class _Hostile extends StreamChannelMixin<Object?> implements WebSocketChannel {
  @override
  Stream<Object?> get stream =>
      throw StateError('this channel cannot be listened to');

  @override
  final WebSocketSink sink = _ThrowingSink();

  @override
  Future<void> get ready async {}

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _ThrowingSink implements WebSocketSink {
  @override
  void add(Object? data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {}

  @override
  Future<void> get done async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      throw StateError('this sink cannot be closed');
}

(WebSocketChannel, WebSocketChannel) _pair() {
  final c2s = StreamController<Object?>();
  final s2c = StreamController<Object?>();
  return (
    _Wired(incoming: s2c.stream, outgoing: c2s.sink),
    _Wired(incoming: c2s.stream, outgoing: s2c.sink),
  );
}

class _Wired extends StreamChannelMixin<Object?> implements WebSocketChannel {
  _Wired({
    required Stream<Object?> incoming,
    required StreamSink<Object?> outgoing,
  }) : stream = incoming,
       sink = _WiredSink(outgoing);

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

class _WiredSink implements WebSocketSink {
  _WiredSink(this._out);

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
