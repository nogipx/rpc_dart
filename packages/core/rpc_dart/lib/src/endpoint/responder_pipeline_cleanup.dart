// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _ResponderPipelineCleanup on RpcResponderPipelineMixin {
  /// Tells every in-flight stream about a transport error, then reclaims them.
  ///
  /// The connection is still up — that is what separates this from
  /// [_abortActiveStreams] — so the caller is reachable and gets the status the
  /// error carries instead of waiting out its own deadline and reporting
  /// UNAVAILABLE "Stream closed without receiving response", which names a
  /// symptom rather than a cause.
  ///
  /// Through `wireStatusFor`, which is default-deny: a FOREIGN error is
  /// redacted rather than described to the peer.
  Future<void> _answerActiveStreams(Object error) async {
    if (_respStreams.length == 0) return;

    final wire = wireStatusFor(error);
    final ids = _respStreams.values.map((s) => s.id).toList(growable: false);
    if (_log.isInternal) {
      _log.internal(
        'Answering ${ids.length} active stream(s) with ${wire.status}',
      );
    }

    for (final streamId in ids) {
      try {
        await transport.sendMetadata(
          streamId,
          RpcMetadata.forTrailer(
            wire.status,
            message: wire.message,
            statusDetailsBin: wire.detailsBin,
            // The STATUS must survive a message longer than the header cap.
            maxMessageLength: _trailerMessageCap(transport),
          ),
          endStream: true,
        );
      } catch (e, st) {
        // Best-effort by construction: the reason the transport errored is
        // often that it is going away, so this send failing is not news.
        _log.warning(
          'Could not report the transport error on stream $streamId: $e',
          error: e,
          stackTrace: st,
        );
      }
    }

    _abortActiveStreams('transport error');
  }

  /// Aborts every in-flight stream after the connection is gone.
  ///
  /// The incoming stream closing is the ONLY notice a responder gets that the
  /// peer is unreachable. Log it and do nothing else, and the handlers keep
  /// running with nowhere to send, their tokens never fire, and their stream
  /// state is never reclaimed — one abandoned handler and one stream state per
  /// dropped connection, which any peer can drive by opening streams against an
  /// expensive method and disconnecting.
  ///
  /// Both directions reach here: closing either end of a paired transport
  /// closes the channel.
  ///
  /// The token is cancelled first, so a handler polling it or awaiting
  /// `cancelled` unwinds cooperatively, exactly as on the cancellation and
  /// deadline paths.
  void _abortActiveStreams(String reason) {
    if (_respStreams.length == 0) return;
    if (_log.isInternal) {
      _log.internal(
        'Aborting ${_respStreams.length} active stream(s): $reason',
      );
    }

    for (final state in _respStreams.values) {
      final token = state.cachedContext?.cancellationToken;
      if (token != null && !token.isCancelled) token.cancel(reason);
    }

    final active = _respStreams.values.map((s) => s.id).toList(growable: false);
    for (final streamId in active) {
      _detached(_cleanupStream(streamId), 'stream cleanup');
    }
  }

  Future<void> _runDrain(Duration timeout) async {
    _respIsDraining = true;

    _log.info(
      'Drain started — cancelling ${_respStreams.length} active stream(s)',
    );

    // Cancel all active stream contexts.
    for (final state in _respStreams.values) {
      final ctx = state.cachedContext;
      if (ctx != null && ctx.cancellationToken != null) {
        ctx.cancellationToken!.cancel('server draining');
      }
    }

    // Wait for streams to finish — SIGNALLED, not polled.
    //
    // Polling every 50 ms meant a server whose last call finished a millisecond
    // into the drain still waited for the next tick, so shutdown paid up to a
    // full interval on every deploy for work that was already done.
    //
    // `timeout` here is a Timer rather than a `DateTime.now()` comparison, so a
    // wall-clock step cannot shorten or extend the budget.
    if (_respStreams.length > 0) {
      final idle = _respDrainIdle = Completer<void>();
      try {
        await idle.future.timeout(timeout);
      } on TimeoutException {
        // Fall through to the forced cleanup below, which is what the budget
        // expiring means.
      } finally {
        _respDrainIdle = null;
      }
    }

    if (_respStreams.length > 0) {
      _log.warning(
        'Drain timeout — ${_respStreams.length} stream(s) still active, forcing cleanup',
      );
      // Actually force the cleanup the log promises: close remaining responders
      // and release their state/stream IDs.
      final remaining = _respStreams.values
          .map((s) => s.id)
          .toList(growable: false);
      for (final streamId in remaining) {
        await _cleanupStream(streamId);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Stream management
  // ---------------------------------------------------------------------------

  /// Tears [streamId] down; [only] restricts that to one particular call.
  ///
  /// **Every teardown that runs after an await must pass it.** A stream id does
  /// not identify a call for longer than a connection: a peer numbers its own
  /// streams and restarts at the bottom on each socket, so across a reconnect the
  /// same number names a DIFFERENT call — and a handler parked when the socket
  /// dropped reaches this line with the old number in hand. Without the check it
  /// closed the new call's responder, released its id and remembered it as torn
  /// down, mid-answer, and the new caller waited out its own deadline.
  ///
  /// Nothing here can be done for a call that is already gone, so an id whose
  /// state has moved on is left entirely alone: remembering it as closed would
  /// make the pipeline ignore the live call's own frames, and releasing the slot
  /// would give away a slot that call is holding.
  ///
  /// The bulk teardowns ([_abortActiveStreams], [closeResponderResources], the
  /// drain's forced cleanup) do NOT pass it, and do not need to: they run when the
  /// connection or the endpoint is ending, so no new call can take the number.
  Future<void> _cleanupStream(
    int streamId, {
    RpcResponderStreamState? only,
  }) async {
    if (only != null && !identical(_respStreams[streamId], only)) {
      if (_log.isInternal) {
        _log.internal(
          'Skipping a stale cleanup for stream $streamId: the id now names '
          'another call',
        );
      }
      return;
    }
    // Remember the id even when there was no state: the rejection path can run
    // before the peer's payload frame arrives, and that frame must not open a
    // fresh, never-cleaned entry.
    _rememberClosedStream(streamId);

    // Before the early return below: a stream that never got as far as running
    // a handler -- half-open, unknown method, rejected -- still charged a slot
    // at admission, and nothing else would ever give it back. A stream whose
    // handler IS running keeps it; that handler releases it when it finishes.
    _releaseHandlerSlot(streamId);

    final state = _respStreams.take(streamId);

    // Tell a waiting drain, BEFORE the early return: whether this id had state or
    // not, what a drain is waiting for is the count reaching zero.
    if (_respStreams.length == 0) {
      final idle = _respDrainIdle;
      if (idle != null && !idle.isCompleted) idle.complete();
    }

    if (state == null) return;

    // The one check that can see a request vanishing between the peer and the
    // handler. Both sides otherwise report success over different data: the
    // caller knows what it sent, the handler knows what it read, and until here
    // nothing compares the two — which is why a consumer's upload could
    // acknowledge 16 of 17 messages with no error anywhere.
    //
    // Reported, never raised: by this point the call has answered and there is
    // no one left to fail. What it buys is that the next occurrence is one grep
    // away instead of unfalsifiable.
    final lost = state.acceptedRequests - state.deliveredRequests;
    if (lost > 0) {
      _log.error(
        'Request messages LOST for ${state.methodKey ?? "?"} '
        '[streamId: $streamId]: the pipeline accepted '
        '${state.acceptedRequests} and the handler was given '
        '${state.deliveredRequests} — $lost never arrived '
        '(dropped: ${state.droppedRequests})',
      );
    }
    // A stream torn down while still holding pre-method frames must return its
    // share of the connection budget, or the ceiling ratchets down over time.
    _releasePreMethodBytes(state);
    // Same for the handler-side buffers, against the connection ceiling.
    state.releaseBuffered();
    state.cancelDeadline();
    // End the client-stream request feed first: a handler parked in
    // `await for (requests)` has to be released before its responder is closed.
    state.closeRequestSink();

    final responder = state.responder;
    if (responder != null) await _closeResponder(responder);

    // Dispose the per-call scope: runs any handler-registered cleanup. Idempotent
    // (it may have already self-closed on cancellation/deadline).
    final callScope = state.cachedContext?.getValue<RpcCallScope>(RpcCallScope);
    if (callScope != null) await callScope.close();

    try {
      transport.releaseStreamId(streamId);
    } catch (error) {
      _log.warning('Error releasing stream ID $streamId: $error');
    }
  }

  Future<void> _closeResponder(IRpcResponder responder) async {
    try {
      await responder.close();
    } catch (error, stackTrace) {
      _log.error(
        'Error closing responder [id: ${responder.id}]',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// [_pipelineFedRequestStream] for a server-stream or bidi responder, seeded
  /// with what arrived before it was bound.
  Stream<RpcTransportMessage> _pipelineFedPreBound(
    RpcResponderStreamState state,
  ) => _pipelineFedRequestStream(
    state,
    initialMessages: state.takePreBindBufferedMessages(),
  );

  /// Request stream for a streaming responder, fed by this pipeline.
  ///
  /// Unlike [_stateBoundStream] this does NOT subscribe to
  /// `transport.getMessagesForStream`. A streaming responder is bound on the
  /// call's first request frame and then consumes for the rest of the call, so
  /// it would depend on that per-stream view carrying every LATER frame -- and
  /// the default implementation in [IRpcTransport] is a plain `where` over the
  /// non-replaying broadcast, which drops whatever the transport dispatched
  /// before the subscription existed. `RpcChannelTransport` routes a frame to
  /// the per-stream view only if the view exists when the frame is dispatched,
  /// so one async hop between it and this pipeline loses the next request: a
  /// decorator that re-broadcasts `incomingMessages` asynchronously did exactly
  /// that to every bidi call a peer client was sent. The pipeline already
  /// observes every frame, so it forwards them itself.
  Stream<RpcTransportMessage> _pipelineFedRequestStream(
    RpcResponderStreamState state, {
    required Iterable<RpcTransportMessage> initialMessages,
  }) {
    final controller = StreamController<RpcTransportMessage>();
    state.attachRequestSink(controller, budget: _respBudget);

    // Take over flow-control metering for this stream. The transport meters
    // what it hands out through getMessagesForStream, and this responder is fed
    // by the pipeline instead, so the transport would otherwise have to credit
    // on arrival -- which left the client-stream upload direction unbounded.
    // Claiming it here obliges us to credit on consumption below.
    final transport = this.transport;
    final flowControlled = transport is IRpcFlowControlled
        ? transport as IRpcFlowControlled
        : null;
    flowControlled?.deferFlowCredit(state.id);

    // Everything that arrived before this point was credited on arrival, while
    // the stream was not yet deferred. Those must not be credited again as the
    // handler takes them, and until it does the peer believes them consumed,
    // so the depth bound allows for them.
    final initial = initialMessages.toList(growable: false);
    state.markPreCredited(
      initial.where((m) => m.payload != null || m.isDirect).length,
    );
    for (final message in initial) {
      state.pushRequest(message);
    }
    // The peer may have half-closed before the responder was bound -- always
    // the case for a call that carried no messages at all, which is legal.
    if (state.clientEnded) state.endRequests();

    controller.onCancel = () => state.detachRequestSink();
    // `map` is lazy, so a handler that stops consuming stops credit reaching
    // the peer -- the same property the transport's own metering relies on.
    return controller.stream.map((message) {
      state.releaseRequest(message);
      if ((message.payload != null || message.isDirect) &&
          !state.takePreCredited()) {
        flowControlled?.returnFlowCredit(
          state.id,
          message.payload?.length ?? 0,
        );
      }
      return message;
    });
  }

  Stream<RpcTransportMessage> _stateBoundStream(
    RpcResponderStreamState state,
    int streamId, {
    Iterable<RpcTransportMessage> initialMessages =
        const <RpcTransportMessage>[],
    bool consumePreBindBuffer = false,
  }) {
    final controller = StreamController<RpcTransportMessage>();
    late final StreamSubscription<RpcTransportMessage> subscription;

    subscription = transport
        .getMessagesForStream(streamId)
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: () => unawaited(controller.close()),
        );

    subscription.pause();
    state.markBoundToMessageStream();

    final merged = <RpcTransportMessage>[
      if (consumePreBindBuffer) ...state.takePreBindBufferedMessages(),
      ...initialMessages,
    ];

    // Replay the peer's half-close when it happened BEFORE this bind. The
    // transport subscription above only carries frames from now on, so a
    // responder created at end-of-stream -- which is exactly when a stream
    // that carried zero request messages starts -- would never learn the peer
    // had finished, and the handler's `await for (requests)` would wait
    // forever on a client that was already done.
    if (state.clientEnded && !merged.any((m) => m.isEndOfStream)) {
      merged.add(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
    }

    for (final message in merged) {
      controller.add(message);
    }

    subscription.resume();
    controller.onCancel = () async => subscription.cancel();
    // Pass the responder's demand down to the transport, so a handler that
    // stops consuming stops the metered per-stream stream being drained --
    // which is what withholds flow-control credit from the peer.
    controller.onPause = () => subscription.pause();
    controller.onResume = () => subscription.resume();

    return controller.stream;
  }
}
