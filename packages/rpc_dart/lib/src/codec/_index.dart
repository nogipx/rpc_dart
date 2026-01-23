// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'special_cbor.dart';

part 'codec.dart';
part 'binary_codec.dart';

/// Base interface for RPC messages that can be turned into bytes.
/// All request/response types should implement this for binary serialization
/// (protobuf, msgpack, etc.).
abstract interface class IRpcSerializable {
  /// Serializes an object to a map representation.
  Map<String, dynamic> toJson();

  /// Deserializes an object from bytes (should be a static factory).
  /// static T fromBytes(Uint8List bytes);
}

/// Contract for encoding and decoding messages.
///
/// Hides the underlying serialization format (JSON, Protocol Buffers,
/// MessagePack, etc.) while providing conversion to and from bytes.
abstract class IRpcCodec<T> {
  /// Serializes an object of type T to a byte sequence.
  ///
  /// [message] Object to serialize.
  /// Returns the byte representation.
  Uint8List serialize(T message);

  /// Deserializes bytes into an object of type T.
  ///
  /// [bytes] Bytes to deserialize.
  /// Returns the reconstructed object.
  T deserialize(Uint8List bytes);
}
