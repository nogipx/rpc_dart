// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for a boolean value.
class RpcBool extends RpcPrimitiveMessage<bool> {
  /// Creates a new RpcBool.
  ///
  /// [value] Boolean value to store.
  ///
  /// Provides consistent serialization/deserialization for booleans in RPC.
  const RpcBool(super.value);

  /// Creates RpcBool from JSON: a bool, a number (non-zero is true) or the
  /// strings `true`, `false`, `1`, `0`; no value is false. Anything else
  /// throws [FormatException] rather than reading as false.
  factory RpcBool.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v == null) return const RpcBool(false);
    if (v is bool) return RpcBool(v);
    if (v is num) return RpcBool(v != 0);
    if (v is String) {
      switch (v.toLowerCase().trim()) {
        case 'true' || '1':
          return const RpcBool(true);
        case 'false' || '0':
          return const RpcBool(false);
      }
    }
    throw FormatException(
      'RpcBool.fromJson: cannot decode value of type ${v.runtimeType}: $v',
    );
  }

  /// Default codec for [RpcBool].
  static RpcCodec<RpcBool> get codec => RpcCodec<RpcBool>(RpcBool.fromJson);

  @override
  String toString() => value.toString();
}
