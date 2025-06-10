// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:typed_data';
import 'special_cbor.dart';

part 'codec.dart';

/// Основной интерфейс для всех RPC сообщений - работает с байтами
/// Все типы запросов и ответов должны реализовывать этот интерфейс
/// Это базовый интерфейс для binary сериализации (protobuf, msgpack, etc.)
abstract interface class IRpcSerializable {
  /// Сериализует объект в байты
  Map<String, dynamic> toJson();

  /// Десериализует объект из байтов - должен быть статическим методом
  /// static T fromBytes(Uint8List bytes);
}

/// Интерфейс для кодирования и декодирования сообщений.
///
/// Позволяет абстрагироваться от конкретного формата сериализации (JSON, Protocol Buffers,
/// MessagePack и др.). Реализации должны обеспечивать корректное преобразование объектов
/// в байты и обратно.
abstract class IRpcCodec<T> {
  /// Сериализует объект типа T в последовательность байтов.
  ///
  /// [message] Объект для сериализации.
  /// Возвращает байтовое представление объекта.
  Uint8List serialize(T message);

  /// Десериализует последовательность байтов в объект типа T.
  ///
  /// [bytes] Байты для десериализации.
  /// Возвращает объект, воссозданный из байтов.
  T deserialize(Uint8List bytes);
}
