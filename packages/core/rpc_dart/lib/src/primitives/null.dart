// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for null.
class RpcNull extends RpcPrimitiveMessage<void> {
  /// Creates an [RpcNull] instance.
  const RpcNull() : super(null);

  /// Creates an [RpcNull] from JSON (always returns a new instance).
  static RpcNull fromJson(Map<String, dynamic> json) {
    return RpcNull();
  }

  /// Creates an [RpcNull] from bytes (always returns a new instance).
  static RpcNull fromBytes(Uint8List bytes) {
    return RpcNull();
  }

  /// Default codec for [RpcNull].
  static RpcCodec<RpcNull> get codec => RpcCodec<RpcNull>(RpcNull.fromJson);

  @override
  String toString() => null.toString();
}
