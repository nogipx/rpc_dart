// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `sendMessage` adds the stream id to `_halfClosedLocal` AFTER awaiting the pump,
// and it is the only one of the three add sites that does. A peer RST_STREAM
// arriving while the send is parked on the window clears every per-stream map AND
// wakes the pump, so the woken send put the id back into a set nothing would
// remove again -- one entry per reset stream, for the life of the connection.
//
// The window is owned by the server here: SETTINGS with INITIAL_WINDOW_SIZE=64
// means the second send parks, which no real-server rig can schedule reliably.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// Completes the HTTP/2 handshake with a per-stream window of [windowSize] and
/// then reads without ever granting more, so a send parks and stays parked.
Future<(ServerSocket, Future<Socket>)> _pinholeServer({
  required int windowSize,
}) async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  final first = Completer<Socket>();
  listener.listen((socket) {
    socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    unawaited(socket.done.catchError((Object _) => socket));
    socket.add([
      0, 0, 6, 4, 0, 0, 0, 0, 0, // SETTINGS, length 6, stream 0
      0, 4, // SETTINGS_INITIAL_WINDOW_SIZE
      (windowSize >> 24) & 0xFF,
      (windowSize >> 16) & 0xFF,
      (windowSize >> 8) & 0xFF,
      windowSize & 0xFF,
    ]);
    socket.add([0, 0, 0, 4, 1, 0, 0, 0, 0]); // ACK for the client's SETTINGS
    socket.flush();
    if (!first.isCompleted) first.complete(socket);
  });
  return (listener, first.future);
}

void _frameOn(Socket socket, int type, int streamId, List<int> payload) {
  socket.add([
    0,
    0,
    payload.length,
    type,
    0,
    (streamId >> 24) & 0xFF,
    (streamId >> 16) & 0xFF,
    (streamId >> 8) & 0xFF,
    streamId & 0xFF,
    ...payload,
  ]);
  socket.flush();
}

/// RST_STREAM(CANCEL): ends the incoming side, so the inline release clears every
/// per-stream map, and cancels the outgoing sink, so the pump wakes whatever is
/// parked on the window. Both halves of the race in one frame.
void _resetStream(Socket socket, int streamId) =>
    _frameOn(socket, 3, streamId, [0, 0, 0, 8]);

void _windowUpdate(Socket socket, int streamId, int increment) =>
    _frameOn(socket, 8, streamId, [
      (increment >> 24) & 0xFF,
      (increment >> 16) & 0xFF,
      (increment >> 8) & 0xFF,
      increment & 0xFF,
    ]);

Uint8List _frame(int payloadBytes) =>
    RpcMessageFrame.encode(Uint8List(payloadBytes));

Future<Map<String, Object?>> _maps(RpcHttp2CallerTransport t) async {
  final d = (await t.health()).details;
  return {
    'activeStreams': d['activeStreams'],
    'halfClosedLocal': d['halfClosedLocal'],
    'outgoingPumps': d['outgoingPumps'],
  };
}

/// Opens a stream, fills the window, parks an `endStream: true` send on it, and
/// returns the readings around the reset. [openWindowFirst] decides whether the
/// release lands while the send is still parked.
Future<
  ({
    bool parked,
    Object? threw,
    Map<String, Object?> whileParked,
    Map<String, Object?> windowOpen,
    Map<String, Object?> afterReset,
  })
>
_parkThenReset({required bool openWindowFirst}) async {
  final (listener, socketFuture) = await _pinholeServer(windowSize: 64);
  final socket = await Socket.connect('127.0.0.1', listener.port);
  final serverSocket = await socketFuture;
  final transport = RpcHttp2CallerTransport.viaSocket(
    socket,
    host: '127.0.0.1',
    port: listener.port,
    scheme: 'http',
  );
  addTearDown(() async {
    await transport.close().catchError((Object _) {});
    await listener.close();
  });

  // The SETTINGS must land before the stream opens, or it gets the default
  // 65535-byte window and nothing ever parks.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final id = transport.createStream();
  await transport.sendMetadata(
    id,
    RpcMetadata.forClientRequest('Svc', 'Upload'),
  );

  // Two sends, because the pump checks `_paused` BEFORE adding: the first fills
  // the 64-byte window and pauses the sink, the second parks.
  unawaited(transport.sendMessage(id, _frame(512)).catchError((Object _) {}));
  await Future<void>.delayed(const Duration(milliseconds: 150));

  var finished = false;
  Object? threw;
  final parked = Future<void>(() async {
    try {
      await transport.sendMessage(id, _frame(512), endStream: true);
    } catch (e) {
      threw = e;
    } finally {
      finished = true;
    }
  });
  await Future<void>.delayed(const Duration(milliseconds: 150));

  final wasParked = !finished;
  final whileParked = await _maps(transport);

  var windowOpen = <String, Object?>{};
  if (openWindowFirst) {
    _windowUpdate(serverSocket, id, 65535);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    windowOpen = await _maps(transport);
  }

  _resetStream(serverSocket, id);
  await parked.timeout(
    const Duration(seconds: 5),
    onTimeout: () => throw StateError('the parked send never unwound'),
  );
  // A late add is still a leak, so this settles rather than sampling at once.
  await Future<void>.delayed(const Duration(milliseconds: 300));

  return (
    parked: wasParked,
    threw: threw,
    whileParked: whileParked,
    windowOpen: windowOpen,
    afterReset: await _maps(transport),
  );
}

void main() {
  // WITNESS. Before the fix the last reading was
  // {activeStreams: 0, halfClosedLocal: 1}.
  test(
    'a reset landing on a parked half-close leaves nothing in halfClosedLocal',
    () async {
      final r = await _parkThenReset(openWindowFirst: false);

      // Guards first: without these the assertion below passes for the wrong
      // reason, which is how round 564 came to report a zero that guarded
      // nothing.
      expect(
        r.parked,
        isTrue,
        reason:
            'the send must still be parked when the reset lands, or the '
            'race under test never happens',
      );
      expect(r.whileParked['activeStreams'], 1);
      expect(
        r.whileParked['halfClosedLocal'],
        0,
        reason: 'the id is added only once the send completes',
      );

      expect(
        r.afterReset['activeStreams'],
        0,
        reason: 'the inline release runs on the reset',
      );
      expect(
        r.afterReset['halfClosedLocal'],
        0,
        reason:
            'the woken send put the id back into a set the release had '
            'already cleared, and nothing removes it again',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // WITNESS, the send's own answer. A peer RST_STREAM cancels the pump's SINK
  // without disposing the pump, so the woken `add` used to queue its payload into
  // a controller whose destination was already gone and return NORMALLY. Measured
  // on the wire: the server read only the first send's 64 bytes, never the 512
  // this one carries. Round 558's rule -- a send that did not reach the peer must
  // not read as success -- on the path its own arm could not reach, because that
  // arm disposed the pump.
  test('a parked send fails when the peer resets the stream', () async {
    final r = await _parkThenReset(openWindowFirst: false);

    expect(r.parked, isTrue);
    expect(
      r.threw,
      isA<RpcStatusException>(),
      reason:
          'returning normally told the caller a payload had been sent that '
          'went nowhere',
    );
    expect((r.threw! as RpcStatusException).statusCode, RpcStatus.unavailable);
  });

  // WITNESS, the pump. Of the seven per-stream maps `health()` reports, this was
  // the only one the inline release left behind: `releaseStreamId` was the only
  // path that disposed a pump, so a stream ending any other way kept one until its
  // id was released -- which a direct transport user need never do.
  test('the inline release disposes the stream pump too', () async {
    final r = await _parkThenReset(openWindowFirst: false);

    expect(r.whileParked['outgoingPumps'], 1, reason: 'the arm needs a pump');
    expect(r.afterReset['outgoingPumps'], 0);
  });

  // CONTROL. Reads 0 before and after the fix, and that is not what it is for:
  // its `windowOpen` row is the proof that the add site runs AT ALL. If that
  // ever reads 0 the witness above is vacuous and proves nothing.
  test(
    'CONTROL: a half-close that completes before the reset does add the id',
    () async {
      final r = await _parkThenReset(openWindowFirst: true);

      expect(r.parked, isTrue);
      expect(
        r.threw,
        isNull,
        reason:
            'a send that DID reach the peer must still read as success -- '
            'the sink-cancelled signal must not fire on a clean completion',
      );
      expect(
        r.windowOpen['halfClosedLocal'],
        1,
        reason:
            'the window opened, so the send completed while the stream was '
            'still active -- this is the add the witness asserts is skipped '
            'when the stream is gone',
      );
      expect(r.windowOpen['activeStreams'], 1);
      expect(
        r.afterReset['halfClosedLocal'],
        0,
        reason: 'the release that follows clears what the completed send added',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
