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
