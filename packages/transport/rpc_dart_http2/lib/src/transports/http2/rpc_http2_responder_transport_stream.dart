// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_responder_transport.dart';

/// Everything the responder keeps for one client-initiated stream, from its
/// arrival until `releaseStreamId` or `close` removes the record.
final class _ResponderStream {
  _ResponderStream(this.incoming, this._parsers);

  /// The client's stream, which the response goes out on. Kept after the
  /// request ends, because the response still has to be sent.
  final http2.ServerTransportStream incoming;

  /// Counts the records holding a parser, for the parser ceiling.
  final _ParserTally _parsers;

  /// The backpressured writer, created on first send. See [_OutgoingPump].
  _OutgoingPump? pump;

  /// The request's incoming messages, until the request ends.
  StreamSubscription<void>? subscription;

  /// The frame parser, which carries the state for a fragmented message.
  RpcMessageParser? get parser => _parser;
  RpcMessageParser? _parser;
  set parser(RpcMessageParser? value) {
    if ((value == null) != (_parser == null)) {
      _parsers.count += value == null ? -1 : 1;
    }
    _parser = value;
  }

  /// The initial response headers have gone out, which is what distinguishes
  /// trailers (no `:status`) from Trailers-Only (`:status` plus
  /// `grpc-status`).
  bool initialHeadersSent = false;

  /// This transport refused the request, so its end must not reach the
  /// handler as a clean one before the refusal's cancel does.
  bool requestRefused = false;

  /// This call's share of the un-consumed request window.
  final Http2FlowAccount flow = Http2FlowAccount();

  /// Cancels the subscription and forgets the parser. Returns the cancel.
  ///
  /// The pump and [incoming] are left to the caller: a teardown ends the
  /// stream through the pump, and how it falls back differs by path.
  Future<void>? dispose() {
    final cancelling = subscription?.cancel();
    subscription = null;
    parser = null;
    return cancelling;
  }
}

/// How many records hold a parser.
final class _ParserTally {
  int count = 0;
}
