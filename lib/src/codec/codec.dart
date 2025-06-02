// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// CBOR сериализатор для RPC сообщений
class RpcCodec<T extends IRpcSerializable> implements IRpcCodec<T> {
  final T Function(Map<String, dynamic> json)? _fromJson;

  /// Создает CBOR сериализатор
  /// [fromCbor] - функция для создания объекта из CBOR Map
  RpcCodec(this._fromJson);

  @override
  Uint8List serialize(T message) {
    // Получаем JSON представление объекта
    final json = message.toJson();

    return CborCodec.encode(json);
  }

  @override
  T deserialize(Uint8List bytes) {
    final decoded = CborCodec.decode(bytes);

    // CborCodec.decode теперь всегда возвращает Map<String, dynamic>
    return _fromJson!(decoded);
  }

  /// Статический хелпер для десериализации CBOR
  static T fromBytes<T extends IRpcSerializable>({
    required Uint8List bytes,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    final decoded = CborCodec.decode(bytes);

    // CborCodec.decode уже возвращает Map<String, dynamic>
    return fromJson(decoded);
  }
}

// Преобразование LinkedMap<dynamic, dynamic> в Map<String, dynamic>
Map<String, dynamic> convertMap(Map<dynamic, dynamic> map) {
  return map.map((key, value) => MapEntry(key.toString(), value));
}
