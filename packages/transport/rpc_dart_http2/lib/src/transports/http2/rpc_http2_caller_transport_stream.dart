// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

/// How many calls hold a reservation and a parser, kept by [_CallerStream] so
/// the two ceilings read a count rather than walk every call.
final class _CallerTally {
  int reserved = 0;
  int parsers = 0;
}

/// Everything the caller keeps for one stream id.
///
/// One record per id, from [RpcHttp2CallerTransport.createStream] (or the
/// opening [RpcHttp2CallerTransport.sendMetadata] of an id that was never
/// created) until a teardown leaves nothing in it. A teardown clears the parts
/// it owns and drops the record once [isSpent].
final class _CallerStream {
  _CallerStream(this._tally);

  final _CallerTally _tally;

  /// The HTTP/2 stream, from the opening frame until it ends or is reset.
  http2.ClientTransportStream? h2;

  /// The backpressured writer for the request's DATA, created on first send.
  ///
  /// `sendData` enqueues regardless of the server's window, so without a pump
  /// a server whose handler stops consuming does not slow this client down at
  /// all: the whole request is pulled into package:http2's outgoing queue, in
  /// this process's memory, while a fraction of it is on the wire.
  ///
  /// Unlike the responder there is no header/data ordering to preserve here:
  /// HEADERS go out with `makeRequest`, so this sink only ever carries DATA.
  RpcHttp2OutgoingPump? pump;

  StreamSubscription<void>? subscription;

  /// The frame parser, which carries the state for a fragmented message.
  RpcMessageParser? get parser => _parser;
  RpcMessageParser? _parser;
  set parser(RpcMessageParser? value) {
    if ((value == null) != (_parser == null)) {
      _tally.parsers += value == null ? -1 : 1;
    }
    _parser = value;
  }

  /// The id was handed out by `createStream` and not retired yet.
  ///
  /// [h2] is only set once `sendMetadata` opens the HTTP/2 stream, so counting
  /// it cannot bound stream CREATION: a burst of createStream() calls all pass
  /// before the first reaches sendMetadata. This is what `createStream`
  /// counts.
  bool get reserved => _reserved;
  bool _reserved = false;
  set reserved(bool value) {
    if (value != _reserved) _tally.reserved += value ? 1 : -1;
    _reserved = value;
  }

  /// This side has half-closed the stream by sending END_STREAM.
  ///
  /// HTTP/2 forbids a DATA frame on a stream that is half-closed (local), and
  /// package:http2 answers that violation by tearing down the whole CONNECTION
  /// -- not just the stream. Every path that ends the request direction sets
  /// this so no later path sends a second one.
  bool halfClosedLocal = false;

  /// The peer ended the stream while the id is still held: a send on it is
  /// dropped, not refused. Cleared by `releaseStreamId`.
  bool peerEnded = false;

  /// The response carried a gRPC status (trailers, or a Trailers-Only
  /// response).
  ///
  /// package:http2 completes a stream's `incomingMessages` NORMALLY when the
  /// connection goes away mid-response, so `onDone` alone cannot tell a
  /// finished call from a truncated one.
  bool statusReceived = false;

  /// The initial response headers have arrived, which is what tells trailers
  /// from initial headers on the way in.
  bool initialHeadersReceived = false;

  /// This call's share of the un-consumed response window.
  final Http2FlowAccount flow = Http2FlowAccount();

  /// Nothing is left: the record can go.
  bool get isSpent =>
      h2 == null &&
      pump == null &&
      subscription == null &&
      !peerEnded &&
      !_hasExchange &&
      flow.isClear;

  bool get _hasExchange =>
      _parser != null ||
      _reserved ||
      halfClosedLocal ||
      statusReceived ||
      initialHeadersReceived;

  /// Forgets the exchange: the parser, the reservation, the half-close and the
  /// response's progress. What every teardown clears.
  void endExchange() {
    parser = null;
    initialHeadersReceived = false;
    halfClosedLocal = false;
    reserved = false;
    statusReceived = false;
  }

  /// Releases the pump, waking anything parked on the server's window, cancels
  /// the subscription and forgets the exchange; [h2] is dropped without a
  /// frame. Returns the cancel.
  ///
  /// Leaves [peerEnded] and [flow], whose lifetimes differ by path.
  Future<void>? dispose() {
    h2 = null;
    pump?.dispose();
    pump = null;
    final cancelling = subscription?.cancel();
    subscription = null;
    endExchange();
    return cancelling;
  }
}
