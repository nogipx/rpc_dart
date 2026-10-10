// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

extension _Http2CallerLifecycle on RpcHttp2CallerTransport {
  /// Re-arms [ready] for the connection just attached.
  void _armReady() {
    final ready = _ready.isCompleted ? Completer<void>() : _ready;
    _ready = ready;
    // An unobserved failure would reach the root zone; the caller that cares
    // awaits [ready] itself.
    unawaited(ready.future.catchError((Object _) {}));
    final number = _connectionNumber;
    unawaited(
      _connection.onInitialPeerSettingsReceived.then((_) {
        if (number == _connectionNumber && !ready.isCompleted) {
          ready.complete();
        }
      }, onError: (Object _) {}),
    );
  }

  /// Connection [number] is gone: its socket ended, or keepalive found the
  /// path dead. Fails what is left on it and reports it on [connectionLost].
  ///
  /// [incomingMessages] stays open across a drop for [reconnect], so without
  /// the report nothing listening can tell a drop from a quiet connection;
  /// `RpcClientConnection` reconnects on it.
  void _connectionLost(int number) {
    if (number != _connectionNumber || _lostConnection == number) return;
    if (_isClosed) return;
    _lostConnection = number;
    _disconnected = true;
    if (!_ready.isCompleted) {
      _ready.completeError(
        RpcStatusException(
          RpcStatus.unavailable,
          'HTTP/2 connection to $_host:$_port ended before its SETTINGS',
        ),
      );
    }
    _discardConnection(_connection);
    if (!_lostCtl.isClosed) _lostCtl.add(null);
  }

  /// (Re)starts PING keepalive for the current connection.
  ///
  /// Called from the constructor and again after [reconnect] swaps
  /// `_connection`: a timer left pointing at the old connection would ping a
  /// corpse forever and never probe the live one.
  ///
  /// A dead peer never answers, so `ping()` simply never completes — the
  /// timeout is what actually detects the half-open path. On failure the
  /// connection is TERMINATED, never finished: `finish()` on a connection whose
  /// peer is gone throws from package:http2 into the root zone. Terminating
  /// makes `isOpen` false, so pending calls fail UNAVAILABLE and health()
  /// reports the connection down — which is what a supervisor needs in order to
  /// reconnect.
  ///
  /// Every await is guarded: this runs on a detached timer callback, where an
  /// unhandled async error reaches the root zone and kills the isolate.
  void _startKeepalive() {
    _keepalive?.cancel();
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
          'half-open, tearing the connection down so calls fail fast',
        );
        _connectionLost(number);
      },
    );
  }

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'disconnected': _disconnected,
    'connectionOpen': _connection.isOpen,
    'activeStreams': _activeStreams.length,
    'pendingSubscriptions': _streamSubscriptions.length,
    'pendingParsers': _streamParsers.length,
    // Reported for the same reason as its siblings: growth here is the
    // observable symptom of a per-stream entry that was added and never removed.
    // It was the one per-stream map NOT reported, and it is the one whose add in
    // `sendMessage` happens AFTER an await, so a release landing in that window
    // leaves an entry nothing removes again (B-184).
    'halfClosedLocal': _halfClosedLocal.length,
    // Per-stream state that only a TEARDOWN clears, exposed because the three
    // teardown paths clear different subsets and no instrument could see the
    // difference. An outgoing pump left behind is the expensive one: a caller
    // parked on the server's window never unwinds once its stream is gone,
    // which is why `releaseStreamId` disposes it first.
    'fcOutstanding': _fcOutstanding.length,
    'outgoingPumps': _outgoingPumps.length,
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

  Future<RpcHealthStatus> _reconnectOnce() async {
    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'Transport is closed and cannot be reconnected',
        details: {..._buildHealthDetails(), 'supported': false},
      );
    }

    // BEFORE the teardown. Whether this transport can rebuild its connection is
    // fixed at construction, and the teardown below is destructive: it cancels
    // every subscription, disposes every pump and clears six per-stream maps.
    // Answering here leaves the LIVE connection intact and every in-flight call
    // with it.
    final factory = _connectionFactory;
    if (factory == null) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message:
            'This transport was built over a socket it did not open, so the '
            'connection cannot be recreated; build a new transport instead.',
        details: {..._buildHealthDetails(), 'supported': false},
      );
    }

    _logger?.info('Reconnecting the HTTP/2 client to $_host:$_port');

    // terminate(), not finish(). finish() writes a GOAWAY, and reconnect is
    // called precisely when the connection is already gone -- either the peer
    // died, or an earlier reconnect finished this very connection. Writing to a
    // closed frame writer makes package:http2 throw
    //
    //   Bad state: Cannot add event after closing
    //     package:http2 ... FrameWriter.writeGoawayFrame
    //     asynchronous gap
    //     package:http2/src/connection.dart  Connection._setupConnection
    //
    // ASYNCHRONOUSLY, from a subscription it created in the ROOT zone. The
    // try/catch below never saw it, and an unhandled async error in the root
    // zone kills the isolate. Reproduced by simply calling reconnect() twice.
    //
    // _discardConnection exists for exactly this and is already used on the
    // abandon path; the prologue just never used it.
    //
    // Its socket ending is this reconnect's own doing, not a loss to report.
    _lostConnection = _connectionNumber;
    _discardConnection(_connection);

    // TELL THE CONSUMERS FIRST. `terminate()` above delivers its per-stream errors
    // asynchronously, and the loop below cancels each subscription -- so the first
    // subscription was gone before its error arrived and its consumer waited out
    // its deadline with nothing. Measured with three in-flight server streams:
    // `call 0 STILL WAITING` while calls 1 and 2 failed in ~10ms, and one stream
    // controller left behind afterwards.
    //
    // `closeAll`'s `error` argument exists for exactly this -- "a transport closing
    // under its callers wants to tell the ones that were IN FLIGHT why their call
    // ended" -- and the reconnect path never used it.
    //
    // The ARGUMENT is not optional here even though the race above resolves in the
    // consumers' favour once the loop stops crashing: `closeAll()` bare would close
    // a waiting consumer's stream with a CLEAN END, turning a hang into silent
    // truncation. What the call is needed for either way is the entry it drops --
    // one stream controller was left behind per stranded call.
    _streams.closeAll(
      error: (streamId) => RpcStatusException(
        RpcStatus.unavailable,
        'HTTP/2 connection to $_host:$_port was replaced by a reconnect while '
        'stream $streamId was in flight; retry on the new connection',
      ),
    );

    // A COPY, and it is load-bearing: `_discardConnection` above terminated the
    // connection, which ends every stream ASYNCHRONOUSLY, and each ending runs the
    // inline release -- which removes its own `_streamSubscriptions` entry. The
    // `await` inside this loop is where those endings land, so iterating the live
    // map threw `Concurrent modification during iteration` and reconnect() died
    // half-torn-down, with no new connection and every map already cleared.
    // Reproduced with two in-flight server streams.
    for (final subscription in List.of(_streamSubscriptions.values)) {
      try {
        await subscription.cancel();
      } catch (e) {
        _logger?.warning('Error cancelling a subscription: $e');
      }
    }
    _streamSubscriptions.clear();
    // Release every producer parked on a server window before the streams go.
    for (final pump in _outgoingPumps.values) {
      pump.dispose();
    }
    _outgoingPumps.clear();
    _streamParsers.clear();
    _activeStreams.clear();
    _initialHeadersReceived.clear();
    _halfClosedLocal.clear();
    _reservedStreams.clear();
    _statusReceived.clear();
    // The flow-control ledgers and the reset-id memory belong to the connection
    // that just went: ids on the new one start from scratch, so an entry carried
    // over meters a stream that no longer exists.
    _fcOutstanding.clear();
    _fcRefused.clear();
    _resetStreams.clear();

    // From here until the attach below there is no connection, and saying so is
    // what makes `_ensureUsable` the one that answers. Without it the flag was
    // false for the whole factory await, the guard passed, and the refusal came
    // from the discarded connection instead -- the right CODE (14) by accident
    // and the wrong TYPE, so a caller branching on RpcNoConnectionException saw
    // it on the websocket sibling and not here for the same state.
    //
    // NOT the silent-drop fix round 449 refuted: nothing is lost in this window
    // either way, which that round measured. This is about which code answers.
    _disconnected = true;
    try {
      final connection = await factory();

      // Re-check AFTER the factory. The guard at the top of this method runs
      // before every await here, and opening a connection takes real time, so
      // close() lands inside that window. Two things went wrong when it did:
      // the new connection was attached to a transport the caller had already
      // closed (nothing holds it, so it can never be closed), and
      // `_isClosed = false` below UN-CLOSED the transport, so isClosed lied.
      //
      // Measured through the CONNECT-proxy path, which stalls the factory the
      // way a real network does (400ms), with close() 20ms in:
      //
      //   control, plain connect + close : live=0  isClosed=true
      //   close during reconnect, before : live=1  isClosed true -> FALSE,
      //                                    reconnect reported HEALTHY
      //   close during reconnect, after  : live=0  isClosed stays true
      //
      // Same defect as RpcClientConnection in core (334b3337) and
      // RpcWebSocketCallerTransport (32966691), both of which checked before
      // the await and not after. This one is worse because of the un-close.
      if (_isClosed || _messageController.isClosed) {
        _discardConnection(connection);
        return RpcHealthStatus.closed(
          component: runtimeType.toString(),
          message: 'Transport closed during reconnect',
          details: {..._buildHealthDetails(), 'supported': true},
        );
      }

      _connection = connection;
      _connectionNumber = _drainSignal.built;
      _disconnected = false;
      // `_nextStreamId` is deliberately NOT reset here.
      //
      // It used to be, and that handed the first call on the new connection the
      // id a call from the old one still held. This id is rpc_dart's own handle
      // — package:http2 assigns the real HTTP/2 stream ids itself in
      // `makeRequest`, and `_activeStreams` is keyed by the handle — so nothing
      // about the protocol requires it to restart, while everything about
      // teardown requires it not to: a caller releases its id and half-closes
      // by id, and the id is all it has to present.
      //
      // Measured, one reconnect between two calls, with the first still open:
      //
      //   before: A and B both get id 1, and B's `getMessagesForStream(1)`
      //           throws "Bad state: Stream has already been listened to" —
      //           A's controller is still registered under that id
      //   after : A keeps 1, B gets 3, both served
      //
      // The websocket sibling had the same defect in quieter form (there the
      // ids collide silently and a dead call's `finishSending` HALF-CLOSES the
      // live one). Fixed there by continuing the id sequence across the swap;
      // same principle, one line here.
      // The signal is per-TRANSPORT but describes the CURRENT connection, and
      // the factory closure reports every connection into the same holder. A
      // stale flag here would make a freshly reconnected transport claim it was
      // draining and refuse every call.
      _drainSignal.goawayReceived = false;
      _armReady();
      // Re-arm keepalive against the NEW connection. The old timer closed over
      // the old one, so without this a reconnected transport either pings a
      // corpse forever or (after a keepalive-triggered teardown, which cancels
      // the timer) is left with no keepalive at all — blind again after exactly
      // the first drop, which is when a flaky path is most likely.
      _startKeepalive();
      _logger?.info('HTTP/2 client reconnected');
      return RpcHealthStatus.healthy(
        component: runtimeType.toString(),
        message: 'HTTP/2 connection re-established',
        details: {..._buildHealthDetails(), 'supported': true},
      );
    } catch (error, stackTrace) {
      // NOT _isClosed: the caller did not close this transport, it merely has
      // no connection right now. Marking it closed made the first failure
      // terminal -- retry-with-backoff, the only way anyone drives reconnect,
      // could never recover.
      _disconnected = true;
      _logger?.error(
        'Failed to reconnect the HTTP/2 client',
        error: error,
        stackTrace: stackTrace,
      );
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Failed to reconnect HTTP/2 transport: $error',
        details: {
          ..._buildHealthDetails(),
          'supported': true,
          'error': error.toString(),
        },
      );
    }
  }
}
