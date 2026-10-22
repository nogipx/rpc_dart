// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// CBOR serializer for RPC messages.
class RpcCodec<T extends IRpcSerializable> implements IRpcCodec<T> {
  final T Function(Map<String, dynamic> json) _fromJson;

  /// Creates a CBOR serializer; [fromJson] builds an object from the decoded
  /// map.
  const RpcCodec(T Function(Map<String, dynamic> json) fromJson)
    : _fromJson = fromJson;

  @override
  Uint8List serialize(T message) => RpcCborCodec.encode(message.toJson());

  @override
  T deserialize(Uint8List bytes) => _fromJson(RpcCborCodec.decode(bytes));
}
