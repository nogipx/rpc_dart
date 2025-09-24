// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// Универсальный бинарный кодек.
///
/// Позволяет подключить произвольную бинарную сериализацию (например, Protocol
/// Buffers) без необходимости добавлять внешние зависимости в ядро. Пользователь
/// передает функции преобразования в байты и обратно.
class RpcBinaryCodec<T> implements IRpcCodec<T> {
  final Uint8List Function(T value) _toBytes;
  final T Function(Uint8List bytes) _fromBytes;

  const RpcBinaryCodec({
    required Uint8List Function(T value) toBytes,
    required T Function(Uint8List bytes) fromBytes,
  })  : _toBytes = toBytes,
        _fromBytes = fromBytes;

  @override
  Uint8List serialize(T message) => _toBytes(message);

  @override
  T deserialize(Uint8List bytes) => _fromBytes(bytes);
}
