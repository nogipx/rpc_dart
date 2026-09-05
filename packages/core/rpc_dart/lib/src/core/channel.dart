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
/// Implementors only need ~50 lines of code:
///
/// ```dart
/// class WebSocketChannel implements IRpcChannel {
///   final WebSocket _ws;
///   final _ctl = StreamController<Uint8List>();
///   bool _closed = false;
///
///   WebSocketChannel(this._ws) {
///     _ws.listen(
///       (data) => _ctl.add(data is Uint8List ? data : Uint8List.fromList(data)),
///       onDone: () { _closed = true; _ctl.close(); },
///     );
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
  Stream<Uint8List> get incoming;

  /// Close the channel and release all resources.
  Future<void> close();
}

/// Optional capability: a channel whose underlying protocol can say WHY it is
/// hanging up.
///
/// Implemented by transports with a close code on the wire — WebSocket is the
/// one that matters. A channel without it is closed the ordinary way, so this
/// is opt-in and adding it breaks no existing implementer (every one of them
/// uses `implements IRpcChannel`, so a new member on that interface would).
///
/// Why it exists: a frame-level protocol violation is DETERMINISTIC. The peer
/// sent something malformed and will send it again if told to retry. When the
/// channel is torn down without saying so, a WebSocket peer sees close code
/// 1005 "no status received", which maps to UNAVAILABLE — retryable. Measured
/// against an rpc_dart server, with a client whose frame declared a payload
/// past the policy:
///
///     server shutdown           : closeCode=1005 -> UNAVAILABLE (retryable)  correct
///     client protocol violation : closeCode=1005 -> UNAVAILABLE (retryable)  WRONG
///
/// The first is right — a client should reconnect past a restart. The second
/// invites the client to repeat the frame that just got it disconnected.
abstract class IRpcChannelProtocolClose {
  /// Closes the channel, telling the peer this was a protocol violation.
  ///
  /// [reason] is for a human reading a log; it must not be relied on
  /// programmatically, and WebSocket caps it at 123 bytes.
  Future<void> closeForProtocolError(String reason);
}
