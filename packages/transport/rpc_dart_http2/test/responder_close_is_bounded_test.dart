// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The two HTTP/2 transports shut their connection down differently, and only
// one of them was right.
//
// The CALLER bounds it: `finish().timeout(...)` with a `terminate()` fallback,
// above a comment explaining that `finish()` sends GOAWAY and waits for open
// streams to drain -- so over a half-open path it never completes -- and that
// on a connection already dead it "throws from package:http2 into the root
// zone".
//
// The RESPONDER did `await _connection.finish()` bare. Both failure modes
// therefore landed on the server, which is the worse place for them: the hang
// holds shutdown open forever, and a root-zone throw has nothing above it
// listening, so it takes the isolate.
//
// The timeout alone would not be enough. `Future.timeout` abandons the await,
// not the work, so the connection stays alive and unreferenced; `terminate()`
// is what releases it. Both halves are asserted below.

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// A connection whose graceful shutdown never finishes, like a half-open peer
/// that drains nothing.
class _HangingConnection implements http2.ServerTransportConnection {
  final StreamController<http2.ServerTransportStream> _incoming =
      StreamController<http2.ServerTransportStream>();

  /// Completes if and only if the transport falls back to forcing the close.
  final Completer<void> terminated = Completer<void>();

  /// Whether `finish()` was reached at all -- the graceful attempt must still
  /// happen first, or a healthy connection would be killed instead of drained.
  bool finishCalled = false;

  @override
  Stream<http2.ServerTransportStream> get incomingStreams => _incoming.stream;

  @override
  Future<void> finish() {
    finishCalled = true;
    return Completer<void>().future; // never completes
  }

  @override
  Future<void> terminate([int? errorCode, String? message]) async {
    if (!terminated.isCompleted) terminated.complete();
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<void> ping() async {}

  @override
  set onActiveStateChanged(http2.ActiveStateHandler callback) {}

  @override
  Future<void> get onInitialPeerSettingsReceived async {}

  @override
  Stream<int> get onPingReceived => const Stream.empty();

  @override
  Stream<void> get onFrameReceived => const Stream.empty();
}

/// A connection that shuts down promptly, as a live peer does.
class _HealthyConnection implements http2.ServerTransportConnection {
  final StreamController<http2.ServerTransportStream> _incoming =
      StreamController<http2.ServerTransportStream>();

  bool finishCalled = false;
  bool terminateCalled = false;

  @override
  Stream<http2.ServerTransportStream> get incomingStreams => _incoming.stream;

  @override
  Future<void> finish() async {
    finishCalled = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<void> terminate([int? errorCode, String? message]) async {
    terminateCalled = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<void> ping() async {}

  @override
  set onActiveStateChanged(http2.ActiveStateHandler callback) {}

  @override
  Future<void> get onInitialPeerSettingsReceived async {}

  @override
  Stream<int> get onPingReceived => const Stream.empty();

  @override
  Stream<void> get onFrameReceived => const Stream.empty();
}

void main() {
  test('close() completes even when the peer never drains', () async {
    final connection = _HangingConnection();
    final transport = RpcHttp2ResponderTransport(connection: connection);

    // Generous against the 2 s budget, tight against "forever". Before the fix
    // this await never returned.
    await transport.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail(
        'close() did not return: the bare `await finish()` is unbounded, so a '
        'half-open peer holds server shutdown open indefinitely',
      ),
    );

    expect(
      connection.finishCalled,
      isTrue,
      reason: 'the graceful attempt must come first',
    );
    expect(
      connection.terminated.isCompleted,
      isTrue,
      reason:
          'a timeout abandons the await, not the work -- without terminate() '
          'the connection stays alive and unreferenced',
    );
    expect(transport.isClosed, isTrue);
  });

  // CONTROL: the fix must not turn every shutdown into a forced one. A peer
  // that drains promptly is finished gracefully and never terminated.
  test('CONTROL: a healthy connection is finished, not terminated', () async {
    final connection = _HealthyConnection();
    final transport = RpcHttp2ResponderTransport(connection: connection);

    await transport.close().timeout(const Duration(seconds: 10));

    expect(connection.finishCalled, isTrue);
    expect(
      connection.terminateCalled,
      isFalse,
      reason:
          'terminate() is the fallback; reaching it on a live connection would '
          'cut streams that were about to drain',
    );
  });

  // GUARD: close() is reachable twice -- the server calls it, and so does an
  // owner that built the transport itself.
  test('GUARD: a second close() is a no-op', () async {
    final connection = _HangingConnection();
    final transport = RpcHttp2ResponderTransport(connection: connection);

    await transport.close().timeout(const Duration(seconds: 10));
    await transport.close().timeout(const Duration(seconds: 10));

    expect(transport.isClosed, isTrue);
  });
}
