// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

/// Bounds a response a consumer has stopped reading, through [_fc].
///
/// On HTTP/2 the lever that slows a server is the h2 window, which only
/// closes if we stop READING. But pausing parks bytes in package:http2's
/// connection-level queue, and a reset then discards them without crediting
/// the connection window -- so cancelling a paused download would kill the
/// whole connection, in exactly the way it does on the responder side. See the
/// responder's `_fc` for the mechanism.
///
/// So the budget is kept and the CALL is failed past it, while reading never
/// stops. The window is the same number the responder bounds the request
/// direction with.
extension _Http2CallerFlow on RpcHttp2CallerTransport {
  /// Fails a call whose consumer holds [outstanding] response bytes past the
  /// window.
  void _fcFailOverrun(int streamId, int outstanding) {
    _logger?.warning(
      'Stream $streamId holds $outstanding un-consumed response bytes '
      '(window: ${_fc.window}); failing the call',
    );
    // Order matters: the error goes out FIRST, because resetStream records the
    // id in _resetStreams and _emitStreamError deliberately suppresses errors
    // for a stream we reset ourselves.
    _emitStreamError(
      streamId,
      RpcStatusException(
        RpcStatus.resourceExhausted,
        'Response exceeds the un-consumed window '
        '($outstanding > ${_fc.window} bytes)',
      ),
    );
    // Then RST_STREAM, or the server never learns and keeps producing for a
    // consumer that is gone -- the same trap the responder's `onTerminated`
    // comment records from the other side.
    unawaited(
      resetStream(
        streamId,
        reason: 'un-consumed response window exceeded',
      ).catchError((Object _) => false),
    );
  }

  /// Stops a response whose call this side has already failed. Without the
  /// reset its body -- typically a proxy's HTML page -- keeps downloading and
  /// every DATA frame is fed to the gRPC parser, one ERROR per frame.
  ///
  /// Call AFTER reporting the failure: [resetStream] suppresses later errors.
  void _dropFailedResponse(int streamId) {
    unawaited(
      resetStream(
        streamId,
        reason: 'the call has already failed',
      ).catchError((Object _) => false),
    );
  }
}
