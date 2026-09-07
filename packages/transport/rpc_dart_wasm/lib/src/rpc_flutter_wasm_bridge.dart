// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rpc_wasm_bridge.dart';

/// Platform support details for the Flutter WASM backend.
final class RpcWasmSupportInfo {
  final bool jsEngineAvailable;
  final bool webAssemblyAvailable;
  final bool wasmGcSupported;
  final Map<String, Object?> details;

  const RpcWasmSupportInfo({
    required this.jsEngineAvailable,
    required this.webAssemblyAvailable,
    required this.wasmGcSupported,
    required this.details,
  });

  bool get canRunDartWasm =>
      jsEngineAvailable && webAssemblyAvailable && wasmGcSupported;

  @override
  String toString() =>
      'RpcWasmSupportInfo(jsEngine=$jsEngineAvailable, '
      'wasm=$webAssemblyAvailable, gc=$wasmGcSupported)';
}

/// Flutter plugin implementation of [RpcWasmBridge].
///
/// Native code owns the JavaScript/WASM runtime. This class only exposes a
/// byte pipe to [RpcWasmTransport].
final class RpcFlutterWasmBridge implements RpcWasmBridge {
  static const MethodChannel _channel = MethodChannel('rpc_dart_wasm');

  final String runtimeId;
  final BinaryMessenger _messenger;
  final String _incomingChannel;
  final String _outgoingChannel;
  final String _consoleChannel;

  /// SINGLE-SUBSCRIPTION on purpose: it BUFFERS until the transport binds.
  ///
  /// This was a broadcast controller, which DROPS whatever arrives before
  /// someone listens — and there is always a window here, because the platform
  /// message handler below is registered in this constructor while the
  /// subscriber only appears later, when `RpcWasmTransport.fromBridge` builds
  /// the frame channel.
  ///
  /// rpc_dart does send in that window: `RpcChannelTransport` advertises the
  /// CONNECTION flow-control window from its own constructor, so whichever side
  /// comes up first advertises into a bridge nobody is listening to yet. The
  /// peer then never learns the connection window and is bounded only per
  /// stream. Measured over the bridge pair, 8 streams with a 64 KiB stream
  /// window and a 128 KiB connection window, sending into a peer that never
  /// reads:
  ///
  ///     core channel pair : 128 KiB in flight   <- the connection window
  ///     over this bridge  : 512 KiB in flight   <- 8 x the stream window
  ///
  /// Exactly the isolate transport's defect ("the window grant is the one that
  /// is always lost"), and exactly what `RpcWebSocketChannel` warns against in
  /// its own comment. One consumer is the contract here — the transport — so
  /// single-subscription costs nothing and is what buffers.
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>(
    sync: true,
  );
  bool _closed = false;

  final StreamController<String> _console = StreamController<String>.broadcast(
    sync: true,
  );

  /// Console log stream from WASM JS sandbox.
  /// Each entry is prefixed with level: "I:", "W:", "E:", "D:".
  Stream<String> get console => _console.stream;

  RpcFlutterWasmBridge._(this.runtimeId, this._messenger)
    : _incomingChannel = 'rpc_dart_wasm/$runtimeId/incoming',
      _outgoingChannel = 'rpc_dart_wasm/$runtimeId/outgoing',
      _consoleChannel = 'rpc_dart_wasm/$runtimeId/console' {
    // Console log channel from native.
    final consoleChannel = _consoleChannel;
    _messenger.setMessageHandler(consoleChannel, (ByteData? message) async {
      if (message == null || _closed) return null;
      final bytes = Uint8List.view(
        message.buffer,
        message.offsetInBytes,
        message.lengthInBytes,
      );
      final text = String.fromCharCodes(bytes);
      for (final line in text.split('\n')) {
        if (line.isNotEmpty && !_console.isClosed) _console.add(line);
      }
      return null;
    });

    _messenger.setMessageHandler(_incomingChannel, (ByteData? message) async {
      if (message == null || _closed || _incoming.isClosed) return null;
      assert(() {
        debugPrint(
          '[RpcFlutterWasmBridge] received ${message.lengthInBytes} bytes',
        );
        return true;
      }());
      _incoming.add(
        Uint8List.view(
          message.buffer,
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      return null;
    });
  }

  /// Checks whether this platform can run the configured WASM backend.
  static Future<RpcWasmSupportInfo> checkSupport() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'checkSupport',
    );
    final map = (result ?? const <Object?, Object?>{}).cast<String, Object?>();
    return RpcWasmSupportInfo(
      jsEngineAvailable: map['jsEngineAvailable'] == true,
      webAssemblyAvailable: map['hasWebAssembly'] == true,
      wasmGcSupported: map['wasmGC'] == 'GC_SUPPORTED',
      details: map,
    );
  }

  /// Loads a Dart WASM bundle produced by `dart compile wasm`.
  ///
  /// [mjsCode] is the JavaScript glue file generated next to the `.wasm`.
  /// [jsBootPrefix] is evaluated before the glue code and can install extra
  /// host functions required by the runtime.
  static Future<RpcFlutterWasmBridge> load({
    required Uint8List wasmBytes,
    required String mjsCode,
    String jsBootPrefix = '',
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'loadRuntime',
      {'wasm': wasmBytes, 'mjs': mjsCode, 'jsBootPrefix': jsBootPrefix},
    );
    final map = (result ?? const <Object?, Object?>{}).cast<String, Object?>();
    final runtimeId = map['runtimeId'] as String?;
    final error = map['error'] as String?;
    if (runtimeId == null || error != null) {
      throw StateError('Failed to load WASM runtime: ${error ?? "no id"}');
    }
    return RpcFlutterWasmBridge._(
      runtimeId,
      ServicesBinding.instance.defaultBinaryMessenger,
    );
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    assert(() {
      debugPrint('[RpcFlutterWasmBridge] sending ${data.length} bytes');
      return true;
    }());
    final reply = _messenger.send(
      _outgoingChannel,
      ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
    );
    if (reply != null) {
      await reply;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // The constructor registers TWO message handlers and owns TWO controllers,
    // so close() has to release both. A handler left registered is a closure
    // holding this bridge, which pins it and its controllers for good; a
    // controller left open never completes its stream, so anything awaiting
    // `console` waits forever.
    _messenger.setMessageHandler(_incomingChannel, null);
    _messenger.setMessageHandler(_consoleChannel, null);
    // NOT awaited, now that `_incoming` is single-subscription: closing one
    // that was never listened to returns a future that does not complete until
    // someone listens, so awaiting it deadlocks close() for a bridge that was
    // built and then abandoned — an aborted setup, which is exactly when
    // cleanup has to work. Same fault, same fix as RpcWebSocketChannel.close().
    unawaited(_incoming.close());
    if (!_console.isClosed) await _console.close();

    await _channel.invokeMethod<void>('closeRuntime', {'runtimeId': runtimeId});
  }
}
