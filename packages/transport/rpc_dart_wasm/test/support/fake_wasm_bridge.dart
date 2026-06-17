// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

/// In-memory [RpcWasmBridge] that loops byte frames to a paired peer.
///
/// This is the test double for the real JS/WASM sandbox bridge: it is
/// byte-only and forwards each [send] to the peer's [incoming] stream, exactly
/// like the native host pipes bytes between the Dart side and the sandbox.
final class FakeWasmBridge implements RpcWasmBridge {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
  late final FakeWasmBridge _peer;
  bool _closed = false;

  /// Frames this bridge has been asked to send, in order. Useful for asserting
  /// framing/ordering without a real runtime.
  final List<Uint8List> sent = [];

  static ({FakeWasmBridge client, FakeWasmBridge server}) pair() {
    final client = FakeWasmBridge();
    final server = FakeWasmBridge();
    client._peer = server;
    server._peer = client;
    return (client: client, server: server);
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List data) async {
    sent.add(data);
    if (_closed || _peer._incoming.isClosed) return;
    _peer._incoming.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}
