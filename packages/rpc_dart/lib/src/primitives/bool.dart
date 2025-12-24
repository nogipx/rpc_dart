// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
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

  /// Creates RpcBool from JSON.
  factory RpcBool.fromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v == null) return const RpcBool(false);
      if (v is bool) return RpcBool(v);

      // Convert numeric values.
      if (v is num) return RpcBool(v != 0);

      // Convert string values.
      final vStr = v.toString().toLowerCase().trim();
      if (vStr == 'true' || vStr == '1') return const RpcBool(true);
      if (vStr == 'false' || vStr == '0') return const RpcBool(false);

      // Fallback for anything else.
      return const RpcBool(false);
    } catch (e) {
      return const RpcBool(false);
    }
  }

  static RpcCodec<RpcBool> get codec => RpcCodec<RpcBool>(RpcBool.fromJson);

  @override
  String toString() => value.toString();
}
