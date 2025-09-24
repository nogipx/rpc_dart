// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'protocol.dart';

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
  static RpcMetadata forClientRequest(
    String serviceName,
    String methodName, {
    String host = '',
  }) {
    final methodPath = '/$serviceName/$methodName';
    return RpcMetadata([
      const RpcHeader(':method', 'POST'),
      RpcHeader(':path', methodPath),
      const RpcHeader(':scheme', 'http'),
      RpcHeader(':authority', host),
      const RpcHeader(
        RpcConstants.contentTypeHeader,
        RpcConstants.grpcContentType,
      ),
      const RpcHeader('te', 'trailers'),
    ]);
  }

  /// Создает метаданные для клиентского запроса с готовым путем.
  ///
  /// Упрощенная версия для случаев, когда путь уже сформирован.
  /// [methodPath] Путь метода в формате /ServiceName/MethodName
  /// [host] Хост-заголовок (опционально)
  static RpcMetadata forClientRequestWithPath(
    String methodPath, {
    String host = '',
  }) {
    return RpcMetadata([
      const RpcHeader(':method', 'POST'),
      RpcHeader(':path', methodPath),
      const RpcHeader(':scheme', 'http'),
      RpcHeader(':authority', host),
      const RpcHeader(
        RpcConstants.contentTypeHeader,
        RpcConstants.grpcContentType,
      ),
      const RpcHeader('te', 'trailers'),
    ]);
  }

  /// Создает начальные метаданные для ответа сервера.
  ///
  /// Формирует HTTP/2 заголовки, которые сервер отправляет клиенту
  /// при получении запроса, до отправки каких-либо данных.
  /// Возвращает метаданные, готовые для отправки в начале ответа.
  static RpcMetadata forServerInitialResponse() {
    return const RpcMetadata([
      RpcHeader(':status', '200'),
      RpcHeader(
        RpcConstants.contentTypeHeader,
        RpcConstants.grpcContentType,
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
      RpcHeader(RpcConstants.grpcStatusHeader, statusCode.toString()),
    ];

    if (message.isNotEmpty) {
      headers.add(RpcHeader(RpcConstants.grpcMessageHeader, message));
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
