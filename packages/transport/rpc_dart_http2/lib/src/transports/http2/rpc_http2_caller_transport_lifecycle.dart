// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

extension _Http2CallerLifecycle on RpcHttp2CallerTransport {
  /// Arms [ready] for the connection.
  void _armReady() {
    // An unobserved failure would reach the root zone; the caller that cares
    // awaits [ready] itself.
    unawaited(_ready.future.catchError((Object _) {}));
    unawaited(
      _connection.onInitialPeerSettingsReceived.then((_) {
        if (!_ready.isCompleted) _ready.complete();
      }, onError: (Object _) {}),
    );
  }

  /// Connection [number] is gone: its socket ended, or keepalive found the
  /// path dead. The transport closes, which is how the layers above learn of
  /// it: [incomingMessages] ends.
  ///
  /// The calls in flight are failed FIRST, with UNAVAILABLE. [close] cancels
  /// their subscriptions, so a stream whose error had not arrived by then would
  /// otherwise end clean -- truncation reported as completion.
  void _connectionLost(int number) {
    if (number != _connectionNumber || _isClosed || _connectionGone) return;
    _connectionGone = true;
    if (!_ready.isCompleted) {
      _ready.completeError(
        RpcStatusException(
          RpcStatus.unavailable,
          'HTTP/2 connection to $_host:$_port ended before its SETTINGS',
        ),
      );
    }
    _streams.closeAll(
      error: (streamId) => RpcStatusException(
        RpcStatus.unavailable,
        'HTTP/2 connection to $_host:$_port was lost while stream $streamId '
        'was in flight',
      ),
    );
    _discardConnection(_connection);
    unawaited(close().catchError((Object _) {}));
  }

  /// Starts PING keepalive for the connection.
  ///
  /// A dead peer never answers, so `ping()` simply never completes — the
  /// timeout is what actually detects the half-open path. On failure the
  /// connection is TERMINATED, never finished: `finish()` on a connection whose
  /// peer is gone throws from package:http2 into the root zone. The transport
  /// then closes, so pending calls fail UNAVAILABLE.
  ///
  /// Every await is guarded: this runs on a detached timer callback, where an
  /// unhandled async error reaches the root zone and kills the isolate.
  void _startKeepalive() {
    final connection = _connection;
    final number = _connectionNumber;
    _keepalive = startHttp2Keepalive(
      interval: _pingInterval,
      timeout: _pingTimeout,
      ping: connection.ping,
      isDead: () => _isClosed,
      onDead: (error) {
        _logger?.warning(
          'HTTP/2 keepalive failed for $_host:$_port ($error); the path is '
          'half-open, closing the transport so calls fail fast',
        );
        _connectionLost(number);
      },
    );
  }

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'connectionOpen': _connection.isOpen,
    // Each counts the calls holding that part of their record, so growth in
    // one is the observable symptom of a part a teardown left behind.
    'activeStreams': _activeCount,
    'pendingSubscriptions': _count((call) => call.subscription != null),
    'pendingParsers': _count((call) => call.parser != null),
    // The one set in `sendMessage` AFTER an await, so a release landing in
    // that window is the way to leave it behind.
    'halfClosedLocal': _count((call) => call.halfClosedLocal),
    'fcOutstanding': _count((call) => call.flow.outstanding > 0),
    // An outgoing pump left behind is the expensive one: a caller parked on
    // the server's window never unwinds once its stream is gone, which is why
    // `releaseStreamId` disposes it first.
    'outgoingPumps': _count((call) => call.pump != null),
    'streamControllers': _streams.length,
    'host': _host,
    'port': _port,
    'scheme': _scheme,
    'messageControllerClosed': _messageController.isClosed,
  };

  /// Shuts down a connection this transport has decided to abandon.
  ///
  /// `terminate()`, never `finish()`: finishing a connection whose socket is
  /// already gone makes package:http2 throw `Bad state: Cannot add event after
  /// closing` from its own frame writer, asynchronously and after its own future
  /// has completed — so no handler at a call site can see it and it reaches the
  /// root zone, where an unhandled async error kills the isolate.
  /// `finish_throws_into_the_zone_test` characterises that, and the terminate
  /// rows beside it are why this returned future may be dropped: it stays silent
  /// on a live socket and on a destroyed one alike.
  void _discardConnection(http2.ClientTransportConnection connection) {
    try {
      connection.terminate();
    } catch (e) {
      _logger?.warning('Discarding abandoned connection failed: $e');
    }
  }
}
