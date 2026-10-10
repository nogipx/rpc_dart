// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

extension _Http2CallerFlow on RpcHttp2CallerTransport {
  /// How much un-consumed RESPONSE payload one call may hold; the responder's
  /// `_fcWindow` bounds the request direction with the same number.
  int get _fcWindow => unconsumedWindowFor(_policy);

  /// Bounds a response a consumer has stopped reading.
  ///
  /// This used to be a demand hop -- `onPause`/`onResume` forwarding to the
  /// http2 subscription -- because on HTTP/2 the lever that slows a server is
  /// the h2 window, which only closes if we stop READING. Without any bound at
  /// all a paused client never slowed the server down: measured with a
  /// server-stream handler and a client that paused after 5 items, the handler
  /// produced 33906 more (132.4 MiB) in 4 s and was still climbing, against
  /// 1023 (4.0 MiB, flat) over websocket.
  ///
  /// But pausing parks bytes in package:http2's connection-level queue, and a
  /// reset then discards them without crediting the connection window -- so
  /// cancelling a paused download killed the whole connection, measured, in
  /// exactly the way it did on the responder side. See the responder's
  /// `_fcWindow` for the mechanism and the numbers.
  ///
  /// So the budget is kept and the CALL is failed past it, while reading never
  /// stops. `map` is lazy, so a consumer that stops pulling stops discharging.
  Stream<RpcTransportMessage> _fcMetered(
    int streamId,
    Stream<RpcTransportMessage> source,
  ) => source.map((message) {
    _fcDischarge(streamId, message.payload?.length ?? 0);
    return message;
  });

  void _fcDischarge(int streamId, int bytes) {
    if (bytes <= 0) return;
    final left = (_fcOutstanding[streamId] ?? 0) - bytes;
    if (left <= 0) {
      _fcOutstanding.remove(streamId);
    } else {
      _fcOutstanding[streamId] = left;
    }
  }

  void _fcOnDelivered(int streamId, int bytes) {
    if (bytes <= 0 || !_streams.contains(streamId)) return;
    final before = _fcOutstanding[streamId] ?? 0;
    final now = before + bytes;
    _fcOutstanding[streamId] = now;
    // Past the window by what was ALREADY waiting, not by the message that
    // just arrived: one message is delivered whole and cannot be consumed
    // before it is here, so counting it refused every response message
    // larger than the window -- 4 MiB by default, against a 16 MiB message
    // limit -- from a caller reading as fast as it could.
    if (before <= _fcWindow || !_fcRefused.add(streamId)) return;
    _logger?.warning(
      'Stream $streamId holds $now un-consumed response bytes '
      '(window: $_fcWindow); failing the call',
    );
    // Order matters: the error goes out FIRST, because resetStream records the
    // id in _resetStreams and _emitStreamError deliberately suppresses errors
    // for a stream we reset ourselves.
    _emitStreamError(
      streamId,
      RpcStatusException(
        RpcStatus.resourceExhausted,
        'Response exceeds the un-consumed window ($now > $_fcWindow bytes)',
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

  void _fcForget(int streamId) {
    _fcOutstanding.remove(streamId);
    _fcRefused.remove(streamId);
  }
}
