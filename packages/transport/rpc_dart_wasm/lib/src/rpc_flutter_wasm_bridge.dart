// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;

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

  /// Whether [RpcFlutterWasmBridge.load] can succeed here.
  ///
  /// Includes the two sandbox features the Android plugin requires and reports
  /// in [details] -- WASM compilation and provide/consume array buffers --
  /// because load refuses without either. iOS reports neither and needs
  /// neither.
  bool get canRunDartWasm =>
      jsEngineAvailable &&
      webAssemblyAvailable &&
      wasmGcSupported &&
      details['wasmCompilationSupported'] != false &&
      details['namedDataSupported'] != false;

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
  final String _diedChannel;

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

  /// The runtime went away on its own. Distinct from [_closed]: a dead bridge
  /// reports itself closed, but [close] still has its own work to do.
  bool _dead = false;

  /// Native was asked to release the runtime -- by the death report or by
  /// [close], whichever came first. Asked once.
  bool _released = false;

  void _releaseNative() {
    if (_released) return;
    _released = true;
    unawaited(
      _channel
          .invokeMethod<void>('closeRuntime', {'runtimeId': runtimeId})
          .catchError((Object _) {}),
    );
  }

  final StreamController<String> _console = StreamController<String>.broadcast(
    sync: true,
  );

  /// Console log stream from WASM JS sandbox, one line per event.
  /// Each line is prefixed with level: "I:", "W:", "E:", "D:".
  Stream<String> get console => _console.stream;

  static final RegExp _levelPrefix = RegExp('^[IWED]:');

  RpcFlutterWasmBridge._(this.runtimeId, this._messenger)
    : _incomingChannel = 'rpc_dart_wasm/$runtimeId/incoming',
      _outgoingChannel = 'rpc_dart_wasm/$runtimeId/outgoing',
      _consoleChannel = 'rpc_dart_wasm/$runtimeId/console',
      _diedChannel = 'rpc_dart_wasm/$runtimeId/died' {
    // Native tells us the sandbox is gone. Without this the runtime's death is
    // invisible to Dart: `incoming` only ended when the HOST closed it, so
    // every in-flight call waited out a deadline that is optional on this
    // transport.
    _messenger.setMessageHandler(_diedChannel, (ByteData? message) async {
      _reportDeath(_reasonOf(message));
      return null;
    });

    // Console log channel from native.
    final consoleChannel = _consoleChannel;
    _messenger.setMessageHandler(consoleChannel, (ByteData? message) async {
      if (message == null || _closed) return null;
      final bytes = Uint8List.view(
        message.buffer,
        message.offsetInBytes,
        message.lengthInBytes,
      );
      final text = _decodeNativeText(bytes);
      // Only an entry's first line carries its level; the rest -- a stack
      // trace -- inherit it, or a filter on `E:` keeps the message and drops
      // the stack.
      var level = 'I:';
      for (final line in text.split('\n')) {
        if (line.isEmpty || _console.isClosed) continue;
        if (_levelPrefix.hasMatch(line)) {
          level = line.substring(0, 2);
          _console.add(line);
        } else {
          _console.add('$level$line');
        }
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
  ///
  /// The bridge -- and its channel handlers -- exist BEFORE the runtime boots,
  /// under an id chosen here: native pushes what the guest sends during its
  /// `main` before `loadRuntime` returns, and Flutter holds one message per
  /// channel that has no handler, so of three boot frames Dart got the last.
  static Future<RpcFlutterWasmBridge> load({
    required Uint8List wasmBytes,
    required String mjsCode,
    String jsBootPrefix = '',
  }) async {
    final bridge = RpcFlutterWasmBridge._(
      _newRuntimeId(),
      ServicesBinding.instance.defaultBinaryMessenger,
    );
    final Map<String, Object?> map;
    try {
      final result = await _channel
          .invokeMethod<Map<Object?, Object?>>('loadRuntime', {
            'wasm': wasmBytes,
            'mjs': mjsCode,
            'jsBootPrefix': jsBootPrefix,
            'runtimeId': bridge.runtimeId,
          });
      map = (result ?? const <Object?, Object?>{}).cast<String, Object?>();
    } catch (_) {
      bridge._release();
      rethrow;
    }
    final runtimeId = map['runtimeId'] as String?;
    final error = map['error'] as String?;
    if (runtimeId == null || error != null) {
      bridge._release();
      throw RpcStatusException(
        RpcStatus.unavailable,
        'Failed to load WASM runtime: ${error ?? "no id"}',
      );
    }
    if (runtimeId != bridge.runtimeId) {
      bridge._release();
      unawaited(
        _channel.invokeMethod<void>('closeRuntime', {'runtimeId': runtimeId}),
      );
      throw RpcStatusException(
        RpcStatus.unavailable,
        'The native plugin ignored the requested runtime id',
      );
    }
    return bridge;
  }

  static final Random _ids = Random.secure();

  static String _newRuntimeId() => List.generate(
    16,
    (_) => _ids.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  /// Drops the handlers and controllers of a bridge whose runtime never came
  /// up; native has nothing to release.
  void _release() {
    _closed = true;
    _messenger.setMessageHandler(_incomingChannel, null);
    _messenger.setMessageHandler(_consoleChannel, null);
    _messenger.setMessageHandler(_diedChannel, null);
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_console.isClosed) unawaited(_console.close());
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isClosed => _closed || _dead;

  /// Whether the runtime died on its own rather than being closed by the host.
  bool get isDead => _dead;

  /// Decodes text both plugins encode as UTF-8 — `data(using: .utf8)` on iOS,
  /// `toByteArray(Charsets.UTF_8)` on Android.
  ///
  /// `String.fromCharCodes` is a byte-per-character reinterpretation, so every
  /// non-ASCII character arrived as one mojibake character per byte. It cannot
  /// throw, which is why nothing noticed.
  ///
  /// `allowMalformed`, because both call sites are diagnostics: the console
  /// handler runs inside a platform message handler and `_reasonOf` inside the
  /// death report. A decoder that threw there would turn a truncated log line
  /// into a crash, or lose the death notice that is the whole point of the
  /// channel.
  static String _decodeNativeText(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  static String _reasonOf(ByteData? message) {
    if (message == null || message.lengthInBytes == 0) return 'runtime died';
    return _decodeNativeText(
      Uint8List.view(
        message.buffer,
        message.offsetInBytes,
        message.lengthInBytes,
      ),
    );
  }

  /// Fails `incoming` so every in-flight call is answered.
  ///
  /// UNAVAILABLE because that is what the death of a peer is in gRPC terms, and
  /// because it is retryable: reloading the runtime and calling again is the
  /// correct response, which a bare exception would not have expressed.
  void _reportDeath(String reason) {
    if (_dead || _closed) return;
    _dead = true;
    _messenger.setMessageHandler(_incomingChannel, null);
    _messenger.setMessageHandler(_consoleChannel, null);
    _messenger.setMessageHandler(_diedChannel, null);
    if (!_incoming.isClosed) {
      _incoming.addError(
        RpcStatusException(
          RpcStatus.unavailable,
          'WASM runtime $runtimeId died: $reason',
        ),
        StackTrace.current,
      );
      unawaited(_incoming.close());
    }
    if (!_console.isClosed) unawaited(_console.close());
    // Release the native side now. The iOS runtime holds its web view -- and
    // the web view's content process -- until closeRuntime, so a dead runtime
    // the application never closes would keep them for good. Android has
    // already released its own; there closeRuntime finds nothing.
    _releaseNative();
  }

  /// Frames waiting for the native side, in order, and their total size.
  final List<Uint8List> _sendQueue = [];
  int _sendQueuedBytes = 0;
  bool _pumping = false;

  /// Completed when the queue drops below [_sendQueueLimit] again.
  Completer<void>? _sendRoom;

  /// The most a [send] queues before it waits for the native side.
  static const int _sendQueueLimit = 1024 * 1024;

  /// The most one platform message carries, in frames and in bytes; a single
  /// larger frame still goes alone. Frames because the guest decodes a chunk
  /// in one go, and a chunk of thousands outruns its consumer.
  static const int _sendBatchFrames = 64;
  static const int _sendBatchBytes = 64 * 1024;

  /// Queues [data] and returns once it is queued, unless the queue is full.
  ///
  /// One platform message per frame, each awaited before the next, held the
  /// guest to one frame per native round trip -- each a JavaScript evaluation
  /// on Android: about 30 frames a second host-to-guest. The pump below sends
  /// whatever has queued in one message instead. Safe because the bridge is a
  /// byte stream that the guest reassembles. Flow control still bounds what is
  /// in flight; the queue limit bounds memory if the peer does no flow control.
  @override
  Future<void> send(Uint8List data) async {
    if (_closed || _dead) return;
    assert(() {
      debugPrint('[RpcFlutterWasmBridge] sending ${data.length} bytes');
      return true;
    }());
    _sendQueue.add(data);
    _sendQueuedBytes += data.lengthInBytes;
    if (!_pumping) unawaited(_pumpSends());
    if (_sendQueuedBytes > _sendQueueLimit) {
      await (_sendRoom ??= Completer<void>()).future;
    }
  }

  Future<void> _pumpSends() async {
    _pumping = true;
    try {
      while (_sendQueue.isNotEmpty && !_closed && !_dead) {
        var frames = 1;
        var bytes = _sendQueue.first.lengthInBytes;
        while (frames < _sendQueue.length &&
            frames < _sendBatchFrames &&
            bytes + _sendQueue[frames].lengthInBytes <= _sendBatchBytes) {
          bytes += _sendQueue[frames].lengthInBytes;
          frames++;
        }
        final Uint8List chunk;
        if (frames == 1) {
          chunk = _sendQueue.first;
        } else {
          chunk = Uint8List(bytes);
          var at = 0;
          for (var i = 0; i < frames; i++) {
            chunk.setAll(at, _sendQueue[i]);
            at += _sendQueue[i].lengthInBytes;
          }
        }
        _sendQueue.removeRange(0, frames);
        _sendQueuedBytes -= bytes;
        final room = _sendRoom;
        if (room != null && _sendQueuedBytes <= _sendQueueLimit) {
          _sendRoom = null;
          room.complete();
        }
        final reply = _messenger.send(
          _outgoingChannel,
          ByteData.view(chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes),
        );
        if (reply != null) await reply;
      }
    } finally {
      _pumping = false;
      // A closed or dead bridge sends nothing more; release any waiter.
      final room = _sendRoom;
      _sendRoom = null;
      room?.complete();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    // The constructor registers THREE message handlers and owns TWO
    // controllers, so close() has to release all of them. A handler left
    // registered is a closure holding this bridge, which pins it and its
    // controllers for good; a controller left open never completes its stream,
    // so anything awaiting `console` waits forever.
    _messenger.setMessageHandler(_incomingChannel, null);
    _messenger.setMessageHandler(_consoleChannel, null);
    _messenger.setMessageHandler(_diedChannel, null);
    // NOT awaited, now that `_incoming` is single-subscription: closing one
    // that was never listened to returns a future that does not complete until
    // someone listens, so awaiting it deadlocks close() for a bridge that was
    // built and then abandoned — an aborted setup, which is exactly when
    // cleanup has to work. Same fault, same fix as RpcWebSocketChannel.close().
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_console.isClosed) await _console.close();

    if (!_released) {
      _released = true;
      await _channel.invokeMethod<void>('closeRuntime', {
        'runtimeId': runtimeId,
      });
    }
  }
}
