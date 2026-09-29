// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every operation the reconnecting wrapper forwards takes a bare stream id and
// resolves it on whatever inner transport is current, so an id from the previous
// connection acts on the new one. The four send paths are guarded against that;
// the flow-credit pair was not, and a consumer still draining the old
// connection's buffers credits the new one — granting a window nothing consumed
// and crediting a connection pool nothing drew from.
//
// Witnessed at the WIRE, by counting frames the wrapper writes to the new
// socket: a returned credit above half the window is exactly one grant frame, so
// "did the stale call reach the new connection" is a frame count rather than an
// inference.
//
// The control is the same call for a LIVE id. A guard that dropped everything
// would pass the witness and switch flow control off, which stalls a stream at
// its window instead of over-granting it.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _window = 64 * 1024;

// The per-stream window only. With the connection pool off, a returned credit
// over half the window produces exactly one frame and nothing else does.
const _policy = RpcSecurityPolicy(
  flowControlWindowBytes: _window,
  flowControlConnectionWindowBytes: null,
);

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  test(
    'WITNESS: a credit returned for a stale id puts nothing on the new socket',
    () async {
      final one = _pair();
      final two = _pair();
      final client = RpcWebSocketCallerTransport(
        one.client,
        policy: _policy,
        reconnectFactory: () async => two.client,
      );
      final server1 = RpcWebSocketResponderTransport(
        one.server,
        policy: _policy,
      );
      addTearDown(() async {
        await client.close().catchError((Object _) {});
        await server1.close().catchError((Object _) {});
      });

      // A stream the PEER opened, which is what the responder pipeline defers
      // and credits. It is live on the first connection and on no other.
      final staleId = server1.createStream();
      await server1.sendMetadata(
        staleId,
        RpcMetadata.forClientRequest('Svc', 'm'),
      );
      await _settle();

      await client.reconnect();
      // A peer really is there on the new socket; it just has not reused the
      // number yet. Without one the counted sink has no reader and teardown
      // never finishes.
      final server2 = RpcWebSocketResponderTransport(
        two.server,
        policy: _policy,
      );
      addTearDown(() async {
        await server2.close().catchError((Object _) {});
      });
      await _settle();

      final before = two.frames;
      client.deferFlowCredit(staleId);
      client.returnFlowCredit(staleId, _window);
      await _settle();

      expect(
        two.frames - before,
        0,
        reason:
            'a grant went out on the new connection for a stream that only ever '
            'existed on the old one',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // CONTROL: crediting must still work, or the guard has replaced an over-grant
  // with a stall. Same rig, same call, an id that IS live here.
  test(
    'CONTROL: a credit for a live id still grants',
    () async {
      final one = _pair();
      final client = RpcWebSocketCallerTransport(one.client, policy: _policy);
      final server = RpcWebSocketResponderTransport(
        one.server,
        policy: _policy,
      );
      addTearDown(() async {
        await client.close().catchError((Object _) {});
        await server.close().catchError((Object _) {});
      });

      final liveId = server.createStream();
      await server.sendMetadata(
        liveId,
        RpcMetadata.forClientRequest('Svc', 'm'),
      );
      await _settle();

      final before = one.frames;
      client.returnFlowCredit(liveId, _window);
      await _settle();

      expect(
        one.frames - before,
        1,
        reason:
            'the guard dropped a credit for a stream live on this connection, so '
            'its window is never replenished',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  // GUARD: the four send paths must keep their own guard. It is the parity this
  // fix restores, and a change that loosened it would not show up above.
  test(
    'GUARD: a send for a stale id is still dropped',
    () async {
      final one = _pair();
      final two = _pair();
      final client = RpcWebSocketCallerTransport(
        one.client,
        policy: _policy,
        reconnectFactory: () async => two.client,
      );
      final server1 = RpcWebSocketResponderTransport(
        one.server,
        policy: _policy,
      );
      addTearDown(() async {
        await client.close().catchError((Object _) {});
        await server1.close().catchError((Object _) {});
      });

      final staleId = server1.createStream();
      await server1.sendMetadata(
        staleId,
        RpcMetadata.forClientRequest('Svc', 'm'),
      );
      await _settle();

      await client.reconnect();
      final server2 = RpcWebSocketResponderTransport(
        two.server,
        policy: _policy,
      );
      addTearDown(() async {
        await server2.close().catchError((Object _) {});
      });
      await _settle();

      final before = two.frames;
      await client.sendMetadata(
        staleId,
        RpcMetadata([const RpcHeader('x-probe-stale', '1')]),
        endStream: true,
      );
      await _settle();

      expect(two.frames - before, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

// ── an in-memory socket that counts what the wrapper writes to it ────────────

class _Pair {
  _Pair(this.client, this.server, this._count);

  final WebSocketChannel client;
  final WebSocketChannel server;
  final _Count _count;

  int get frames => _count.n;
}

class _Count {
  int n = 0;
}

_Pair _pair() {
  final c2s = StreamController<Object?>();
  final s2c = StreamController<Object?>();
  final count = _Count();
  return _Pair(
    _MemChannel(incoming: s2c.stream, outgoing: c2s.sink, count: count),
    _MemChannel(incoming: c2s.stream, outgoing: s2c.sink),
    count,
  );
}

class _MemChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _MemChannel({
    required Stream<Object?> incoming,
    required StreamSink<Object?> outgoing,
    _Count? count,
  }) : stream = incoming,
       sink = _MemSink(outgoing, count);

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

class _MemSink implements WebSocketSink {
  _MemSink(this._out, this._count);

  final StreamSink<Object?> _out;
  final _Count? _count;
  bool _closed = false;

  @override
  void add(Object? data) {
    if (_closed) return;
    if (data is List<int>) _count?.n++;
    _out.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _out.addError(error, stackTrace);
  }

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
