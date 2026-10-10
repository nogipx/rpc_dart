// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

extension _ResponderPipelineAdmission on RpcResponderPipelineMixin {
  /// Releases [streamId]'s slot once nothing is left to wait for.
  ///
  /// Called from both ends of the call's life -- stream teardown and handler
  /// completion -- because either can come first, and the slot must survive
  /// until the LATER of the two. Idempotent: whichever arrives second finds the
  /// id already gone.
  void _releaseHandlerSlot(int streamId) {
    if (_respHandlerLive.contains(streamId)) return;
    _respSlotHeld.remove(streamId);
  }

  /// Runs [work] as [streamId]'s server-side work, keeping its slot charged
  /// throughout.
  ///
  /// **Charged at DISPATCH, not here**, or a simultaneous burst walks through:
  /// nothing is running yet when the batch is admitted. What this adds is the
  /// other end — the slot is returned when the WORK ends, not when the stream
  /// is torn down.
  ///
  /// **Wrapped around the whole middleware+interceptor+handler chain**, not the
  /// user handler alone: an interceptor parked on either side of `next()` is
  /// work outside the handler, and releasing it with the stream reproduces the
  /// exact defect this limit exists for, one layer out.
  Future<T> _withHandlerSlot<T>(int streamId, Future<T> Function() work) async {
    if (_respMaxHandlers == null) return work();
    _respHandlerLive.add(streamId);
    try {
      return await work();
    } finally {
      _respHandlerLive.remove(streamId);
      _releaseHandlerSlot(streamId);
    }
  }

  /// Same, for a handler whose work is a response stream: the slot is held
  /// until that stream completes, errors, or its consumer cancels.
  Stream<T> _withHandlerSlotStream<T>(int streamId, Stream<T> Function() work) {
    if (_respMaxHandlers == null) return work();
    // A generator, so its finally runs on cancellation as well as completion.
    return () async* {
      _respHandlerLive.add(streamId);
      try {
        yield* work();
      } finally {
        _respHandlerLive.remove(streamId);
        _releaseHandlerSlot(streamId);
      }
    }();
  }

  void _releasePreMethodBytes(RpcResponderStreamState state) {
    final parked = state.preMethodBufferedBytes;
    if (parked <= 0) return;
    _respPreMethodBytes -= parked;
    if (_respPreMethodBytes < 0) _respPreMethodBytes = 0;
  }

  /// Bounds how long [state] may sit half-open before its slot is reclaimed.
  ///
  /// Half-open means dispatched-not-yet, and the peer's optional `grpc-timeout`
  /// was the only other bound on it — which an attacker omits.
  ///
  /// **Armed once per stream and cancelled at dispatch**, so a running handler
  /// is never affected however long it lives. That is also the limit: one
  /// request frame gets the handler dispatched and then waiting forever on a
  /// request stream that never half-closes, parking the same state for ~30
  /// extra bytes. See [RpcSecurityPolicy.halfOpenStreamTimeout].
  void _armHalfOpenReclaim(RpcResponderStreamState state) {
    if (state.responder != null) return;
    final timeout = _respHalfOpenTimeout;
    if (timeout == null) return;
    state.armHalfOpen(timeout, () {
      // Dispatched in the meantime: nothing to reclaim.
      if (state.responder != null) return;
      // Identity, not presence: across a reconnect the id can already name a
      // different call, and reclaiming that one answers it DEADLINE_EXCEEDED for
      // a deadline it never had. See [_cleanupStream]'s `only`.
      if (!identical(_respStreams[state.id], state)) return;
      if (!_warnedHalfOpen) {
        _warnedHalfOpen = true;
        _log.warning(
          'Reclaiming stream ${state.id}: half-open for '
          '${timeout.inMilliseconds}ms without a request message',
        );
      }
      _detached(
        _sendGrpcErrorAndCleanup(
          streamId: state.id,
          status: RpcStatus.deadlineExceeded,
          message:
              'Stream was half-open for ${timeout.inMilliseconds}ms without '
              'a request message',
          context: state.cachedContext,
        ),
        'grpc error cleanup',
      );
    });
  }
}
