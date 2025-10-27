import 'dart:typed_data';

import 'package:cbor/cbor.dart';
import '../domain/exceptions/web_authn_exceptions.dart';
import '../domain/verifiers/_models.dart';

/// Вспомогательный класс для декодирования CBOR данных WebAuthn
class AppCborDecoder {
  // Получаем singleton инстанс декодера из пакета
  static final _cbor = cbor;

  /// Декодирование attestationObject.
  /// Выбрасывает [WebAuthnException] в случае ошибки.
  static AttestationObjectResult decodeAttestationObject(Uint8List data) {
    try {
      final decoded = _cbor.decode(data);
      return _processDecodedAttestationObject(decoded);
    } on CborMalformedException catch (e, st) {
      throw WebAuthnException.registration(
        'Ошибка декодирования attestationObject: некорректный формат CBOR. $e',
        st,
      );
    } catch (e, st) {
      // Ловим любые другие неожиданные ошибки
      throw WebAuthnException.registration(
        'Ошибка декодирования attestationObject: $e',
        st,
      );
    }
  }

  /// Декодирование публичного ключа в формате COSE.
  /// Выбрасывает [WebAuthnException] в случае ошибки.
  static CosePublicKey decodeCosePublicKey(Uint8List data) {
    try {
      final decoded = _cbor.decode(data);
      return _processCoseKey(decoded);
    } on CborMalformedException catch (e, st) {
      throw WebAuthnException.registration(
        'Ошибка декодирования COSE ключ: некорректный формат CBOR. $e',
        st,
      );
    } catch (e, st) {
      throw WebAuthnException.registration(
        'Ошибка декодирования COSE ключ: $e',
        st,
      );
    }
  }

  /// Обрабатывает декодированный attestationObject независимо от используемого декодера
  static AttestationObjectResult _processDecodedAttestationObject(
    dynamic decoded,
  ) {
    if (decoded is! Map) {
      return AttestationObjectResult.failure(
        'attestationObject не является CBOR Map',
      );
    }

    final decodedMap = <String, dynamic>{};
    for (final entry in decoded.entries) {
      // Правильно обрабатываем ключи из разных CBOR библиотек
      String keyStr;
      if (entry.key is String) {
        keyStr = entry.key as String;
      } else {
        // Для CborString и других CBOR типов используем toString()
        keyStr = entry.key.toString();
        // Убираем возможные кавычки или префиксы из toString() для CborString
        if (keyStr.startsWith('"') && keyStr.endsWith('"')) {
          keyStr = keyStr.substring(1, keyStr.length - 1);
        }
      }

      // Обрабатываем значения
      dynamic value = entry.value;

      // Для CBOR bytes (authData) - конвертируем в List<int>
      if (value != null &&
          (value.runtimeType.toString().contains('CborBytes') ||
              value.runtimeType.toString().contains('_CborBytesImpl'))) {
        // Если это CborBytes из библиотеки cbor
        try {
          // Пробуем разные способы извлечения байтов
          final bytes = value.bytes;
          if (bytes != null) {
            if (bytes is Uint8List) {
              value = bytes.toList();
            } else if (bytes is List<int>) {
              value = bytes;
            } else {
              // Для Uint8Buffer и других типов
              value = List<int>.from(bytes);
            }
          } else {
            // Fallback - может быть значение хранится в другом поле
            value = List<int>.from(value);
          }
        } catch (e) {
          // Последний fallback - пробуем toString и парсинг
          try {
            value = List<int>.from(value);
          } catch (_) {
            value = entry.value;
          }
        }
      }

      decodedMap[keyStr] = value;
    }

    final fmt = decodedMap['fmt'];

    // Преобразуем CBOR строку в обычную строку если нужно
    String? fmtString;
    if (fmt is String) {
      fmtString = fmt;
    } else if (fmt != null) {
      // Для CBOR строк используем toString() и убираем кавычки если есть
      final fmtStr = fmt.toString();
      if (fmtStr.startsWith('"') && fmtStr.endsWith('"')) {
        fmtString = fmtStr.substring(1, fmtStr.length - 1);
      } else {
        fmtString = fmtStr;
      }
    }

    if (fmtString == null || fmtString.isEmpty) {
      return AttestationObjectResult.failure(
        'attestationObject.fmt отсутствует или пуст. '
        'Получен тип: ${fmt?.runtimeType}, значение: $fmt. '
        'Ключи в decodedMap: ${decodedMap.keys.toList()}',
      );
    }

    final authData = decodedMap['authData'];

    // Преобразуем authData в List<int> если это возможно
    List<int>? authDataBytes;
    if (authData is List<int>) {
      authDataBytes = authData;
    } else if (authData is Uint8List) {
      authDataBytes = authData.toList();
    } else if (authData is List) {
      try {
        authDataBytes = (authData).cast<int>();
      } catch (e) {
        // Не удалось преобразовать
      }
    }

    if (authDataBytes == null) {
      return AttestationObjectResult.failure(
        'attestationObject.authData отсутствует или имеет неправильный формат. '
        'Получен тип: ${authData?.runtimeType}. '
        'Значение было обработано в общем коде, но все равно не преобразовалось в List<int>.',
      );
    }

    final attStmt = decodedMap['attStmt'];
    if (attStmt is! Map) {
      return AttestationObjectResult.failure(
        'attestationObject.attStmt отсутствует или не является Map. '
        'Получен тип: ${attStmt?.runtimeType}',
      );
    }

    final attStmtMap = <String, dynamic>{};
    for (final entry in attStmt.entries) {
      String keyStr;
      if (entry.key is String) {
        keyStr = entry.key as String;
      } else {
        keyStr = entry.key.toString();
        if (keyStr.startsWith('"') && keyStr.endsWith('"')) {
          keyStr = keyStr.substring(1, keyStr.length - 1);
        }
      }
      attStmtMap[keyStr] = entry.value;
    }

    return AttestationObjectResult.success(
      format: fmtString,
      authData: authDataBytes,
      attStmt: attStmtMap,
    );
  }

  /// Обрабатывает декодированный COSE ключ
  static CosePublicKey _processCoseKey(dynamic coseKey) {
    if (coseKey is! Map) {
      throw ArgumentError(
        'COSE ключ не является Map, получен: ${coseKey.runtimeType}',
      );
    }

    final keyMap = <dynamic, dynamic>{};
    for (final entry in coseKey.entries) {
      // Обрабатываем ключи - для COSE ключей ключами могут быть числа
      dynamic keyValue = entry.key;

      // Если ключ является CBOR объектом, извлекаем его значение
      if (keyValue.runtimeType.toString().contains('CborSmallInt') ||
          keyValue.runtimeType.toString().contains('CborInt') ||
          keyValue.runtimeType.toString().contains('_CborSmallIntImpl')) {
        try {
          // Пробуем получить значение из CBOR Int
          if (keyValue.value != null) {
            keyValue = keyValue.value;
          } else {
            // Для _CborSmallIntImpl пробуем прямое преобразование
            keyValue = int.parse(keyValue.toString());
          }
        } catch (e) {
          // Fallback к toString если не удалось извлечь число
          final keyStr = keyValue.toString();
          if (keyStr.contains(':')) {
            keyValue = int.tryParse(keyStr.split(':').last.trim()) ?? keyValue;
          } else {
            // Пробуем парсить напрямую
            keyValue = int.tryParse(keyStr) ?? keyValue;
          }
        }
      } else if (keyValue is! int && keyValue is! String) {
        // Для других типов используем toString
        keyValue = keyValue.toString();
      }

      // Обрабатываем значения
      dynamic value = entry.value;

      // Для CBOR integers конвертируем в int
      if (value != null &&
          (value.runtimeType.toString().contains('CborSmallInt') ||
              value.runtimeType.toString().contains('CborInt') ||
              value.runtimeType.toString().contains('_CborSmallIntImpl'))) {
        try {
          if (value.value != null) {
            value = value.value;
          } else {
            value = int.parse(value.toString());
          }
        } catch (e) {
          final valueStr = value.toString();
          value = int.tryParse(valueStr) ?? value;
        }
      }
      // Для CBOR bytes конвертируем в List<int>
      else if (value != null &&
          (value.runtimeType.toString().contains('CborBytes') ||
              value.runtimeType.toString().contains('_CborBytesImpl'))) {
        try {
          final bytes = value.bytes;
          if (bytes != null) {
            if (bytes is Uint8List) {
              value = bytes.toList();
            } else if (bytes is List<int>) {
              value = bytes;
            } else {
              // Для Uint8Buffer и других типов
              value = List<int>.from(bytes);
            }
          } else {
            value = List<int>.from(value);
          }
        } catch (e) {
          try {
            value = List<int>.from(value);
          } catch (_) {
            value = entry.value;
          }
        }
      }
      // Для Uint8Buffer напрямую конвертируем в List<int>
      else if (value != null &&
          value.runtimeType.toString().contains('Uint8Buffer')) {
        try {
          value = List<int>.from(value);
        } catch (e) {
          value = entry.value;
        }
      }

      keyMap[keyValue] = value;
    }

    try {
      return CosePublicKey.fromMap(keyMap);
    } catch (e) {
      final keysString = keyMap.keys
          .map((k) => '$k: ${keyMap[k]?.runtimeType}')
          .join(', ');
      throw ArgumentError(
        'Ошибка при преобразовании COSE карты в ключ. Ключи: {$keysString}. Ошибка: ${e.toString()}',
      );
    }
  }

  /// Парсинг объекта AuthenticatorData из байтов
  static AuthenticatorData parseAuthenticatorData(List<int> authData) {
    try {
      return AuthenticatorData.fromRawData(Uint8List.fromList(authData));
    } catch (e) {
      throw ArgumentError(
        'Ошибка при парсинге authenticator data: ${e.toString()}',
      );
    }
  }
}
