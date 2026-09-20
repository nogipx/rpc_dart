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

@JS('console.error')
external void _consoleError(JSString message);

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
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'RpcWasm.run() may only be called once per runtime',
      );
    }
    _initialized = true;

    // Guest code runs in a guarded zone so an unawaited failing Future -- the
    // way ordinary code drops an error by accident -- is reported as an ERROR.
    //
    // It was already reaching the host, but through dart2wasm's own uncaught
    // handler, which prints. Measured on both an iOS 18.6 simulator and an
    // Android 11 emulator, a handler scheduling a Future it never awaits:
    //
    //     before : I:Bad state: orphaned guest failure     <- info
    //     after  : E:...                                   <- error
    //
    // An operator filtering the console stream for errors saw nothing at all
    // when a handler inside the sandbox failed. The zone also carries the
    // stack, which print alone did not.
    // A SYNCHRONOUS throw out of the zone body goes to the handler above, not
    // to the caller: runZonedGuarded returns null and `result` is never
    // assigned, so `return result` raised a LateInitializationError and a
    // failing `configure` or `start()` reached the guest author as a message
    // about an uninitialised field. Caught here and rethrown after the zone
    // closes, so the boot error surfaces as itself.
    late final RpcPeerEndpoint result;
    Object? bootError;
    StackTrace? bootStack;
    runZonedGuarded(
      () {
        try {
          result = _boot(
            configure: configure,
            isClient: isClient,
            policy: policy,
            debugLabel: debugLabel,
            compressionEnabled: compressionEnabled,
            logController: logController,
          );
        } catch (error, stack) {
          bootError = error;
          bootStack = stack;
        }
      },
      (error, stack) {
        _consoleError('Unhandled error in WASM guest: $error\n$stack'.toJS);
      },
    );
    final failure = bootError;
    if (failure != null) {
      // Reported as well as rethrown. An exception escaping the guest's `main`
      // is printed by dart2wasm's own uncaught handler at INFO level, which is
      // the very thing the zone was added to fix -- an operator filtering the
      // console for errors would see nothing for a runtime that never booted.
      _consoleError('WASM guest failed to boot: $failure\n$bootStack'.toJS);
      Error.throwWithStackTrace(failure, bootStack ?? StackTrace.current);
    }
    return result;
  }

  static RpcPeerEndpoint _boot({
    required void Function(RpcPeerEndpoint endpoint) configure,
    required bool isClient,
    required RpcSecurityPolicy policy,
    required String? debugLabel,
    required bool compressionEnabled,
    required LogController? logController,
  }) {
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
      // Clearing `_initialized` invites a retry, so the failed boot has to
      // leave NOTHING behind. Closing the endpoint alone does not: it reaches
      // the bridge only after several awaits, while a retry installs its own
      // `rpcWasmReceiveBytes` synchronously — so the late close deleted the
      // LIVE handler and every host-to-guest byte went nowhere.
      //
      // `_RpcWasmBridge.close()` releases the JS global before its first await,
      // so calling it here frees the name while this call still owns it.
      unawaited(bridge.close());
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
