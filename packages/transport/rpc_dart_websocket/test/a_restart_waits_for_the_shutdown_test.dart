// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_isRunning = false` is set at the TOP of `stop()` and all its work — the
// drain, then the closes — happens after it. A `start()` landing in that window
// flipped the flag back and the stop carried on regardless, so every connection
// the restarted server accepted belonged to the shutdown:
//
//   accepted before the close snapshot   torn down, while the server reports running
//   accepted after it                    dropped by `_endpoints.clear()`, never closed
//
// The second is the worse one. Nothing holds that endpoint, so no later `stop()`
// or `dispose()` can reach it: the peer has a working socket that this server has
// forgotten.
//
// The two windows need different rigs. Reaching the drain window needs a REAL
// in-flight call — with none, the drain returns on its first poll and the arm
// silently becomes a second copy of the close-window arm.
//
// What is read is the KIND of close the fresh connection got: refused outright
// (answered, with a reason), torn down by the shutdown, or never closed at all.
// A boolean cannot tell the first from the second, and the fix must produce the
// first for a peer arriving mid-shutdown and neither for one arriving after it.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

typedef _Run = ({String freshOutcome, int endpointsHeld, int startMillis});

/// [window] picks where the fresh connection lands: `drain` and `close` are the
/// two halves of a shutdown, `after` waits for the shutdown to finish first, and
/// `none` never stops at all.
Future<_Run> _restart(String window) async {
  final conns = StreamController<WebSocketChannel>();
  final server = RpcWebSocketServer.createWithContracts(
    connections: conns.stream,
    contracts: [_Slow()..setup()],
  );
  addTearDown(() async {
    await server.dispose().catchError((Object _) {});
    await conns.close();
  });
  await server.start();

  Future<void>? stopping;
  Future<Object?>? inFlight;

  if (window != 'none') {
    if (window == 'drain') {
      final (clientWs, serverWs) = _pair();
      conns.add(serverWs);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(clientWs),
      );
      inFlight = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Slow',
            methodName: 'wait',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .catchError((Object _) => 'failed'.rpc);
    } else {
      // A close slow enough to give the close loop a window to land inside.
      conns.add(_Channel(closeDelay: const Duration(milliseconds: 600)));
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));

    stopping = server.stop(
      drainTimeout: window == 'drain' ? const Duration(seconds: 3) : null,
    );
    if (window == 'after') {
      await stopping;
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  final watch = Stopwatch()..start();
  await server.start();
  watch.stop();

  if (window == 'close') {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  final fresh = _Channel(closeDelay: Duration.zero);
  conns.add(fresh);
  await Future<void>.delayed(const Duration(milliseconds: 100));

  await stopping;
  await inFlight;
  await Future<void>.delayed(const Duration(milliseconds: 200));

  return (
    freshOutcome: (fresh.sink as _Sink).outcome,
    endpointsHeld: server.endpoints.length,
    startMillis: watch.elapsedMilliseconds,
  );
}

void main() {
  test(
    'WITNESS: a restart during the DRAIN does not hand its connection to the shutdown',
    () async {
      final run = await _restart('drain');

      expect(
        run.freshOutcome,
        'never',
        reason:
            'the connection was accepted by the restarted server and then closed '
            'by the stop that was still running',
      );
      expect(
        run.endpointsHeld,
        1,
        reason:
            'the restarted server is not holding the connection it accepted',
      );
      // The serialisation itself: start() cannot return before the shutdown it
      // was asked to follow has finished.
      expect(run.startMillis, greaterThan(50));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS: a restart during the CLOSE does not leak its connection',
    () async {
      final run = await _restart('close');

      expect(
        run.freshOutcome,
        'never',
        reason: 'closed by a shutdown the caller had already superseded',
      );
      expect(
        run.endpointsHeld,
        1,
        reason:
            '`_endpoints.clear()` dropped it, so nothing can ever close that '
            'socket: no later stop() or dispose() knows it exists',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: the ordinary restart, and a server that never stopped. Both must
  // hold the connection — without them "held and unclosed" is satisfied by a rig
  // that never delivered a connection at all.
  for (final window in ['after', 'none']) {
    test(
      'CONTROL: window=$window holds the fresh connection',
      () async {
        final run = await _restart(window);
        expect(run.freshOutcome, 'never');
        expect(run.endpointsHeld, 1);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  // GUARD: a peer arriving while a shutdown really IS in flight, with no restart
  // asked for, must still be REFUSED — answered with a close and a reason, never
  // accepted. That is deliberate behaviour and the opposite of what this fix
  // could have been mistaken for.
  test(
    'GUARD: mid-shutdown, with no restart, a peer is still refused',
    () async {
      final conns = StreamController<WebSocketChannel>();
      final server = RpcWebSocketServer.createWithContracts(
        connections: conns.stream,
        contracts: [_Slow()..setup()],
      );
      addTearDown(() async {
        await server.dispose().catchError((Object _) {});
        await conns.close();
      });
      await server.start();

      conns.add(_Channel(closeDelay: const Duration(milliseconds: 600)));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final stopping = server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final fresh = _Channel(closeDelay: Duration.zero);
      conns.add(fresh);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await stopping;

      expect((fresh.sink as _Sink).outcome, 'refused');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// A handler slow enough that the drain has something to wait for.
final class _Slow extends RpcResponderContract {
  _Slow() : super('Slow');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'wait',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return 'done'.rpc;
      },
    );
  }
}

/// Two in-memory channels wired back to back, so a real call can be in flight.
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

class _Channel extends StreamChannelMixin<Object?> implements WebSocketChannel {
  _Channel({required Duration closeDelay})
    // A controller that stays OPEN. `Stream.empty()` ends at once, which tears
    // the endpoint down before anything here can observe it.
    : _incoming = StreamController<Object?>(),
      sink = _Sink(closeDelay) {
    stream = _incoming.stream;
  }

  final StreamController<Object?> _incoming;

  @override
  late final Stream<Object?> stream;

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

class _Sink implements WebSocketSink {
  _Sink(this._delay);

  final Duration _delay;
  final _done = Completer<void>();

  /// Refused outright, torn down by a shutdown, or never closed. A boolean
  /// cannot tell the first two apart, and they are different defects.
  String outcome = 'never';

  @override
  void add(Object? data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {}

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    outcome = (closeReason ?? '').contains('not accepting')
        ? 'refused'
        : 'torn down';
    await Future<void>.delayed(_delay);
    if (!_done.isCompleted) _done.complete();
  }
}
