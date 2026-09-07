// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

/// In-memory [RpcWasmBridge] that loops byte frames to a paired peer.
///
/// This is the test double for the real JS/WASM sandbox bridge: it is
/// byte-only and forwards each [send] to the peer's [incoming] stream, exactly
/// like the native host pipes bytes between the Dart side and the sandbox.
final class FakeWasmBridge implements RpcWasmBridge {
  /// Mirrors the real bridges: SINGLE-SUBSCRIPTION, so it BUFFERS whatever
  /// arrives before the transport binds.
  ///
  /// This was broadcast, like the real ones, and that is why no test could see
  /// the defect: a broadcast controller drops frames sent before anyone
  /// listens, and both real bridges start receiving in their constructor while
  /// the subscriber appears only when the transport is built. A test double
  /// that shares the production shape is what makes the difference visible.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: true,
  );
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
    // NOT awaited, for the same reason the real bridges do not: closing a
    // never-listened single-subscription controller hangs until someone
    // listens.
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  /// The runtime went away on its own -- what [RpcFlutterWasmBridge] does when
  /// native reports a jetsammed content process or a killed sandbox.
  ///
  /// Call it on the HOST side. A bridge's own `_incoming` is its RECEIVE queue
  /// (`send` writes into the peer's), so the host's is what must fail: that is
  /// the stream `RpcChannelTransport` listens to.
  void killRuntime([String reason = 'runtime died']) {
    if (_closed) return;
    _closed = true;
    _peer._closed = true;
    if (!_incoming.isClosed) {
      _incoming.addError(
        RpcStatusException(RpcStatus.unavailable, 'WASM runtime died: $reason'),
        StackTrace.current,
      );
      unawaited(_incoming.close());
    }
  }
}
