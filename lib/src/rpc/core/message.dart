// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '../_index.dart';

/// Представляет отдельный HTTP/2 заголовок.
///
/// HTTP/2 передает заголовки в бинарном виде через HPACK-сжатие, но
/// на уровне API они представлены в виде пар "имя-значение".
/// Специальные заголовки в HTTP/2 начинаются с двоеточия (например, :path).
final class RpcHeader {
  /// Имя заголовка
  final String name;

  /// Значение заголовка
  final String value;

  /// Создает заголовок с указанным именем и значением
  const RpcHeader(this.name, this.value);
}

/// Метаданные запроса или ответа (набор HTTP/2 заголовков).
///
/// В gRPC метаданные передаются через HTTP/2 заголовки и трейлеры.
/// Этот класс обеспечивает удобный доступ к ним и содержит
/// фабричные методы для создания стандартных наборов заголовков.
final class RpcMetadata {
  /// Список заголовков, составляющих метаданные
  final List<RpcHeader> headers;

  /// Создает метаданные из списка заголовков
  const RpcMetadata(this.headers);

  /// Создает метаданные для клиентского запроса.
  ///
  /// Формирует необходимые HTTP/2 заголовки для инициализации gRPC вызова.
  /// [serviceName] Имя сервиса (например, "ChatService")
  /// [methodName] Имя метода (например, "Send")
  /// [host] Хост-заголовок (опционально)
  /// Возвращает метаданные, готовые для отправки при инициализации запроса.
  static RpcMetadata forClientRequest(String serviceName, String methodName,
      {String host = ''}) {
    final methodPath = '/$serviceName/$methodName';
    return RpcMetadata([
      RpcHeader(':method', 'POST'),
      RpcHeader(':path', methodPath),
      RpcHeader(':scheme', 'http'),
      RpcHeader(':authority', host),
      RpcHeader(
        RpcConstants.CONTENT_TYPE_HEADER,
        RpcConstants.GRPC_CONTENT_TYPE,
      ),
      RpcHeader('te', 'trailers'),
    ]);
  }

  /// Создает метаданные для клиентского запроса с готовым путем.
  ///
  /// Упрощенная версия для случаев, когда путь уже сформирован.
  /// [methodPath] Путь метода в формате /ServiceName/MethodName
  /// [host] Хост-заголовок (опционально)
  static RpcMetadata forClientRequestWithPath(String methodPath,
      {String host = ''}) {
    return RpcMetadata([
      RpcHeader(':method', 'POST'),
      RpcHeader(':path', methodPath),
      RpcHeader(':scheme', 'http'),
      RpcHeader(':authority', host),
      RpcHeader(
        RpcConstants.CONTENT_TYPE_HEADER,
        RpcConstants.GRPC_CONTENT_TYPE,
      ),
      RpcHeader('te', 'trailers'),
    ]);
  }

  /// Создает начальные метаданные для ответа сервера.
  ///
  /// Формирует HTTP/2 заголовки, которые сервер отправляет клиенту
  /// при получении запроса, до отправки каких-либо данных.
  /// Возвращает метаданные, готовые для отправки в начале ответа.
  static RpcMetadata forServerInitialResponse() {
    return RpcMetadata([
      RpcHeader(':status', '200'),
      RpcHeader(
        RpcConstants.CONTENT_TYPE_HEADER,
        RpcConstants.GRPC_CONTENT_TYPE,
      ),
    ]);
  }

  /// Создает метаданные для финального трейлера.
  ///
  /// Формирует заголовки-трейлеры, которые отправляются в конце потока
  /// и содержат статус выполнения операции gRPC.
  /// [statusCode] Код завершения gRPC (см. RpcStatus)
  /// [message] Дополнительное сообщение (обычно при ошибке)
  /// Возвращает метаданные-трейлеры для завершения потока.
  static RpcMetadata forTrailer(int statusCode, {String message = ''}) {
    final headers = [
      RpcHeader(
        RpcConstants.GRPC_STATUS_HEADER,
        statusCode.toString(),
      ),
    ];

    if (message.isNotEmpty) {
      headers.add(RpcHeader(
        RpcConstants.GRPC_MESSAGE_HEADER,
        message,
      ));
    }

    return RpcMetadata(headers);
  }

  /// Находит значение заголовка по его имени.
  ///
  /// [name] Имя искомого заголовка
  /// Возвращает значение заголовка или null, если заголовок не найден.
  String? getHeaderValue(String name) {
    for (var header in headers) {
      if (header.name == name) {
        return header.value;
      }
    }
    return null;
  }

  /// Извлекает путь метода из метаданных.
  ///
  /// Ищет заголовок :path и возвращает его значение.
  /// Возвращает null, если заголовок не найден.
  String? get methodPath => getHeaderValue(':path');

  /// Извлекает имя сервиса из пути метода.
  ///
  /// Парсит путь вида /ServiceName/MethodName и возвращает ServiceName.
  /// Возвращает null, если путь некорректен или не найден.
  String? get serviceName {
    final path = methodPath;
    if (path == null || !path.startsWith('/')) return null;

    final parts = path.substring(1).split('/');
    return parts.isNotEmpty ? parts[0] : null;
  }

  /// Извлекает имя метода из пути метода.
  ///
  /// Парсит путь вида /ServiceName/MethodName и возвращает MethodName.
  /// Возвращает null, если путь некорректен или не найден.
  String? get methodName {
    final path = methodPath;
    if (path == null || !path.startsWith('/')) return null;

    final parts = path.substring(1).split('/');
    return parts.length >= 2 ? parts[1] : null;
  }
}

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
  /// [isEndOfStream] Флаг конца потока (для трейлеров)
  /// Возвращает сообщение, содержащее только метаданные.
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
}
