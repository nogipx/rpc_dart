// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'channel_transport.dart';

extension _ChannelTransportFlow on RpcChannelTransport {
  /// Charges [message] against the per-stream buffer bound; false means it must
  /// not be queued.
  ///
  /// Fails THE STREAM, not the connection. A peer flooding one call must not
  /// take down the others sharing the socket — the same reasoning as
  /// `closeOnOversizedFrame: !isClient` in [RpcChannelTransport.fromChannel],
  /// and the reason this is not routed through `closeOnProtocolError`.
  bool _admitToStreamBuffer(
    RpcTransportMessage message,
    StreamController<RpcTransportMessage> ctl,
  ) {
    final streamId = message.streamId;
    final admission = _buffers.admit(
      streamId,
      message.bufferedBytes,
      events: RpcFlowController.carriesMessage(message) ? 1 : 0,
    );
    switch (admission) {
      case RpcBufferAdmission.admitted:
        return true;
      case RpcBufferAdmission.refused:
        return false;
      case RpcBufferAdmission.overflowed:
      case RpcBufferAdmission.overflowedConnection:
        // WHICH ceiling, because there are three and they bound different
        // things: a zero-copy payload weighs 0 bytes, so a message-count
        // overflow reported as a byte overflow names a number the stream never
        // approached.
        final byCount =
            _buffers.eventsFor(streamId) >= _buffers.limitEvents ||
            message.bufferedBytes == 0;
        final reason = admission == RpcBufferAdmission.overflowedConnection
            ? 'past the connection total of ${_buffers.limitTotalBytes} '
                  'bytes un-consumed'
            : byCount
            ? 'more than ${_buffers.limitEvents} un-consumed messages'
            : 'more than ${_buffers.limitBytes} bytes un-consumed';
        // The consumer gets the error; without this the OPERATOR gets nothing,
        // which is what the http2 responder already avoids for its own version
        // of this bound.
        _log.warning('Stream $streamId buffered $reason; failing the stream');
        ctl.addError(
          RpcStatusException(
            RpcStatus.resourceExhausted,
            'Stream $streamId buffered $reason without being consumed',
          ),
        );
        return false;
    }
  }

  /// Releases both charges as each message is handed to the consumer.
  ///
  /// `map` is lazy: a paused consumer pauses this subscription too, so nothing
  /// is released while messages sit in the controller's buffer. That is what
  /// carries the consumer's pause all the way to the remote producer.
  ///
  /// Two mechanisms, released together because they are charged together and
  /// nowhere else — the buffer ledger unconditionally, since its bound applies
  /// whether or not flow control is on, and the window only when there is one.
  Stream<RpcTransportMessage> _metered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) {
    if (!_fc.enabled) {
      return source.map((message) {
        _release(streamId, message);
        return message;
      });
    }
    return source.map((message) {
      _release(streamId, message);
      _fc.onConsumed(streamId, message);
      return message;
    });
  }

  void _release(int streamId, RpcTransportMessage message) {
    _buffers.release(
      streamId,
      message.bufferedBytes,
      events: RpcFlowController.carriesMessage(message) ? 1 : 0,
    );
  }

  /// Whether anything still tracks [streamId] as a live call.
  ///
  /// A stream this side opened is in [_activeStreams] until it is released; one
  /// the PEER opened is known to the controller from the first frame we saw of
  /// it, since that is where the window is advertised; either kind has a
  /// per-stream controller while a consumer is bound. "None of them" means the
  /// call is over, and a late grant for it must not resurrect its credit.
  bool _isStreamLive(int streamId) =>
      _activeStreams.contains(streamId) ||
      _streamControllers.containsKey(streamId) ||
      _fc.isAdvertised(streamId);

  /// Drops BOTH per-stream ledgers for a finished stream.
  ///
  /// Two mechanisms, dropped at the same moment because both are keyed on the
  /// PEER's stream id and both become unreachable when the call ends.
  void _forgetStream(int streamId) {
    _fc.forget(streamId);
    _buffers.forget(streamId);
  }
}
