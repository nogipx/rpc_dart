// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// CBOR serializer for RPC messages.
class RpcCodec<T extends IRpcSerializable> implements IRpcCodec<T> {
  final T Function(Map<String, dynamic> json)? _fromJson;

  /// Creates a CBOR serializer.
  /// [fromJson] builds an object from a JSON map.
  const RpcCodec([T Function(Map<String, dynamic> json)? fromJson])
      : _fromJson = fromJson;

  /// Creates a CBOR serializer with a required decoder.
  const RpcCodec.withDecoder(T Function(Map<String, dynamic> json) fromJson)
      : _fromJson = fromJson;

  @override
  Uint8List serialize(T message) {
    // Obtain the JSON representation first.
    final json = message.toJson();

    return CborCodec.encode(json);
  }

  @override
  T deserialize(Uint8List bytes) {
    final decoder = _fromJson;
    if (decoder == null) {
      throw StateError(
        'RpcCodec cannot deserialize data without a fromJson function. '
        'Create an instance via RpcCodec.withDecoder or pass fromJson to the constructor.',
      );
    }

    final decoded = CborCodec.decode(bytes);

    // CborCodec.decode always returns Map<String, dynamic>.
    return decoder(decoded);
  }

  /// Static helper for CBOR deserialization.
  static T fromBytes<T extends IRpcSerializable>({
    required Uint8List bytes,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    final decoded = CborCodec.decode(bytes);

    // CborCodec.decode already returns Map<String, dynamic>.
    return fromJson(decoded);
  }
}

// Converts LinkedMap<dynamic, dynamic> to Map<String, dynamic>.
Map<String, dynamic> convertMap(Map<dynamic, dynamic> map) {
  return map.map((key, value) => MapEntry(key.toString(), value));
}
