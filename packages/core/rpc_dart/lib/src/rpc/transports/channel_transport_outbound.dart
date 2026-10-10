// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'channel_transport.dart';

extension _ChannelTransportOutbound on RpcChannelTransport {
  /// Refuses a WRITE on a closed transport.
  ///
  /// These three used to `return`, so a caller awaiting a send was told the
  /// bytes went out while nothing reached the wire. On a client-stream that is
  /// not a lost frame but a lost MESSAGE: the peer's handler is given a shorter
  /// sequence than the caller sent and answers normally, so both sides report
  /// success over different data.
  ///
  /// [RpcClosedException] rather than a bare `StateError`: it is classifiable
  /// by the caller and it survives the wire if it ever crosses one. This site
  /// spelled it `RpcStatusException(unavailable, ...)` while ten siblings threw
  /// `StateError`, and `_isTransportClosed` had to accept both by comparing
  /// message text.
  ///
  /// READS and teardown stay lenient: [finishSending] and [releaseStreamId] run
  /// from `finally` blocks, where a throw masks the error that got there.
  void _refuseIfClosed() {
    if (_closed) {
      throw _closedByPeer
          ? RpcClosedException.byPeer('Transport')
          : RpcClosedException('Transport');
    }
  }

  /// Sends [message] once the windows admit [bytes] and one message, parking
  /// for credit when they do not.
  Future<void> _sendMetered(
    RpcTransportMessage message,
    int bytes, {
    bool direct = false,
  }) async {
    final streamId = message.streamId;
    final endStream = message.isEndOfStream;
    // Fast path FIRST, synchronously: with flow control off, or with credit in
    // hand, this must not introduce an `await`. An unconditional await adds a
    // microtask hop to every send even when the window is disabled, which
    // reorders frames on a path that was synchronous.
    if (!_fc.tryConsume(streamId, bytes, direct: direct)) {
      final parked = Completer<void>();
      _parkedSends[streamId] = parked;
      try {
        await _fc.awaitCredit(streamId, bytes, direct: direct);
        // Closed WHILE parked for credit — the reachable half, and the one that
        // loses a message on a live call rather than a dead one.
        _refuseIfClosed();
        await _channel.send(message);
        if (endStream) _markFinished(streamId);
      } finally {
        // Cleared whether the send went out or was refused: either way nothing
        // is waiting on the window any more, and `finishSending` must not be
        // held by a ghost.
        if (identical(_parkedSends[streamId], parked)) {
          _parkedSends.remove(streamId);
        }
        parked.complete();
      }
      return;
    }
    // The fifth ending site, and the only one that did not claim its ending.
    //
    // `tryConsume` admits on `credit > 0` rather than on fit and never consults
    // `_sendWaiters`, so in the turn a grant lands a parked sender is woken —
    // its continuation a MICROTASK — while this path takes the credit and goes
    // out first. Measured with a synchronous channel, which is what puts a
    // caller inside that turn:
    //
    //     [meta, meta, data(64), data(8)+END, data(64)]
    //                            ^ the ending, ahead of the parked frame
    //
    // GUARDED on `containsKey`, not an unconditional `await`: with the window
    // off nothing ever parks, and an await here would add a microtask hop to
    // every send on a path the comment above keeps deliberately synchronous.
    if (endStream &&
        _parkedSends.containsKey(streamId) &&
        !await _claimEnding(streamId)) {
      return;
    }
    await _channel.send(message);
    if (endStream) _markFinished(streamId);
  }

  /// Claims the right to end [streamId] and waits for anything parked on it.
  ///
  /// Every ending goes through here EXCEPT the one in [_sendMetered]'s parked
  /// branch, which IS the parked send: it would await its own completer, and
  /// that completes only after it returns.
  ///
  /// Returns false only when the transport closed, before the wait or during
  /// it. A repeat ending is not refused here — [finishSending] keeps its own
  /// `_finishedStreams` guard for that.
  Future<bool> _claimEnding(int streamId) async {
    if (_closed) return false;
    _rememberFinished(streamId);
    final parked = _parkedSends[streamId];
    if (parked != null) {
      try {
        await parked.future;
      } catch (_) {}
    }
    return !_closed;
  }

  /// Records that this side has ended its half of [streamId].
  ///
  /// Does NOT release the stream. Half-closing means "I have finished SENDING",
  /// and the call is outstanding until its response arrives — so releasing here
  /// made [RpcSecurityPolicy.maxActiveStreams] count senders rather than calls,
  /// and a client parked on four responses had its whole ceiling free again.
  ///
  /// The slot comes back on the terminal INBOUND frame (see [_onMessage]), on
  /// [releaseStreamId] for a call that ends without one — cancelled, failed, or
  /// abandoned — and on [close] for all of them at once.
  void _markFinished(int streamId) {
    _rememberFinished(streamId);
  }
}
