import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'base64_utils.dart';

/// Вспомогательный класс для криптографических операций
class WebAuthnCryptoUtils {
  /// Преобразование строки в уникальный идентификатор
  static int getUserId(String userName) {
    // Создаем SHA-256 хеш от строки
    var bytes = utf8.encode(userName);
    var digest = sha256.convert(bytes);

    // Берем первые 14-15 символов для надежности и делаем mod для гарантии попадания в диапазон int
    var hexValue = digest.toString().substring(0, 14);
    var uniqueId =
        int.parse(hexValue, radix: 16) %
        (1 << 53); // Безопасный диапазон для целых чисел

    return uniqueId;
  }

  /// Преобразование байтов в шестнадцатеричную строку
  static String bytesToHex(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Преобразование байтов в BigInt
  static BigInt bytesToBigInt(List<int> bytes) {
    String hex = bytesToHex(bytes);
    return BigInt.parse('0x$hex');
  }

  /// Создание EC публичного ключа из координат X и Y
  static ECPublicKey createECPublicKeyFromCoordinates(
    String curveName,
    List<int> xBytes,
    List<int> yBytes,
  ) {
    try {
      // Преобразуем байты в BigInt
      final x = bytesToBigInt(xBytes);
      final y = bytesToBigInt(yBytes);

      // Логируем для отладки
      print('Создание EC ключа из координат:');
      print('Кривая: $curveName');
      print('X: $x (${xBytes.length} байт)');
      print('Y: $y (${yBytes.length} байт)');

      // Получаем параметры кривой
      final curveParams = getCurveParametersByName(curveName);

      // Создаем ECPoint
      final q = curveParams.curve.createPoint(x, y);

      // Создаем ECPublicKey
      return ECPublicKey(q, curveParams);
    } catch (e) {
      print('Ошибка при создании EC ключа из координат: ${e.toString()}');
      rethrow;
    }
  }

  /// Получение параметров кривой по имени
  static ECDomainParameters getCurveParametersByName(String curveName) {
    switch (curveName) {
      case 'prime256v1': // P-256
      case 'P-256': // NIST P-256
      case 'secp256r1': // Еще одно название P-256
        return ECCurve_secp256r1();
      case 'secp384r1': // P-384
      case 'P-384': // NIST P-384
        return ECCurve_secp384r1();
      case 'secp521r1': // P-521
      case 'P-521': // NIST P-521
        return ECCurve_secp521r1();
      default:
        throw ArgumentError('Неподдерживаемая кривая: $curveName');
    }
  }

  /// Получение имени кривой по параметру crv из COSE ключа
  static String getCurveNameByCoseParam(int crv) {
    switch (crv) {
      case 1:
        // Для P-256 (prime256v1, secp256r1)
        return 'P-256';
      case 2:
        // Для P-384 (secp384r1)
        return 'P-384';
      case 3:
        // Для P-521 (secp521r1)
        return 'P-521';
      default:
        throw ArgumentError('Неизвестный параметр crv: $crv');
    }
  }

  /// Преобразование COSE публичного ключа в формат PEM
  static List<int> coseKeyToPem(dynamic coseKeyInput) {
    // Поддерживаем как Map, так и CosePublicKey
    int keyType;
    int? curve;
    List<int>? x;
    List<int>? y;

    if (coseKeyInput is Map<dynamic, dynamic>) {
      // Старый формат - Map
      keyType = coseKeyInput[1] as int? ?? 0;
      curve = coseKeyInput[-1] as int?;
      x = coseKeyInput[-2] != null
          ? (coseKeyInput[-2] as List<dynamic>).cast<int>()
          : null;
      y = coseKeyInput[-3] != null
          ? (coseKeyInput[-3] as List<dynamic>).cast<int>()
          : null;
    } else {
      // Новый формат - CosePublicKey объект
      final coseKey = coseKeyInput;
      keyType = coseKey.keyType;
      curve = coseKey.curve;
      x = coseKey.x?.toList();
      y = coseKey.y?.toList();
    }

    if (keyType == 2) {
      // EC ключ
      if (curve == null) {
        throw ArgumentError('COSE ключ не содержит параметр crv');
      }

      if (x == null || y == null) {
        throw ArgumentError('COSE ключ не содержит координаты x или y');
      }

      try {
        // Получаем название кривой
        final curveName = getCurveNameByCoseParam(curve);

        // Для всех EC ключей используем простое JSON представление
        final keyMap = {
          'curve': curveName,
          'x': WebAuthnSafeBase64.encode(x),
          'y': WebAuthnSafeBase64.encode(y),
        };

        final jsonKey = json.encode(keyMap);
        return utf8.encode(jsonKey);
      } catch (e) {
        // Подробное логирование ошибки для отладки
        print('Ошибка при создании EC ключа: ${e.toString()}');
        print('Параметры: crv=$curve, x=${x.length} байт, y=${y.length} байт');
        throw ArgumentError('Ошибка при создании EC ключа: ${e.toString()}');
      }
    } else if (keyType == 3) {
      // RSA ключ
      throw UnimplementedError('Преобразование RSA ключа недоступно');
    } else {
      throw ArgumentError('Неподдерживаемый тип ключа: $keyType');
    }
  }

  /// Проверка, что два списка байт одинаковы
  static bool compareBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Создание JSON-представления публичного ключа EC
  static String publicKeyToJson(ECPublicKey publicKey) {
    // Получаем координаты точки
    final q = publicKey.Q!;
    final x = q.x?.toBigInteger();
    final y = q.y?.toBigInteger();

    if (x == null || y == null) {
      throw ArgumentError('Координаты точки EC не могут быть null');
    }

    // Преобразуем BigInteger в байты
    final xBytes = encodeBigInt(x);
    final yBytes = encodeBigInt(y);

    // Определяем имя кривой
    String curveName = 'unknown';
    if (publicKey.parameters is ECCurve_secp256r1) {
      curveName = 'P-256';
    } else if (publicKey.parameters is ECCurve_secp384r1) {
      curveName = 'P-384';
    } else if (publicKey.parameters is ECCurve_secp521r1) {
      curveName = 'P-521';
    }

    // Создаем JSON-объект
    final keyMap = {
      'curve': curveName,
      'x': WebAuthnSafeBase64.encode(xBytes),
      'y': WebAuthnSafeBase64.encode(yBytes),
    };

    return json.encode(keyMap);
  }

  /// Создание EC-ключа из JSON-представления
  static ECPublicKey publicKeyFromJson(String jsonString) {
    try {
      final keyMap = json.decode(jsonString) as Map<String, dynamic>;

      // Извлекаем имя кривой и координаты
      final curveName = keyMap['curve'] as String;
      final xBase64 = keyMap['x'] as String;
      final yBase64 = keyMap['y'] as String;

      // Преобразуем Base64 в BigInt
      final x = decodeBigInt(
        Uint8List.fromList(WebAuthnSafeBase64.decode(xBase64)),
      );
      final y = decodeBigInt(
        Uint8List.fromList(WebAuthnSafeBase64.decode(yBase64)),
      );

      // Выбираем кривую по имени
      ECDomainParameters curve;
      switch (curveName) {
        case 'P-256':
          curve = ECCurve_secp256r1();
          break;
        case 'P-384':
          curve = ECCurve_secp384r1();
          break;
        case 'P-521':
          curve = ECCurve_secp521r1();
          break;
        default:
          throw ArgumentError('Неизвестная кривая: $curveName');
      }

      // Создаем точку на кривой и публичный ключ
      final q = curve.curve.createPoint(x, y);
      return ECPublicKey(q, curve);
    } catch (e) {
      throw FormatException('Невозможно создать EC ключ из JSON: $e');
    }
  }

  // Вспомогательный метод для кодирования BigInt в байты
  static Uint8List encodeBigInt(BigInt number) {
    // Преобразуем в шестнадцатеричную строку
    var hexString = number.toRadixString(16);

    // Добавляем ведущий ноль, если нужно
    if (hexString.length % 2 != 0) {
      hexString = '0$hexString';
    }

    // Конвертируем в байты
    final byteLength = hexString.length ~/ 2;
    final result = Uint8List(byteLength);

    for (var i = 0; i < byteLength; i++) {
      final byteString = hexString.substring(i * 2, i * 2 + 2);
      result[i] = int.parse(byteString, radix: 16);
    }

    return result;
  }

  // Вспомогательный метод для декодирования BigInt из байтов
  static BigInt decodeBigInt(Uint8List bytes) {
    // Преобразуем байты в шестнадцатеричную строку
    var hexString = bytesToHex(bytes);

    // Добавляем ведущий ноль, если нужно
    if (hexString.length % 2 != 0) {
      hexString = '0$hexString';
    }

    // Преобразуем шестнадцатеричную строку в BigInt
    return BigInt.parse('0x$hexString');
  }

  /// Напрямую проверяет WebAuthn подпись без использования сторонних библиотек
  static bool verifyWebAuthnSignature(
    Uint8List signedData,
    Uint8List signature,
    String curveName,
    String xBase64,
    String yBase64,
  ) {
    // Декодируем координаты из base64
    final xBytes = Uint8List.fromList(WebAuthnSafeBase64.decode(xBase64));
    final yBytes = Uint8List.fromList(WebAuthnSafeBase64.decode(yBase64));

    // Создаем публичный ключ напрямую
    final ecParams = getCurveParametersByName(curveName);
    final x = bytesToBigInt(xBytes);
    final y = bytesToBigInt(yBytes);
    final q = ecParams.curve.createPoint(x, y);
    final publicKey = ECPublicKey(q, ecParams);

    // Извлекаем r и s из подписи в DER формате
    BigInt? rValue;
    BigInt? sValue;

    if (signature.isNotEmpty && signature[0] == 0x30) {
      // Парсим DER подпись
      ASN1Parser parser = ASN1Parser(signature);
      ASN1Sequence sequence = parser.nextObject() as ASN1Sequence;

      if (sequence.elements.length == 2) {
        ASN1Integer rAsn1 = sequence.elements[0] as ASN1Integer;
        ASN1Integer sAsn1 = sequence.elements[1] as ASN1Integer;

        rValue = rAsn1.valueAsBigInteger;
        sValue = sAsn1.valueAsBigInteger;

        // Создаем верификатор
        final verifier = ECDSASigner(SHA256Digest());
        final params = PublicKeyParameter<ECPublicKey>(publicKey);
        verifier.init(false, params);

        // Создаем подпись
        final ecSignature = ECSignature(rValue, sValue);

        // ВАЖНО: Используем сырые данные без дополнительного хеширования
        // Это ключевой момент для работы с WebAuthn!
        return verifier.verifySignature(signedData, ecSignature);
      }
    } else if (signature.length == 64) {
      // Поддержка raw формата (r||s) для полноты
      // Извлекаем r и s как первые и вторые 32 байта
      final r = bytesToBigInt(signature.sublist(0, 32));
      final s = bytesToBigInt(signature.sublist(32));

      // Создаем верификатор
      final verifier = ECDSASigner(SHA256Digest());
      final params = PublicKeyParameter<ECPublicKey>(publicKey);
      verifier.init(false, params);

      // Создаем подпись
      final ecSignature = ECSignature(r, s);

      // Используем сырые данные без дополнительного хеширования
      return verifier.verifySignature(signedData, ecSignature);
    }

    // Не удалось проверить подпись ни одним из способов
    return false;
  }

  /// Преобразует WebAuthn подпись в формат DER для проверки
  static Uint8List webAuthnToDerSignature(Uint8List rawSignature) {
    // Если подпись уже похожа на DER (начинается с 0x30), просто вернем её
    if (rawSignature.isNotEmpty && rawSignature[0] == 0x30) {
      return rawSignature;
    }

    // Проверка на размер для raw формата r||s
    if (rawSignature.length != 64) {
      throw ArgumentError(
        'WebAuthn подпись должна быть 64 байта (32 для r + 32 для s)',
      );
    }

    // Разделяем r и s компоненты
    final r = rawSignature.sublist(0, 32);
    final s = rawSignature.sublist(32);

    // Преобразуем байты в BigInt
    final rBigInt = bytesToBigInt(r);
    final sBigInt = bytesToBigInt(s);

    // Используем логику для создания DER
    final rBytes = encodeBigInt(rBigInt);
    final sBytes = encodeBigInt(sBigInt);

    return _createDerSignature(rBytes, sBytes);
  }

  /// Создает DER подпись из компонентов r и s
  static Uint8List _createDerSignature(Uint8List r, Uint8List s) {
    // Убеждаемся, что числа положительные по DER правилам
    final rBytes = _ensurePositive(r);
    final sBytes = _ensurePositive(s);

    // Вычисляем общую длину последовательности
    final totalLength = 2 + rBytes.length + 2 + sBytes.length;

    // Создаем буфер для DER последовательности
    final result = BytesBuilder();

    // Добавляем тег SEQUENCE и длину
    result.addByte(0x30); // Тег SEQUENCE
    result.addByte(totalLength);

    // Добавляем компонент r
    result.addByte(0x02); // Тег INTEGER
    result.addByte(rBytes.length);
    result.add(rBytes);

    // Добавляем компонент s
    result.addByte(0x02); // Тег INTEGER
    result.addByte(sBytes.length);
    result.add(sBytes);

    return result.toBytes();
  }

  /// Убеждается, что BigInt представлен как положительное число в DER
  static Uint8List _ensurePositive(Uint8List bytes) {
    if (bytes.isEmpty) {
      return Uint8List.fromList([0]);
    }

    // Если старший бит первого байта установлен, добавляем ведущий ноль
    if (bytes[0] & 0x80 != 0) {
      final result = Uint8List(bytes.length + 1);
      result[0] = 0;
      result.setRange(1, result.length, bytes);
      return result;
    }

    return bytes;
  }
}
