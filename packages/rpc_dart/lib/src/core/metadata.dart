// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'compression.dart';
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
  static const int _maxGrpcMessageLength = 1024;
  static const int _maxMethodTokenLength = 128;
  static final RegExp _methodTokenPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
  static final RegExp _percentTriplet = RegExp(r'%[0-9A-Fa-f]{2}');

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
    _validateMethodToken(serviceName, 'serviceName');
    _validateMethodToken(methodName, 'methodName');
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
      RpcHeader(
        RpcConstants.grpcAcceptEncodingHeader,
        RpcGrpcCompression.supportedEncodings().join(','),
      ),
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
    if (!_isValidMethodPath(methodPath)) {
      throw ArgumentError.value(
        methodPath,
        'methodPath',
        'Некорректный путь метода (ожидается /Service/Method)',
      );
    }
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
      RpcHeader(
        RpcConstants.grpcAcceptEncodingHeader,
        RpcGrpcCompression.supportedEncodings().join(','),
      ),
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
  static RpcMetadata forTrailer(
    int statusCode, {
    String message = '',
    Uint8List? statusDetailsBin,
  }) {
    final headers = [
      RpcHeader(RpcConstants.grpcStatusHeader, statusCode.toString()),
    ];

    if (message.isNotEmpty) {
      headers.add(
        RpcHeader(
          RpcConstants.grpcMessageHeader,
          encodeGrpcMessage(message),
        ),
      );
    }

    if (statusDetailsBin != null && statusDetailsBin.isNotEmpty) {
      headers.add(
        RpcHeader(
          RpcConstants.grpcStatusDetailsBinHeader,
          base64Encode(statusDetailsBin),
        ),
      );
    }

    return RpcMetadata(headers);
  }

  /// Parses `grpc-timeout` into a [Duration].
  ///
  /// Format: 1-8 digits followed by a unit:
  /// `H` hours, `M` minutes, `S` seconds, `m` milliseconds,
  /// `u` microseconds, `n` nanoseconds.
  static Duration? parseGrpcTimeout(String raw) {
    final value = raw.trim();
    if (value.length < 2 || value.length > 9) return null;

    final unit = value[value.length - 1];
    final digits = value.substring(0, value.length - 1);
    if (digits.isEmpty || digits.length > 8) return null;

    final amount = int.tryParse(digits);
    if (amount == null || amount < 0) return null;

    switch (unit) {
      case 'H':
        return Duration(hours: amount);
      case 'M':
        return Duration(minutes: amount);
      case 'S':
        return Duration(seconds: amount);
      case 'm':
        return Duration(milliseconds: amount);
      case 'u':
        return Duration(microseconds: amount);
      case 'n':
        if (amount == 0) return Duration.zero;
        final micros = amount ~/ 1000;
        return Duration(microseconds: micros == 0 ? 1 : micros);
      default:
        return null;
    }
  }

  /// Encodes a [Duration] into `grpc-timeout` format.
  ///
  /// Chooses the largest unit that fits into 8 digits.
  static String encodeGrpcTimeout(Duration timeout) {
    final micros = timeout.inMicroseconds;
    if (micros <= 0) return '0u';

    String? tryUnit(int value, String unit) {
      if (value < 0) return null;
      if (value.toString().length > 8) return null;
      return '$value$unit';
    }

    final hours = timeout.inHours;
    final hoursEncoded = tryUnit(hours, 'H');
    if (hoursEncoded != null) return hoursEncoded;

    final minutes = timeout.inMinutes;
    final minutesEncoded = tryUnit(minutes, 'M');
    if (minutesEncoded != null) return minutesEncoded;

    final seconds = timeout.inSeconds;
    final secondsEncoded = tryUnit(seconds, 'S');
    if (secondsEncoded != null) return secondsEncoded;

    final millis = timeout.inMilliseconds;
    final millisEncoded = tryUnit(millis, 'm');
    if (millisEncoded != null) return millisEncoded;

    final microsEncoded = tryUnit(micros, 'u');
    if (microsEncoded != null) return microsEncoded;

    // Fall back to max 8 digits microseconds.
    return '99999999u';
  }

  Uint8List? get statusDetailsBin {
    final raw = getHeaderValue(RpcConstants.grpcStatusDetailsBinHeader);
    if (raw == null || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
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
    if (parts.isEmpty || parts[0].isEmpty) return null;
    return parts[0];
  }

  /// Извлекает имя метода из пути метода.
  ///
  /// Парсит путь вида /ServiceName/MethodName и возвращает MethodName.
  /// Возвращает null, если путь некорректен или не найден.
  String? get methodName {
    final path = methodPath;
    if (path == null || !path.startsWith('/')) return null;

    final parts = path.substring(1).split('/');
    if (parts.length < 2 || parts[1].isEmpty) return null;
    return parts[1];
  }

  /// Percent-encode `grpc-message` per gRPC HTTP/2 spec (RFC 3986).
  ///
  /// Encodes the UTF-8 bytes of [message]. Unreserved bytes
  /// (`A-Z a-z 0-9 - . _ ~`) are left as-is; all other bytes are encoded as
  /// `%HH` with uppercase hex. Result is truncated to [_maxGrpcMessageLength]
  /// without cutting an incomplete `%HH` triplet.
  static String encodeGrpcMessage(String message) {
    final bytes = Uint8List.fromList(utf8.encode(message));
    final out = StringBuffer();

    for (final b in bytes) {
      if (_isUnreservedByte(b)) {
        out.writeCharCode(b);
      } else {
        out.write('%');
        out.write(_toUpperHex(b >> 4));
        out.write(_toUpperHex(b & 0x0F));
      }
      if (out.length >= _maxGrpcMessageLength) {
        break;
      }
    }

    var encoded = out.toString();
    if (encoded.length > _maxGrpcMessageLength) {
      encoded = encoded.substring(0, _maxGrpcMessageLength);
    }
    return _trimIncompletePercentTriplet(encoded);
  }

  /// Best-effort decode of percent-encoded `grpc-message`.
  ///
  /// Returns [encoded] unchanged if it doesn't look percent-encoded or if
  /// decoding fails.
  static String decodeGrpcMessage(String encoded, {int maxLength = 1024}) {
    var input = encoded;
    if (input.length > maxLength) {
      input = _trimIncompletePercentTriplet(input.substring(0, maxLength));
    }
    if (!input.contains('%') || !_percentTriplet.hasMatch(input)) {
      return input;
    }

    final bytes = <int>[];
    for (var i = 0; i < input.length; i++) {
      final ch = input.codeUnitAt(i);
      if (ch == 0x25 /* % */ && i + 2 < input.length) {
        final hi = _fromHex(input.codeUnitAt(i + 1));
        final lo = _fromHex(input.codeUnitAt(i + 2));
        if (hi != null && lo != null) {
          bytes.add((hi << 4) | lo);
          i += 2;
          continue;
        }
      }
      if (ch > 0xFF) {
        return input;
      }
      bytes.add(ch);
    }

    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return input;
    }
  }

  static bool _isUnreservedByte(int b) {
    // ALPHA / DIGIT / "-" / "." / "_" / "~"
    return (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
  }

  static String _trimIncompletePercentTriplet(String value) {
    if (!value.contains('%')) return value;
    if (value.endsWith('%')) {
      return value.substring(0, value.length - 1);
    }
    if (value.length >= 2 && value[value.length - 2] == '%') {
      return value.substring(0, value.length - 2);
    }
    return value;
  }

  static String _toUpperHex(int v) =>
      String.fromCharCode(v < 10 ? (0x30 + v) : (0x41 + (v - 10)));

  static int? _fromHex(int codeUnit) {
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
    if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
    if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
    return null;
  }

  static void _validateMethodToken(String value, String label) {
    if (value.isEmpty ||
        value.length > _maxMethodTokenLength ||
        value.contains('/') ||
        value.contains('\r') ||
        value.contains('\n') ||
        !_methodTokenPattern.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        label,
        'Некорректное имя (разрешены A-Z a-z 0-9 _ . -)',
      );
    }
  }

  static bool _isValidMethodPath(String methodPath) {
    if (methodPath.isEmpty ||
        methodPath.length > (_maxMethodTokenLength * 2 + 2) ||
        !methodPath.startsWith('/')) {
      return false;
    }
    final parts = methodPath.substring(1).split('/');
    if (parts.length != 2) return false;
    if (parts[0].isEmpty || parts[1].isEmpty) return false;
    return _methodTokenPattern.hasMatch(parts[0]) &&
        _methodTokenPattern.hasMatch(parts[1]);
  }
}
