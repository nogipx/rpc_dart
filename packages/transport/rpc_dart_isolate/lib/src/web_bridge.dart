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

import 'package:rpc_dart/transport.dart';

import 'port_channel.dart';

/// Wire name to type. The wire name IS the enum name, so renaming a value
/// changes the protocol.
final Map<String, PortFrameType> _frameTypes = PortFrameType.values.asNameMap();

/// [frame] in the Map form structured clone accepts.
Map<String, Object?> bridgeMapOf(PortFrame frame) => {
  'type': frame.type.name,
  'streamId': frame.streamId,
  if (frame.endStream) 'endStream': true,
  if (frame.body != null)
    frame.type == PortFrameType.metadata ? 'metadata' : 'payload': frame.body,
  if (frame.methodPath != null) 'methodPath': frame.methodPath,
};

/// Parses [raw], returning null for anything that is not one of our frames.
///
/// A worker cannot share an object, so a `directObject` frame is not one.
PortFrame? bridgeFrameOf(Object? raw) {
  if (raw is! Map) return null;
  final typeRaw = raw['type'];
  final streamId = asInt(raw['streamId']);
  if (typeRaw is! String || streamId == null) return null;
  final type = _frameTypes[typeRaw];
  if (type == null || type == PortFrameType.directObject) return null;
  return PortFrame(
    type: type,
    streamId: streamId,
    endStream: raw['endStream'] == true,
    body: type == PortFrameType.metadata ? raw['metadata'] : raw['payload'],
    methodPath: raw['methodPath'] is String
        ? raw['methodPath'] as String
        : null,
  );
}

/// [PortChannel] over an isolate_manager worker controller.
///
/// Does NOT support zero-copy -- frames cross by structured clone.
///
/// Takes its transmit function as a parameter, so a test supplies a stub and
/// never needs a Worker.
final class WebMultiplexedChannel extends PortChannel {
  final void Function(Map<String, Object?> data) _send;

  /// Frames sent before [release], in order; null once released.
  List<Map<String, Object?>>? _held;

  /// Bridges [messageStream] and [send].
  ///
  /// [holdUntilReleased] keeps every outgoing frame until [release]. The host
  /// needs it: its transport advertises the connection window from its
  /// constructor, before the worker script has installed `onmessage`, and a
  /// module worker -- dart2wasm's -- drops what arrives before then. Measured
  /// in Chrome, the worker's connection credit stayed null: host-to-worker flow
  /// control silently off.
  WebMultiplexedChannel({
    required super.messageStream,
    required void Function(Map<String, Object?> data) send,
    super.onClose,
    bool holdUntilReleased = false,
  }) : _send = send,
       _held = holdUntilReleased ? <Map<String, Object?>>[] : null;

  /// Sends what [holdUntilReleased] kept, in order, and stops holding.
  void release() {
    final held = _held;
    if (held == null) return;
    _held = null;
    if (isClosed) return;
    for (final frame in held) {
      _send(frame);
    }
  }

  @override
  bool get supportsZeroCopy => false;

  @override
  String get unsendable => 'cannot be structured-cloned to the worker';

  /// The close frame skips the hold: the channel is closed by then.
  @override
  void post(Object message) {
    final frame = message as Map<String, Object?>;
    final held = _held;
    if (held != null && !isClosed) {
      held.add(frame);
    } else {
      _send(frame);
    }
  }

  @override
  Object encodeFrame(PortFrame frame) => bridgeMapOf(frame);

  @override
  PortFrame? decodeFrame(Object? raw) => bridgeFrameOf(raw);

  @override
  Object encodeBytes(Uint8List bytes) => serializeBytes(bytes);

  @override
  Uint8List decodeBytes(Object? body) => materializeBytes(body);

  @override
  Object encodeMetadata(RpcMetadata metadata) => {
    'headers': metadata.headers
        .map((header) => {'name': header.name, 'value': header.value})
        .toList(),
  };

  @override
  RpcMetadata decodeMetadata(Object? body) {
    final headersRaw = body is Map ? body['headers'] : null;
    if (headersRaw is! List) {
      // The TYPE, not the payload: this decodes a message that crossed a worker
      // boundary, and the status reaches a peer where a StateError would be
      // redacted to INTERNAL.
      throw RpcStatusException(
        RpcStatus.invalidArgument,
        'Invalid metadata headers: expected a list, got '
        '${headersRaw.runtimeType}',
      );
    }
    return RpcMetadata(
      headersRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (header) => RpcHeader(
              header['name']?.toString() ?? '',
              header['value']?.toString() ?? '',
            ),
          )
          .toList(),
    );
  }
}

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
///
/// The typed array itself: structured clone copies it as one block, where a
/// `List<int>` crossed as a JS array of numbers, boxed and copied element by
/// element on both sides. A view into a larger buffer is compacted first,
/// because cloning a typed array clones its whole underlying buffer.
/// [materializeBytes] still reads the old list form, from an older peer.
Uint8List serializeBytes(Uint8List data) =>
    data.offsetInBytes == 0 && data.lengthInBytes == data.buffer.lengthInBytes
    ? data
    : Uint8List.fromList(data);
