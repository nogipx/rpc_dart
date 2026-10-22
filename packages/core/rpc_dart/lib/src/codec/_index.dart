// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'special_cbor.dart';

export 'special_cbor.dart' show RpcCborCodec;

part 'codec.dart';
part 'binary_codec.dart';

/// Base interface for RPC messages that can be turned into bytes.
///
/// [toJson] gives the map a codec encodes; the type's `fromJson` factory,
/// handed to `RpcCodec`, reads it back.
abstract interface class IRpcSerializable {
  /// Serializes an object to a map representation.
  Map<String, dynamic> toJson();
}

/// Approximate size of [value]'s JSON form, without encoding it: the UTF-16
/// code units of every string, keys included, plus 8 for each other scalar.
/// An [IRpcSerializable] counts as its [IRpcSerializable.toJson].
///
/// Cheap enough to charge every message against a byte budget, which is what
/// it is for: bounding a buffer of messages that have not been encoded yet.
int approxJsonBytes(Object? value) => switch (value) {
  null => 0,
  final String s => s.length,
  final Map<dynamic, dynamic> m => m.entries.fold(
    0,
    (sum, e) => sum + approxJsonBytes(e.key) + approxJsonBytes(e.value),
  ),
  final Iterable<dynamic> items => items.fold(
    0,
    (sum, item) => sum + approxJsonBytes(item),
  ),
  final IRpcSerializable s => approxJsonBytes(s.toJson()),
  _ => 8,
};

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
