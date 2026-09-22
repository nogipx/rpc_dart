// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The worker bridge's wire format and channel, with no JS dependency.
///
/// Split out of `isolate_transport_web.dart` so it can be TESTED. That file
/// opens with `dart:js_interop` and `package:web`, which do not exist off the
/// web, so a VM test cannot import it — not the class, not the file, nothing.
/// Everything here uses `dart:async`, `dart:typed_data` and rpc_dart alone, so
/// moving it makes the channel's failure paths reachable from an ordinary test
/// while the Worker plumbing stays where it needs the browser.
///
/// Not exported from the package barrel: `rpc_dart_isolate.dart` exports
/// `isolate_transport_web.dart`, which IMPORTS this. Nothing here is public API.
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

// -- Bridge message format (Map-based, for structured-clone transfer) ---------

/// Frame kinds the host and worker exchange.
enum BridgeType { init, ready, metadata, data, finish, close }

/// One frame, in the Map form structured clone accepts.
class BridgeMessage {
  /// What kind of frame this is.
  final BridgeType type;

  /// The RPC stream this frame belongs to; 0 is the handshake.
  final int streamId;

  /// Whether this frame closes its stream.
  final bool endStream;

  /// Encoded [RpcMetadata], when [type] is [BridgeType.metadata].
  final Map<String, Object?>? metadata;

  /// The payload, when [type] is [BridgeType.data].
  final Object? payload;

  /// The method this stream calls, carried on the opening frame.
  final String? methodPath;

  /// Creates a frame.
  const BridgeMessage({
    required this.type,
    required this.streamId,
    this.endStream = false,
    this.metadata,
    this.payload,
    this.methodPath,
  });

  /// The structured-clone form.
  Map<String, Object?> toMap() => {
    'type': switch (type) {
      BridgeType.init => 'init',
      BridgeType.ready => 'ready',
      BridgeType.metadata => 'metadata',
      BridgeType.data => 'data',
      BridgeType.finish => 'finish',
      BridgeType.close => 'close',
    },
    'streamId': streamId,
    if (endStream) 'endStream': true,
    if (metadata != null) 'metadata': metadata,
    if (payload != null) 'payload': payload,
    if (methodPath != null) 'methodPath': methodPath,
  };

  /// Parses [raw], returning null for anything that is not one of our frames.
  static BridgeMessage? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final typeRaw = raw['type'];
    final streamId = asInt(raw['streamId']);
    if (typeRaw is! String || streamId == null) return null;
    final type = switch (typeRaw) {
      'init' => BridgeType.init,
      'ready' => BridgeType.ready,
      'metadata' => BridgeType.metadata,
      'data' => BridgeType.data,
      'finish' => BridgeType.finish,
      'close' => BridgeType.close,
      _ => null,
    };
    if (type == null) return null;
    final metadata = raw['metadata'];
    return BridgeMessage(
      type: type,
      streamId: streamId,
      endStream: raw['endStream'] == true,
      metadata: metadata is Map ? metadata.cast<String, Object?>() : null,
      payload: raw['payload'],
      methodPath: raw['methodPath'] as String?,
    );
  }
}

// -- Web multiplexed channel --------------------------------------------------

/// [IRpcMultiplexedChannel] backed by isolate_manager controller (web workers).
///
/// Does NOT support zero-copy -- bytes are serialized via structured clone.
///
/// Takes its transmit function as a parameter, so a test supplies a stub and
/// never needs a Worker.
class WebMultiplexedChannel implements IRpcMultiplexedChannel {
  final void Function(Map<String, Object?> data) _send;
  final StreamController<RpcTransportMessage> _incomingCtl =
      StreamController<RpcTransportMessage>.broadcast(sync: true);
  late final StreamSubscription<void> _messageSub;
  bool _closed = false;
  final void Function()? _onClose;

  /// Bridges [messageStream] and [send].
  WebMultiplexedChannel({
    required Stream<dynamic> messageStream,
    required void Function(Map<String, Object?> data) send,
    void Function()? onClose,
  }) : _send = send,
       _onClose = onClose {
    _messageSub = messageStream.listen(
      (raw) {
        final msg = BridgeMessage.fromMap(raw);
        if (msg != null) _handleMessage(msg);
      },
      onError: (_) {
        if (!_closed) close();
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incoming => _incomingCtl.stream;

  @override
  Future<void> send(RpcTransportMessage message) async {
    if (_closed) return;

    BridgeType type;
    Map<String, Object?>? metadata;
    Object? payload;

    if (message.payload != null) {
      type = BridgeType.data;
      payload = serializeBytes(message.payload!);
    } else if (message.metadata != null) {
      type = BridgeType.metadata;
      metadata = encodeMetadata(message.metadata!);
    } else if (message.isEndOfStream) {
      type = BridgeType.finish;
    } else {
      return;
    }

    try {
      _send(
        BridgeMessage(
          type: type,
          streamId: message.streamId,
          endStream: message.isEndOfStream,
          metadata: metadata,
          payload: payload,
          methodPath: message.methodPath,
        ).toMap(),
      );
    } catch (error, stack) {
      // ONE message's problem, not the connection's -- the same rule the VM
      // sibling states. `postMessage` throws here for one reason: the payload
      // is not structured-cloneable. A dead worker is SILENT, so a throw is
      // never how this side learns the peer is gone.
      //
      // Closing the channel would kill every other in-flight call over one bad
      // payload, and swallowing the reason would report it as UNAVAILABLE.
      Error.throwWithStackTrace(
        ArgumentError(
          'Isolate transport: the message on stream ${message.streamId} cannot '
          'be structured-cloned to the worker. $error',
        ),
        stack,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    try {
      _send(BridgeMessage(type: BridgeType.close, streamId: 0).toMap());
    } catch (_) {}

    await _messageSub.cancel();
    if (!_incomingCtl.isClosed) await _incomingCtl.close();
    _onClose?.call();
  }

  void _handleMessage(BridgeMessage message) {
    if (_closed || _incomingCtl.isClosed) return;
    if (message.streamId < 0) return;

    switch (message.type) {
      case BridgeType.init:
      case BridgeType.ready:
        break;
      case BridgeType.metadata:
        // Stream 0 is NOT filtered here, unlike the payload cases below.
        //
        // The init/ready/close handshake this bridge reserves stream 0 for uses
        // distinct types, so a `metadata` frame on stream 0 is never a
        // handshake message -- it is RpcChannelTransport's CONNECTION-level
        // flow control. Drop it and the peer looks like one that does not
        // participate, leaving the connection window off in BOTH directions.
        _incomingCtl.add(
          RpcTransportMessage(
            metadata: decodeMetadata(
              message.metadata ?? const <String, Object?>{},
            ),
            isEndOfStream: message.endStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case BridgeType.data:
        if (message.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(
            payload: materializeBytes(message.payload),
            isEndOfStream: message.endStream,
            streamId: message.streamId,
            methodPath: message.methodPath,
          ),
        );
      case BridgeType.finish:
        if (message.streamId == 0) return;
        _incomingCtl.add(
          RpcTransportMessage(isEndOfStream: true, streamId: message.streamId),
        );
      case BridgeType.close:
        close();
    }
  }
}

// -- Helpers ------------------------------------------------------------------

/// Decodes the metadata a peer sent over the worker boundary.
RpcMetadata decodeMetadata(Map<String, Object?> raw) {
  final headersRaw = raw['headers'];
  if (headersRaw is! List) {
    // The TYPE, not the payload: this decodes a message that crossed a worker
    // boundary, and the status now reaches a peer where a StateError was
    // redacted to INTERNAL.
    throw RpcStatusException(
      RpcStatus.invalidArgument,
      'Invalid metadata headers: expected a list, got '
      '${headersRaw.runtimeType}',
    );
  }
  final headers = headersRaw
      .whereType<Map<Object?, Object?>>()
      .map(
        (header) => RpcHeader(
          header['name']?.toString() ?? '',
          header['value']?.toString() ?? '',
        ),
      )
      .toList();
  return RpcMetadata(headers);
}

/// Encodes metadata into the structured-clone form.
Map<String, Object?> encodeMetadata(RpcMetadata metadata) => {
  'headers': metadata.headers
      .map((header) => {'name': header.name, 'value': header.value})
      .toList(),
};

/// Reads an int a structured clone may have widened to `num`.
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

/// Recovers payload bytes from whatever structured clone delivered.
Uint8List materializeBytes(Object? raw) {
  if (raw is Uint8List) return raw;
  if (raw is ByteBuffer) return Uint8List.view(raw);
  if (raw is List) {
    return Uint8List.fromList(
      raw.map((value) => (value as num).toInt()).toList(growable: false),
    );
  }
  throw RpcStatusException(
    RpcStatus.invalidArgument,
    'Unsupported binary payload: ${raw.runtimeType}',
  );
}

/// Puts payload bytes into a form structured clone accepts everywhere.
List<int> serializeBytes(Uint8List data) => data.toList(growable: false);
