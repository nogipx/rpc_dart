// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:rpc_dart/rpc_dart.dart';

import '../rpc_wasm_bridge.dart';
import '../rpc_wasm_transport.dart';

@JS('_rpcWasmSendBytes')
external void _sendBytes(JSUint8Array bytes);

/// Bootstrap for Dart code compiled to WASM.
///
/// This installs the runtime byte callback expected by the native host,
/// adapts the byte pipe into [RpcWasmTransport], and starts a peer endpoint.
///
/// Example:
///
/// ```dart
/// import 'package:rpc_dart_wasm/rpc_wasm.dart';
///
/// void main() {
///   RpcWasm.run(
///     configure: (endpoint) {
///       endpoint.start();
///     },
///   );
/// }
/// ```
abstract final class RpcWasm {
  static bool _initialized = false;
  static RpcPeerEndpoint? _activeEndpoint;

  /// The endpoint created by the most recent [run] call, if any.
  static RpcPeerEndpoint? get activeEndpoint => _activeEndpoint;

  /// Boots a WASM runtime-side peer endpoint.
  ///
  /// [configure] is called before the endpoint starts listening so service
  /// registrations can be installed first.
  static RpcPeerEndpoint run({
    required void Function(RpcPeerEndpoint endpoint) configure,
    bool isClient = false,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    String? debugLabel,
    bool compressionEnabled = false,
    LogController? logController,
  }) {
    if (_initialized) {
      throw StateError('RpcWasm.run() may only be called once per runtime');
    }
    _initialized = true;

    final bridge = _RpcWasmBridge();
    final transport = RpcWasmTransport.fromBridge(
      bridge: bridge,
      isClient: isClient,
      policy: policy,
    );
    final endpoint = RpcPeerEndpoint(
      transport: transport,
      debugLabel: debugLabel,
      compressionEnabled: compressionEnabled,
      logger: logController,
    );

    try {
      configure(endpoint);
      endpoint.start();
      _activeEndpoint = endpoint;
      return endpoint;
    } catch (error, stackTrace) {
      unawaited(endpoint.close());
      _initialized = false;
      _activeEndpoint = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

final class _RpcWasmBridge implements RpcWasmBridge {
  /// SINGLE-SUBSCRIPTION on purpose: it BUFFERS until the transport binds.
  ///
  /// Broadcast DROPS whatever arrives before someone listens, and the window is
  /// wide open here: the constructor installs `rpcWasmReceiveBytes` on the JS
  /// global, so the host can push bytes immediately, while the subscriber only
  /// appears once [RpcWasm.run] builds the transport below.
  ///
  /// The host's `RpcChannelTransport` advertises the CONNECTION flow-control
  /// window from its own constructor and is up first, so that grant lands in
  /// this window. Measured over the bridge pair with 8 streams, a 64 KiB stream
  /// window and a 128 KiB connection window: 512 KiB in flight instead of
  /// 128 KiB — the connection bound gone entirely. See the host bridge for the
  /// full note.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: true,
  );
  bool _closed = false;

  _RpcWasmBridge() {
    globalContext['rpcWasmReceiveBytes'] = _receiveBytes.toJS;
  }

  void _receiveBytes(JSUint8Array bytes) {
    if (_closed || _incoming.isClosed) return;
    final dartBytes = bytes.toDart;
    _incoming.add(dartBytes);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    _sendBytes(data.toJS);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (globalContext.has('rpcWasmReceiveBytes')) {
      globalContext.delete('rpcWasmReceiveBytes'.toJS);
    }
    // NOT awaited: closing a never-listened single-subscription controller
    // returns a future that only completes once someone listens, which would
    // deadlock close() for a bridge that was built and then abandoned.
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }
}
