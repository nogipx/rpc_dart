import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/simple.dart';
import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

/// Простой адаптер для создания корректных WebAuthn тестовых данных
class SimpleTestVectorAdapter {
  static WebAuthnRegistrationCredential createSimpleCredential() {
    // Создаем простые тестовые данные
    final challenge = List<int>.generate(32, (i) => i + 1); // простой challenge
    final credentialId =
        List<int>.generate(16, (i) => i * 2); // простой credential ID

    // Создаем простой clientDataJSON
    final clientData = {
      'type': 'webauthn.create',
      'challenge': base64Url.encode(challenge),
      'origin': 'https://example.com'
    };
    final clientDataJSON = utf8.encode(json.encode(clientData));

    // Создаем простые authenticator data
    final rpIdHash = sha256.convert(utf8.encode('example.com')).bytes;
    final flags = 0x45; // UP + UV + AT flags
    final signCount = [0, 0, 0, 0]; // 32-bit big-endian counter

    // Простой AAGUID (16 bytes)
    final aaguid = List<int>.generate(16, (i) => 0);

    // Длина credential ID (2 bytes big-endian)
    final credIdLength = [
      (credentialId.length >> 8) & 0xFF,
      credentialId.length & 0xFF
    ];

    // Простой COSE public key для ES256
    final cosePublicKey = {
      1: 2, // kty: EC2
      3: -7, // alg: ES256
      -1: 1, // crv: P-256
      -2: List<int>.generate(32, (i) => i + 10), // x coordinate
      -3: List<int>.generate(32, (i) => i + 50), // y coordinate
    };
    final coseKeyBytes = cbor.encode(cosePublicKey);

    // Собираем authenticator data
    final authData = <int>[
      ...rpIdHash,
      flags,
      ...signCount,
      ...aaguid,
      ...credIdLength,
      ...credentialId,
      ...coseKeyBytes,
    ];

    // Создаем простой attestationObject
    final attestationObjectMap = {
      'fmt': 'none',
      'authData': Uint8List.fromList(authData),
      'attStmt': <String, dynamic>{},
    };

    final attestationObject = cbor.encode(attestationObjectMap);

    return WebAuthnRegistrationCredential(
      id: base64Url.encode(credentialId),
      response: WebAuthnRegistrationResponse(
        clientDataJSON: Uint8List.fromList(clientDataJSON),
        attestationObject: Uint8List.fromList(attestationObject),
      ),
      type: 'public-key',
    );
  }
}

void main() {
  group('Simple WebAuthn RPC Tests', () {
    setUp(() {
      // Здесь должна быть реальная имплементация контракта
      // Пока что просто пропускаем тест если нет имплементации
    });

    group('Простые тесты регистрации', () {
      test('1.1 Создание корректного credential объекта', () {
        // Тестируем только создание корректного объекта
        final credential = SimpleTestVectorAdapter.createSimpleCredential();

        expect(credential.id, isNotEmpty);
        expect(credential.response.clientDataJSON, isNotEmpty);
        expect(credential.response.attestationObject, isNotEmpty);
        expect(credential.type, equals('public-key'));

        // Проверяем что clientDataJSON можно распарсить
        final decodedClientData = credential.decodedClientData;
        expect(decodedClientData, isNotNull);
        expect(decodedClientData!['type'], equals('webauthn.create'));
        expect(decodedClientData['origin'], equals('https://example.com'));

        print('✅ Корректный credential объект создан!');
      });

      test('1.2 CBOR encoding/decoding работает корректно', () {
        // Проверяем что наш CBOR действительно правильно кодируется/декодируется
        final testMap = {
          'fmt': 'none',
          'authData': Uint8List.fromList([1, 2, 3, 4]),
          'attStmt': <String, dynamic>{},
        };

        final encoded = cbor.encode(testMap);
        expect(encoded, isNotEmpty);

        final decoded = cbor.decode(encoded) as Map;
        expect(decoded, isMap);
        expect(decoded['fmt'], equals('none'));
        // CBOR декодер может возвращать List<int> вместо Uint8List
        expect(
            decoded['authData'], anyOf([isA<Uint8List>(), isA<List<int>>()]));

        print('✅ CBOR кодирование/декодирование работает!');
      });

      test('1.3 Проверка структуры attestationObject', () {
        final credential = SimpleTestVectorAdapter.createSimpleCredential();

        // Декодируем attestationObject и проверяем структуру
        final attestationObject =
            cbor.decode(credential.response.attestationObject) as Map;

        expect(attestationObject, isMap);
        expect(attestationObject['fmt'], equals('none'));
        expect(attestationObject['authData'],
            anyOf([isA<Uint8List>(), isA<List<int>>()]));
        expect(attestationObject['attStmt'], isMap);

        // Проверяем что authData имеет правильную длину
        final authDataRaw = attestationObject['authData'];
        final authData = authDataRaw is Uint8List
            ? authDataRaw
            : Uint8List.fromList(authDataRaw as List<int>);
        expect(
            authData.length,
            greaterThan(
                37)); // минимум для RP ID hash + flags + counter + AAGUID

        print('✅ Структура attestationObject корректна!');
      });
    });

    group('Тесты валидации', () {
      test('2.1 Некорректный CBOR должен отклоняться', () {
        expect(() {
          cbor.decode(Uint8List.fromList([0xFF, 0xFF]));
        }, throwsA(isA<Exception>()));

        print('✅ Некорректный CBOR правильно отклоняется');
      });

      test('2.2 Некорректный JSON должен отклоняться', () {
        expect(() {
          json.decode('{"invalid": json}');
        }, throwsA(isA<FormatException>()));

        print('✅ Некорректный JSON правильно отклоняется');
      });
    });

    group('Стресс тесты', () {
      test('3.1 Множественные создания credential', () {
        for (int i = 0; i < 10; i++) {
          final credential = SimpleTestVectorAdapter.createSimpleCredential();
          expect(credential.id, isNotEmpty);
        }

        print('✅ Множественные создания credential работают');
      });

      test('3.2 Большие данные', () {
        // Тестируем с большими COSE ключами
        final largeCoseKey = {
          1: 2, // kty: EC2
          3: -7, // alg: ES256
          -1: 1, // crv: P-256
          -2: List<int>.generate(32, (i) => i + 100), // x coordinate
          -3: List<int>.generate(32, (i) => i + 200), // y coordinate
          // Добавляем дополнительные поля
          'extra': List<int>.generate(1000, (i) => i % 256),
        };

        final encoded = cbor.encode(largeCoseKey);
        expect(encoded, isNotEmpty);

        final decoded = cbor.decode(encoded);
        expect(decoded, isMap);

        print('✅ Большие данные обрабатываются корректно');
      });
    });
  });
}
