import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// Класс, представляющий структуру данных аутентификатора (authenticator data)
class AuthenticatorData {
  /// Хеш RP ID (SHA-256)
  final Uint8List rpIdHash;

  /// Флаги (поддерживаемые функции)
  final int flags;

  /// Счетчик подписей
  final int signCount;

  /// Идентификатор AAGUID аутентификатора (если есть)
  final Uint8List? aaguid;

  /// Идентификатор учетных данных (если есть)
  final Uint8List? credentialId;

  /// COSE закодированный публичный ключ (если есть)
  final Uint8List? credentialPublicKey;

  /// Сырые данные
  final Uint8List rawData;

  /// Флаг User Present (пользователь присутствует)
  bool get isUserPresent => (flags & 0x01) != 0;

  /// Флаг User Verified (пользователь проверен)
  bool get isUserVerified => (flags & 0x04) != 0;

  /// Флаг Attested Credential Data (включены данные о учетных данных)
  bool get hasAttestedCredentialData => (flags & 0x40) != 0;

  /// Флаг Extension Data (включены данные расширений)
  bool get hasExtensionData => (flags & 0x80) != 0;

  AuthenticatorData({
    required this.rpIdHash,
    required this.flags,
    required this.signCount,
    this.aaguid,
    this.credentialId,
    this.credentialPublicKey,
    required this.rawData,
  });

  /// Фабричный метод для создания из сырых данных
  factory AuthenticatorData.fromRawData(Uint8List data) {
    if (data.length < 37) {
      throw ArgumentError('Authenticator data должен быть минимум 37 байт');
    }

    final rpIdHash = data.sublist(0, 32);
    final flags = data[32];
    final signCount = ByteData.view(data.buffer, 33, 4).getUint32(0, Endian.big);

    Uint8List? aaguid;
    Uint8List? credentialId;
    Uint8List? credentialPublicKey;

    if ((flags & 0x40) != 0) {
      // Если есть attested credential data
      if (data.length < 55) {
        throw ArgumentError('Для аттестованных данных минимальная длина 55 байт');
      }

      int offset = 37;
      aaguid = data.sublist(offset, offset + 16);
      offset += 16;

      final credIdLen = ByteData.view(data.buffer, offset, 2).getUint16(0, Endian.big);
      offset += 2;

      if (offset + credIdLen > data.length) {
        throw ArgumentError('Недостаточно данных для чтения credentialId');
      }

      credentialId = data.sublist(offset, offset + credIdLen);
      offset += credIdLen;

      if (offset < data.length) {
        credentialPublicKey = data.sublist(offset);
      }
    }

    return AuthenticatorData(
      rpIdHash: rpIdHash,
      flags: flags,
      signCount: signCount,
      aaguid: aaguid,
      credentialId: credentialId,
      credentialPublicKey: credentialPublicKey,
      rawData: data,
    );
  }
}

/// Класс, представляющий COSE публичный ключ
class CosePublicKey {
  /// Тип ключа (kty) - 1 для RSA, 2 для EC и т.д.
  final int keyType;

  /// Алгоритм (alg) - например -7 для ES256
  final int algorithm;

  /// Кривая (crv) - для EC ключей
  final int? curve;

  /// X координата - для EC ключей
  final Uint8List? x;

  /// Y координата - для EC ключей
  final Uint8List? y;

  /// Модуль (n) - для RSA ключей
  final Uint8List? n;

  /// Публичный показатель (e) - для RSA ключей
  final Uint8List? e;

  /// Сырая карта COSE ключа
  final CborMap rawMap;

  CosePublicKey({
    required this.keyType,
    required this.algorithm,
    this.curve,
    this.x,
    this.y,
    this.n,
    this.e,
    required this.rawMap,
  });

  /// Фабричный метод для создания из CBOR-декодированной карты
  factory CosePublicKey.fromMap(Map<dynamic, dynamic> map) {
    final keyType = _getIntValue(map, 1, 'kty');
    final algorithm = _getIntValue(map, 3, 'alg');

    // Инициализируем опциональные параметры
    int? curve;
    Uint8List? x;
    Uint8List? y;
    Uint8List? n;
    Uint8List? e;

    // В зависимости от типа ключа, получаем соответствующие параметры
    if (keyType == 2) {
      // EC ключ
      curve = _getIntValue(map, -1, 'crv');
      x = _getBytesValue(map, -2, 'x');
      y = _getBytesValue(map, -3, 'y');
    } else if (keyType == 3) {
      // RSA ключ
      n = _getBytesValue(map, -1, 'n');
      e = _getBytesValue(map, -2, 'e');
    }

    // Создаем совместимую CborMap для rawMap
    final rawMap = CborMap(<CborValue, CborValue>{});
    for (final entry in map.entries) {
      final key = entry.key is int
          ? (entry.key as int >= 0 ? CborSmallInt(entry.key) : CborInt(BigInt.from(entry.key)))
          : CborString(entry.key.toString());
      final value = entry.value is List<int>
          ? CborBytes(Uint8List.fromList(entry.value))
          : entry.value is int
              ? (entry.value as int >= 0
                  ? CborSmallInt(entry.value)
                  : CborInt(BigInt.from(entry.value)))
              : CborString(entry.value.toString());
      rawMap[key] = value;
    }

    return CosePublicKey(
      keyType: keyType,
      algorithm: algorithm,
      curve: curve,
      x: x,
      y: y,
      n: n,
      e: e,
      rawMap: rawMap,
    );
  }

  /// Вспомогательный метод для извлечения int значений
  static int _getIntValue(Map<dynamic, dynamic> map, dynamic key, String name) {
    final value = map[key];
    if (value is int) return value;
    if (value is BigInt) return value.toInt();

    // Обработка CBOR типов
    if (value != null &&
        (value.runtimeType.toString().contains('CborSmallInt') ||
            value.runtimeType.toString().contains('CborInt') ||
            value.runtimeType.toString().contains('_CborSmallIntImpl'))) {
      try {
        // Пробуем получить значение из CBOR Int
        if (value.value != null) {
          return value.value as int;
        } else {
          return int.parse(value.toString());
        }
      } catch (e) {
        // Fallback к toString если не удалось извлечь число
        final valueStr = value.toString();
        final parsed = int.tryParse(valueStr);
        if (parsed != null) return parsed;
      }
    }

    throw ArgumentError(
        'Поле $name ($key) отсутствует или имеет неверный тип: ${value.runtimeType}');
  }

  /// Вспомогательный метод для извлечения bytes значений
  static Uint8List? _getBytesValue(Map<dynamic, dynamic> map, dynamic key, String name) {
    final value = map[key];
    if (value == null) return null;
    if (value is Uint8List) return Uint8List.fromList(value);
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) return Uint8List.fromList((value).cast<int>());

    // Обработка CBOR bytes типов
    if (value.runtimeType.toString().contains('CborBytes') ||
        value.runtimeType.toString().contains('_CborBytesImpl')) {
      try {
        final bytes = value.bytes;
        if (bytes != null) {
          if (bytes is Uint8List) {
            return bytes;
          } else if (bytes is List<int>) {
            return Uint8List.fromList(bytes);
          } else {
            // Для Uint8Buffer и других типов
            return Uint8List.fromList(List<int>.from(bytes));
          }
        } else {
          return Uint8List.fromList(List<int>.from(value));
        }
      } catch (e) {
        try {
          return Uint8List.fromList(List<int>.from(value));
        } catch (_) {
          // Fallback failed
        }
      }
    }
    // Обработка Uint8Buffer напрямую
    else if (value.runtimeType.toString().contains('Uint8Buffer')) {
      try {
        return Uint8List.fromList(List<int>.from(value));
      } catch (e) {
        // Fallback failed
      }
    }

    throw ArgumentError('Поле $name ($key) имеет неверный тип: ${value.runtimeType}');
  }

  /// Признак того, что это ключ эллиптической кривой
  bool get isEC => keyType == 2;

  /// Признак того, что это RSA ключ
  bool get isRSA => keyType == 3;
}

/// Перечисление форматов attestation
enum AttestationStatementFormat {
  fidoU2f('fido-u2f'),
  packed('packed'),
  tpm('tpm'),
  androidKey('android-key'),
  androidSafetyNet('android-safetynet'),
  apple('apple'),
  none('none');

  final String value;
  const AttestationStatementFormat(this.value);

  static AttestationStatementFormat fromString(String value) {
    return values.firstWhere(
      (format) => format.value == value,
      orElse: () => throw ArgumentError('Неизвестный формат аттестации: $value'),
    );
  }
}

/// Перечисление типов attestation
enum AttestationType {
  basic('Basic'),
  self('Self'),
  attCa('AttCA'),
  ecdaa('ECDAA'),
  none('None');

  final String value;
  const AttestationType(this.value);
}

/// Класс результата проверки аттестации
class AttestationResult {
  /// Успешна ли проверка
  final bool success;

  /// Тип аттестации ('Basic', 'Self', 'AttCA', 'ECDAA', 'None')
  final String? attestationType;

  /// Сообщение об ошибке (если проверка не удалась)
  final String? errorMessage;

  /// Цепочка доверия (x509 сертификаты для некоторых типов аттестации)
  final List<List<int>>? trustPath;

  const AttestationResult({
    required this.success,
    this.attestationType,
    this.errorMessage,
    this.trustPath,
  });

  /// Фабричный метод для создания успешного результата
  factory AttestationResult.success({required String attestationType, List<List<int>>? trustPath}) {
    return AttestationResult(success: true, attestationType: attestationType, trustPath: trustPath);
  }

  /// Фабричный метод для создания результата с ошибкой
  factory AttestationResult.failure(String errorMessage) {
    return AttestationResult(success: false, errorMessage: errorMessage);
  }
}

/// Класс результата расшифровки attestationObject
class AttestationObjectResult {
  /// Успешна ли операция
  final bool success;

  /// Формат аттестации
  final String? format;

  /// Данные аутентификатора
  final List<int>? authData;

  /// Аттестационное заявление
  final Map<dynamic, dynamic>? attStmt;

  /// Сообщение об ошибке (если операция не удалась)
  final String? errorMessage;

  const AttestationObjectResult({
    required this.success,
    this.format,
    this.authData,
    this.attStmt,
    this.errorMessage,
  });

  /// Фабричный метод для создания успешного результата
  factory AttestationObjectResult.success({
    required String format,
    required List<int> authData,
    required Map<dynamic, dynamic> attStmt,
  }) {
    return AttestationObjectResult(
      success: true,
      format: format,
      authData: authData,
      attStmt: attStmt,
    );
  }

  /// Фабричный метод для создания результата с ошибкой
  factory AttestationObjectResult.failure(String errorMessage) {
    return AttestationObjectResult(success: false, errorMessage: errorMessage);
  }
}

/// Класс результата проверки учетных данных WebAuthn
class VerificationResult {
  /// Успешна ли проверка
  final bool success;

  /// Идентификатор учетных данных
  final String? credentialId;

  /// Публичный ключ
  final List<int>? publicKey;

  /// Идентификатор AAGUID
  final List<int>? aaguid;

  /// Тип аттестации
  final String? attestationType;

  /// Сообщение об ошибке (если проверка не удалась)
  final String? errorMessage;

  const VerificationResult({
    required this.success,
    this.credentialId,
    this.publicKey,
    this.aaguid,
    this.attestationType,
    this.errorMessage,
  });

  /// Фабричный метод для создания успешного результата
  factory VerificationResult.success({
    required String credentialId,
    required List<int> publicKey,
    List<int>? aaguid,
    String? attestationType,
  }) {
    return VerificationResult(
      success: true,
      credentialId: credentialId,
      publicKey: publicKey,
      aaguid: aaguid,
      attestationType: attestationType,
    );
  }

  /// Фабричный метод для создания результата с ошибкой
  factory VerificationResult.failure(String errorMessage) {
    return VerificationResult(success: false, errorMessage: errorMessage);
  }
}
