// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Raw bidirectional byte channel -- the minimal transport primitive.
///
/// Transports that move bytes over a single connection (WebSocket, raw TCP,
/// Unix socket, QUIC, etc.) implement this interface. The framework wraps it
/// with [RpcChannelTransport] which adds stream-ID multiplexing, metadata
/// encoding, and the full [IRpcTransport] contract automatically.
///
/// Extend it to get the default [closeFor]; a class that implements it
/// writes every member. Implementors only need ~50 lines of code:
///
/// ```dart
/// class WebSocketChannel extends IRpcChannel {
///   final WebSocket _ws;
///   final _ctl = StreamController<Uint8List>();
///   late final StreamSubscription<dynamic> _sub;
///   bool _closed = false;
///
///   WebSocketChannel(this._ws) {
///     _sub = _ws.listen(
///       (data) => _ctl.add(data is Uint8List ? data : Uint8List.fromList(data)),
///       onDone: () { _closed = true; _ctl.close(); },
///     );
///     // Forward a consumer's pause to the socket, or a paused `incoming`
///     // still reads every chunk off the wire into `_ctl`.
///     _ctl
///       ..onPause = _sub.pause
///       ..onResume = _sub.resume;
///   }
///
///   @override bool get isClosed => _closed;
///   @override Stream<Uint8List> get incoming => _ctl.stream;
///   @override Future<void> send(Uint8List data) async => _ws.add(data);
///   @override Future<void> close() async { _closed = true; await _ws.close(); await _ctl.close(); }
/// }
/// ```
abstract class IRpcChannel {
  /// Whether the channel has been closed.
  bool get isClosed;

  /// Send a raw frame to the remote side.
  Future<void> send(Uint8List data);

  /// Incoming raw frames from the remote side.
  ///
  /// The stream completes when the channel is closed (locally or remotely).
  ///
  /// Pausing it should pause the reads underneath, as the example above does.
  /// rpc_dart's own stack never pauses it; a caller holding the channel
  /// directly may.
  ///
  /// **A delivered chunk is handed over, not lent.** An implementation must not
  /// write into a `Uint8List` it has already added to this stream, and must not
  /// reuse one as scratch for the next chunk — emit a fresh list each time.
  /// `RpcFrameMultiplexedChannel` decodes straight out of the chunk when nothing
  /// is buffered, so a decoded message's payload can be a view into it and can
  /// outlive the `add`.
  Stream<Uint8List> get incoming;

  /// Close the channel and release all resources.
  Future<void> close();

  /// Closes the channel because the peer broke a rule, telling the peer why
  /// where the protocol underneath can say so.
  ///
  /// The default closes the ordinary way. A channel whose protocol carries a
  /// reason -- WebSocket's close code -- or that must close in a particular
  /// way for the peer to read the answer already sent overrides it for the
  /// reasons it can serve and falls back to [close] for the rest.
  ///
  /// A wrapper around another channel forwards this, or the reason is lost
  /// at the wrapper.
  Future<void> closeFor(RpcChannelCloseReason reason) => close();
}

/// Why a channel is closing on the peer's account; see
/// [IRpcChannel.closeFor].
///
/// Both reasons are deterministic: the peer will repeat the message if it
/// reads the close as transient. Closed without saying so, a WebSocket peer
/// sees close code 1005 "no status received", which maps to UNAVAILABLE and is
/// retried.
sealed class RpcChannelCloseReason {
  const RpcChannelCloseReason(this.message);

  /// For a human reading a log; nothing may key off it. WebSocket caps a close
  /// reason at 123 bytes.
  final String message;
}

/// The peer sent something malformed or broke the security policy.
final class RpcCloseForProtocolError extends RpcChannelCloseReason {
  /// A protocol violation described by [message].
  const RpcCloseForProtocolError(super.message);
}

/// The peer's message was larger than the policy allows.
///
/// Not a framing violation: the peer can correct it by sending less, and http1
/// and http2 answer the same request with RESOURCE_EXHAUSTED, so a channel
/// that closes for it lets the peer's caller say the same.
final class RpcCloseForOversize extends RpcChannelCloseReason {
  /// An oversized message described by [message].
  const RpcCloseForOversize(super.message);
}
