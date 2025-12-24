// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Wrapper for null.
class RpcNull extends RpcPrimitiveMessage<void> {
  const RpcNull() : super(null);

  static RpcNull fromJson(Map<String, dynamic> json) {
    return RpcNull();
  }

  static RpcNull fromBytes(Uint8List bytes) {
    return RpcNull();
  }

  static RpcCodec<RpcNull> get codec => RpcCodec<RpcNull>(RpcNull.fromJson);

  @override
  String toString() => null.toString();
}
