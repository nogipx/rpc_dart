// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for a string value.
class RpcString extends RpcPrimitiveMessage<String> {
  const RpcString(super.value);

  /// Creates RpcString from JSON.
  factory RpcString.fromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v == null) return const RpcString('');
      if (v is String) return RpcString(v);
      return RpcString(v.toString());
    } catch (e) {
      return const RpcString('');
    }
  }

  static RpcCodec<RpcString> get codec =>
      RpcCodec<RpcString>(RpcString.fromJson);

  @override
  String toString() => value;
}
