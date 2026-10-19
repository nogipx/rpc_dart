// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for a string value.
class RpcString extends RpcPrimitiveMessage<String> {
  /// Creates an [RpcString] wrapping [value].
  const RpcString(super.value);

  /// Creates RpcString from JSON: a string; no value is the empty string.
  /// Anything else throws [FormatException] rather than being stringified.
  factory RpcString.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    if (v == null) return const RpcString('');
    if (v is String) return RpcString(v);
    throw FormatException(
      'RpcString.fromJson: cannot decode value of type ${v.runtimeType}: $v',
    );
  }

  /// Default codec for [RpcString].
  static RpcCodec<RpcString> get codec =>
      RpcCodec<RpcString>(RpcString.fromJson);

  @override
  String toString() => value;
}
