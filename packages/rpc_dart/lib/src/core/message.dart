// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'metadata.dart';

/// Обертка для gRPC сообщения с его метаданными.
///
/// Объединяет данные (payload) и метаданные (headers) в единый объект,
/// что позволяет обрабатывать разные типы данных в потоке сообщений:
/// - Сообщения с полезной нагрузкой
/// - Сообщения только с метаданными (например, трейлеры)
/// - Информацию о завершении потока
final class RpcMessage<T> {
  /// Полезная нагрузка сообщения (данные)
  final T? payload;

  /// Связанные метаданные (заголовки или трейлеры)
  final RpcMetadata? metadata;

  /// Флаг, указывающий, что сообщение содержит только метаданные
  final bool isMetadataOnly;

  /// Флаг, указывающий, что это последнее сообщение в потоке
  final bool isEndOfStream;

  /// Создает сообщение с указанными параметрами
  const RpcMessage({
    this.payload,
    this.metadata,
    this.isMetadataOnly = false,
    this.isEndOfStream = false,
  });

  /// Создает сообщение только с полезной нагрузкой (данными).
  ///
  /// Удобный фабричный метод для создания обычных сообщений с данными.
  /// [payload] Полезная нагрузка для передачи
  /// Возвращает сообщение, содержащее только данные.
  static RpcMessage<T> withPayload<T>(T payload) {
    return RpcMessage<T>(payload: payload);
  }

  /// Создает сообщение только с метаданными (заголовками или трейлерами).
  ///
  /// Удобный фабричный метод для создания сообщений с метаданными.
  /// [metadata] Метаданные для передачи
  /// [isEndOfStream] Флаг завершения потока
  static RpcMessage<T> withMetadata<T>(
    RpcMetadata metadata, {
    bool isEndOfStream = false,
  }) {
    return RpcMessage<T>(
      metadata: metadata,
      isMetadataOnly: true,
      isEndOfStream: isEndOfStream,
    );
  }

  /// Создает сообщение, обозначающее завершение потока.
  ///
  /// Используется, когда необходимо явно передать факт завершения без данных.
  static RpcMessage<T> endOfStream<T>() {
    return RpcMessage<T>(isEndOfStream: true);
  }
}
