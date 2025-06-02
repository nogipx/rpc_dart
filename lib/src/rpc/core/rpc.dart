// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// ignore_for_file: constant_identifier_names

part of '../_index.dart';

/// Константы протокола gRPC.
///
/// Содержит все фиксированные значения, используемые в протоколе gRPC,
/// что обеспечивает единообразие и устраняет "магические числа" в коде.
abstract interface class RpcConstants {
  /// Размер префикса сообщения в байтах (1 байт флаг + 4 байта длина)
  static const int MESSAGE_PREFIX_SIZE = 5;

  /// Позиция флага сжатия в префиксе
  static const int COMPRESSION_FLAG_INDEX = 0;

  /// Позиция начала поля длины сообщения в префиксе
  static const int MESSAGE_LENGTH_INDEX = 1;

  /// Если сообщение не сжато, используется это значение
  static const int NO_COMPRESSION = 0;

  /// Если сообщение сжато, используется это значение
  static const int COMPRESSED = 1;

  /// HTTP заголовок, содержащий статус gRPC
  static const String GRPC_STATUS_HEADER = 'grpc-status';

  /// HTTP заголовок, содержащий сообщение об ошибке
  static const String GRPC_MESSAGE_HEADER = 'grpc-message';

  /// HTTP заголовок для типа контента
  static const String CONTENT_TYPE_HEADER = 'content-type';

  /// Тип контента для gRPC
  static const String GRPC_CONTENT_TYPE = 'application/grpc';
}

/// Стандартные коды состояний gRPC.
///
/// Определяет все возможные статусы завершения операций gRPC.
/// Ключевые статусы:
/// - OK (0): успешное выполнение
/// - CANCELLED (1): операция была отменена
/// - DEADLINE_EXCEEDED (4): превышено время ожидания
/// - INTERNAL (13): внутренняя ошибка сервера
/// - UNAVAILABLE (14): сервис недоступен
abstract interface class RpcStatus {
  /// Успешное выполнение
  static const int OK = 0;

  /// Операция отменена
  static const int CANCELLED = 1;

  /// Неизвестная ошибка
  static const int UNKNOWN = 2;

  /// Неверный аргумент
  static const int INVALID_ARGUMENT = 3;

  /// Превышено время ожидания
  static const int DEADLINE_EXCEEDED = 4;

  /// Ресурс не найден
  static const int NOT_FOUND = 5;

  /// Ресурс уже существует
  static const int ALREADY_EXISTS = 6;

  /// Отказано в доступе
  static const int PERMISSION_DENIED = 7;

  /// Ресурс исчерпан
  static const int RESOURCE_EXHAUSTED = 8;

  /// Предусловие не выполнено
  static const int FAILED_PRECONDITION = 9;

  /// Операция прервана
  static const int ABORTED = 10;

  /// Выход за пределы диапазона
  static const int OUT_OF_RANGE = 11;

  /// Не реализовано
  static const int UNIMPLEMENTED = 12;

  /// Внутренняя ошибка
  static const int INTERNAL = 13;

  /// Сервис недоступен
  static const int UNAVAILABLE = 14;

  /// Потеря данных
  static const int DATA_LOSS = 15;

  /// Не аутентифицирован
  static const int UNAUTHENTICATED = 16;
}

/// Утилитарный класс для работы с форматом сообщений gRPC.
///
/// Обеспечивает упаковку и распаковку сообщений в соответствии
/// со стандартом gRPC - добавление 5-байтного префикса к сериализованным данным
/// и извлечение информации из этого префикса.
///
/// Формат префикса:
/// - 1-й байт: флаг сжатия (0 или 1)
/// - 2-5-й байты: длина сообщения (uint32, big-endian)
abstract interface class RpcMessageFrame {
  /// Упаковывает сообщение в формат gRPC с 5-байтным префиксом.
  ///
  /// Добавляет к сериализованному сообщению стандартный 5-байтный префикс,
  /// содержащий информацию о сжатии и длине сообщения.
  ///
  /// [messageBytes] Байты сериализованного сообщения
  /// [compressed] Флаг, указывающий, сжато ли сообщение
  /// Возвращает полностью упакованное сообщение с префиксом
  static Uint8List encode(
    Uint8List messageBytes, {
    bool compressed = false,
  }) {
    final result = List<int>.filled(
        RpcConstants.MESSAGE_PREFIX_SIZE + messageBytes.length, 0);

    // Устанавливаем флаг сжатия
    result[RpcConstants.COMPRESSION_FLAG_INDEX] =
        compressed ? RpcConstants.COMPRESSED : RpcConstants.NO_COMPRESSION;

    // Устанавливаем длину сообщения (big-endian)
    final length = messageBytes.length;
    result[RpcConstants.MESSAGE_LENGTH_INDEX] = (length >> 24) & 0xFF;
    result[RpcConstants.MESSAGE_LENGTH_INDEX + 1] = (length >> 16) & 0xFF;
    result[RpcConstants.MESSAGE_LENGTH_INDEX + 2] = (length >> 8) & 0xFF;
    result[RpcConstants.MESSAGE_LENGTH_INDEX + 3] = length & 0xFF;

    // Копируем данные сообщения
    for (int i = 0; i < messageBytes.length; i++) {
      result[RpcConstants.MESSAGE_PREFIX_SIZE + i] = messageBytes[i];
    }

    return Uint8List.fromList(result);
  }

  /// Парсит заголовок сообщения, извлекая информацию о сжатии и длине.
  ///
  /// Анализирует 5-байтный префикс сообщения gRPC и извлекает
  /// информацию о сжатии и длине полезной нагрузки.
  ///
  /// [headerBytes] Байты, содержащие префикс сообщения (должно быть >= 5 байт)
  /// Возвращает структуру с информацией о сжатии и длине сообщения
  /// Выбрасывает Exception при неверной длине входных данных
  static RpcMessageHeader parseHeader(Uint8List headerBytes) {
    if (headerBytes.length < RpcConstants.MESSAGE_PREFIX_SIZE) {
      throw Exception('Неверная длина заголовка сообщения');
    }

    final isCompressed = headerBytes[RpcConstants.COMPRESSION_FLAG_INDEX] ==
        RpcConstants.COMPRESSED;

    final length = (headerBytes[RpcConstants.MESSAGE_LENGTH_INDEX] << 24) |
        (headerBytes[RpcConstants.MESSAGE_LENGTH_INDEX + 1] << 16) |
        (headerBytes[RpcConstants.MESSAGE_LENGTH_INDEX + 2] << 8) |
        headerBytes[RpcConstants.MESSAGE_LENGTH_INDEX + 3];

    return RpcMessageHeader(isCompressed, length);
  }
}

/// Информация, извлеченная из 5-байтного префикса сообщения gRPC.
///
/// Хранит данные о сжатии и длине сообщения, полученные при
/// парсинге префикса сообщения.
final class RpcMessageHeader {
  /// Флаг, указывающий, сжато ли сообщение
  final bool isCompressed;

  /// Длина полезной нагрузки сообщения в байтах
  final int messageLength;

  /// Создает объект с информацией о заголовке сообщения
  RpcMessageHeader(this.isCompressed, this.messageLength);
}
