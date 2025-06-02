// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Структура бинарного сообщения для RPC транспортов
///
/// Используется для мультиплексирования потоков и маршрутизации сообщений
/// между клиентом и сервером.
class RpcTransportFrame {
  /// Идентификатор потока (4 байта)
  final int streamId;

  /// Тип сообщения (1 байт)
  /// 0 - метаданные
  /// 1 - данные
  final int type;

  /// Флаг завершения потока (1 байт)
  /// 0 - не завершен
  /// 1 - завершен
  final bool isEndOfStream;

  /// Путь метода (опционально)
  final String? methodPath;

  /// Типы фреймов для разделения метаданных и данных
  static const int typeMetadata = 0x01;
  static const int typeData = 0x02;

  const RpcTransportFrame({
    required this.streamId,
    required this.type,
    this.isEndOfStream = false,
    this.methodPath,
  });

  /// Сериализует заголовок в бинарный формат
  Uint8List encode() {
    // Начинаем с фиксированных полей:
    // 4 байта - streamId
    // 1 байт - тип сообщения
    // 1 байт - флаг завершения

    final List<int> result = [];

    // Добавляем streamId (big endian)
    result.add((streamId >> 24) & 0xFF);
    result.add((streamId >> 16) & 0xFF);
    result.add((streamId >> 8) & 0xFF);
    result.add(streamId & 0xFF);

    // Добавляем тип сообщения
    result.add(type);

    // Добавляем флаг завершения
    result.add(isEndOfStream ? 1 : 0);

    // Если есть путь метода, добавляем его
    if (methodPath != null) {
      final pathBytes = utf8.encode(methodPath!);
      // Добавляем длину пути (2 байта)
      result.add((pathBytes.length >> 8) & 0xFF);
      result.add(pathBytes.length & 0xFF);
      // Добавляем сам путь
      result.addAll(pathBytes);
    } else {
      // Длина пути 0
      result.add(0);
      result.add(0);
    }

    return Uint8List.fromList(result);
  }

  /// Парсит заголовок из бинарных данных
  static RpcTransportFrame? decode(Uint8List data) {
    if (data.length < 8) {
      // Минимальный размер заголовка: 4+1+1+2 = 8 байт
      return null;
    }

    // Парсим streamId (4 байта)
    final streamId =
        (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];

    // Парсим тип сообщения (1 байт)
    final type = data[4];

    // Парсим флаг завершения (1 байт)
    final isEndOfStream = data[5] == 1;

    // Парсим длину пути метода (2 байта)
    final pathLength = (data[6] << 8) | data[7];

    String? methodPath;
    if (pathLength > 0) {
      if (data.length >= 8 + pathLength) {
        methodPath = utf8.decode(data.sublist(8, 8 + pathLength));
      } else {
        return null; // Недостаточно данных
      }
    }

    return RpcTransportFrame(
      streamId: streamId,
      type: type,
      isEndOfStream: isEndOfStream,
      methodPath: methodPath,
    );
  }

  /// Размер заголовка в байтах
  static int size(String? methodPath) {
    // 4 байта (streamId) + 1 байт (тип) + 1 байт (флаг завершения) + 2 байта (длина пути)
    int headerSize = 8;
    // Если есть путь, добавляем его размер
    if (methodPath != null) {
      headerSize += utf8.encode(methodPath).length;
    }
    return headerSize;
  }

  /// Создает фрейм с метаданными
  static RpcTransportFrame metadata({
    required int streamId,
    bool isEndOfStream = false,
    String? methodPath,
  }) {
    return RpcTransportFrame(
      streamId: streamId,
      type: typeMetadata,
      isEndOfStream: isEndOfStream,
      methodPath: methodPath,
    );
  }

  /// Создает фрейм с данными
  static RpcTransportFrame data({
    required int streamId,
    bool isEndOfStream = false,
    String? methodPath,
  }) {
    return RpcTransportFrame(
      streamId: streamId,
      type: typeData,
      isEndOfStream: isEndOfStream,
      methodPath: methodPath,
    );
  }
}
