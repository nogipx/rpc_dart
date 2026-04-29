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
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);
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
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}
