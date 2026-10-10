// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_responder_transport.dart';

extension _Http2ResponderFlow on RpcHttp2ResponderTransport {
  /// How much un-consumed request payload one stream may hold.
  ///
  /// `flowControlWindowBytes` is the operator's existing knob for exactly this
  /// question. HTTP/2 carries its own windows, so this is not used to emit
  /// rpc-level grants; it is the threshold past which the CALL is refused.
  ///
  /// Do NOT make this the threshold at which reading stops — the obvious lever,
  /// and it makes every cancelled slow call destroy the CONNECTION.
  /// package:http2 credits the connection window only for messages it can move
  /// into a stream's queue, and it will not move them while that stream's
  /// consumer is paused, so a stalled call parks up to a whole connection
  /// window in `_stream2pendingMessages`; reset that stream and
  /// `_closeStreamAbnormally` drops the queue without ever calling
  /// `dataProcessed`, so no WINDOW_UPDATE is emitted for bytes the peer was
  /// charged for. One cancel exhausts the default 68 KiB connection window and
  /// every later call on it hangs.
  ///
  /// Refusing instead keeps reading, so the pool always flows, and bounds
  /// memory by ending the offending call. The cost, accepted by the owner: a
  /// handler that stops consuming kills its own call instead of being
  /// throttled.
  int get _fcWindow => unconsumedWindowFor(_policy);

  void _fcDischarge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final left = (_fcOutstanding[streamId] ?? 0) - bytes;
    if (left <= 0) {
      _fcOutstanding.remove(streamId);
    } else {
      _fcOutstanding[streamId] = left;
    }
  }

  /// Charges [bytes] against [streamId]'s budget and refuses the call past it.
  ///
  /// Only for a stream whose consumer reports back — the pipeline through
  /// [returnFlowCredit], or a [getMessagesForStream] view through [_fcMetered].
  /// Charging anything else would never discharge, and a single unary request
  /// larger than the window would refuse itself.
  void _fcOnDelivered(int streamId, int bytes) {
    if (bytes <= 0) return;
    if (!_fcDeferred.contains(streamId) && !_streams.contains(streamId)) {
      return;
    }
    final before = _fcOutstanding[streamId] ?? 0;
    final now = before + bytes;
    _fcOutstanding[streamId] = now;
    // By what was already waiting: a message is delivered whole, so counting
    // the one that just arrived refused every request message larger than
    // the window from a handler reading as fast as it could. See the
    // caller's _fcOnDelivered.
    if (before > _fcWindow) _fcRefuseOverrun(streamId, now);
  }

  /// Ends a call whose consumer has stopped taking its request.
  void _fcRefuseOverrun(int streamId, int outstanding) {
    if (!_fcRefused.add(streamId)) return;
    _logger?.warning(
      'Stream $streamId holds $outstanding un-consumed request bytes '
      '(window: $_fcWindow); refusing the call',
    );
    // The status goes out FIRST, through the same pump as everything else, so
    // it is ordered ahead of the END_STREAM that teardown sends.
    unawaited(
      sendMetadata(
        streamId,
        RpcMetadata.forTrailer(
          RpcStatus.resourceExhausted,
          message:
              'Request exceeds the un-consumed window '
              '($outstanding > $_fcWindow bytes)',
          maxMessageLength: _policy.maxHeaderValueBytes,
        ),
        endStream: true,
      ).catchError((Object _) {}),
    );
    // Then tear the local call down through the same synthesized frame the
    // RST_STREAM path uses, so the handler stops rather than serving nobody.
    // Carries no payload, so it cannot re-enter _fcOnDelivered.
    _emit(
      RpcTransportMessage.withMetadata(
        streamId: streamId,
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xClientCancelled, 'true'),
          RpcHeader(
            RpcHeaders.xCancellationReason,
            'un-consumed request window exceeded',
          ),
        ]),
      ),
    );
  }

  void _fcForget(int streamId) {
    _fcDeferred.remove(streamId);
    _fcOutstanding.remove(streamId);
    _fcRefused.remove(streamId);
  }

  /// The OTHER half of the request-direction bound. Client-stream requests are
  /// fed by `_pipelineFedRequestStream`, which reports consumption through
  /// [IRpcFlowControlled]; bidirectional and server-stream ones are fed by
  /// `_stateBoundStream`, which subscribes HERE and never calls
  /// deferFlowCredit. Without a report from this side the bidi upload direction
  /// is unbounded even while client-stream is already bounded.
  ///
  /// `map` is lazy, so a consumer that stops pulling stops discharging, which
  /// is what lets the budget fill and the call be refused.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) => source.map((message) {
    _fcDischarge(streamId, message.payload?.length ?? 0);
    return message;
  });
}
