// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_responder_transport.dart';

/// Bounds a request a handler has stopped consuming, through [_fc].
///
/// `flowControlWindowBytes` is the operator's existing knob for exactly this
/// question. HTTP/2 carries its own windows, so this is not used to emit
/// rpc-level grants; it is the threshold past which the CALL is refused.
///
/// Do NOT make it the threshold at which reading stops — the obvious lever,
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
///
/// Both consumers report back. Client-stream requests are fed by
/// `_pipelineFedRequestStream`, which reports consumption through
/// [IRpcFlowCredit]; bidirectional and server-stream ones are fed by
/// `_stateBoundStream`, which subscribes to [getMessagesForStream] and never
/// calls deferFlowCredit, so that view discharges as it is read. Without it
/// the bidi upload direction would be unbounded while client-stream is
/// bounded.
extension _Http2ResponderFlow on RpcHttp2ResponderTransport {
  /// Ends a call whose consumer has stopped taking its request.
  void _fcRefuseOverrun(int streamId, int outstanding) {
    _log.warning(
      'Stream $streamId holds $outstanding un-consumed request bytes '
      '(window: ${_fc.window}); refusing the call',
    );
    // The status goes out FIRST, through the same pump as everything else, so
    // it is ordered ahead of the END_STREAM that teardown sends.
    unawaited(
      sendMetadata(
        streamId,
        RpcTrailers.status(
          RpcStatus.resourceExhausted,
          message:
              'Request exceeds the un-consumed window '
              '($outstanding > ${_fc.window} bytes)',
          maxMessageLength: _policy.maxHeaderValueBytes,
        ),
        endStream: true,
      ).catchError((Object _) {}),
    );
    // Then tear the local call down through the same synthesized frame the
    // RST_STREAM path uses, so the handler stops rather than serving nobody.
    // Carries no payload, so it cannot re-enter the ledger's charge.
    _emit(
      RpcTransportMessage.withMetadata(
        streamId: streamId,
        metadata: RpcTrailers.cancelled('un-consumed request window exceeded'),
      ),
    );
  }
}
