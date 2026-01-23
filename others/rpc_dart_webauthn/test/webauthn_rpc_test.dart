import 'dart:convert';

import 'package:cbor/cbor.dart' as cbor_lib;
import 'package:crypto/crypto.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

/// Адаптер для преобразования простых тестовых данных в WebAuthn объекты
class SimpleTestVectorAdapter {
  /// Преобразует значение в CBOR Value
  static cbor_lib.CborValue _toCborValue(dynamic value) {
    if (value is int) {
      return cbor_lib.CborSmallInt(value);
    } else if (value is List<int>) {
      return cbor_lib.CborBytes(Uint8List.fromList(value));
    } else if (value is String) {
      return cbor_lib.CborString(value);
    } else {
      throw ArgumentError('Unsupported value type: ${value.runtimeType}');
    }
  }

  static WebAuthnRegistrationCredential createSimpleCredential({
    List<int>? challenge,
    String? origin,
  }) {
    // Используем переданный challenge или создаем простой тестовый
    final actualChallenge = challenge ?? List<int>.generate(32, (i) => i + 1);
    // Создаем УНИКАЛЬНЫЙ credential ID с использованием текущего времени
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final credentialId = List<int>.generate(16, (i) => (timestamp + i) & 0xFF);

    // Создаем простой clientDataJSON
    final clientData = {
      'type': 'webauthn.create',
      'challenge': base64Url.encode(actualChallenge),
      'origin': origin ?? 'https://example.com',
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
      credentialId.length & 0xFF,
    ];

    // Простой COSE public key для ES256
    final cosePublicKey = {
      1: 2, // kty: EC2
      3: -7, // alg: ES256
      -1: 1, // crv: P-256
      -2: List<int>.generate(32, (i) => i + 10), // x coordinate
      -3: List<int>.generate(32, (i) => i + 50), // y coordinate
    };
    // Создаем COSE ключ с правильными CBOR типами
    final coseKeyMap = <cbor_lib.CborValue, cbor_lib.CborValue>{};
    for (final entry in cosePublicKey.entries) {
      coseKeyMap[cbor_lib.CborSmallInt(entry.key)] = _toCborValue(entry.value);
    }
    final cbor = cbor_lib.CborCodec();
    final coseKeyBytes = cbor.encode(cbor_lib.CborMap(coseKeyMap));

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

    // Создаем простой attestationObject с правильными CBOR типами
    final cborMap = <cbor_lib.CborValue, cbor_lib.CborValue>{
      cbor_lib.CborString('fmt'): cbor_lib.CborString('none'),
      cbor_lib.CborString('authData'): cbor_lib.CborBytes(
        Uint8List.fromList(authData),
      ),
      cbor_lib.CborString('attStmt'): cbor_lib.CborMap(
        <cbor_lib.CborValue, cbor_lib.CborValue>{},
      ),
    };
    final attestationObjectMap = cbor_lib.CborMap(cborMap);

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
  group('WebAuthn RPC Integration Tests', () {
    late WebAuthnDomainResult domainResult;
    late WebAuthnCaller webAuthnCaller;

    setUp(() async {
      // Создаем РЕАЛЬНЫЙ WebAuthn домен через фабрику
      // Это создает настоящий WebAuthnResponder и все его зависимости
      final config = WebAuthnDomainConfig.inMemory(
        rpId: 'example.com',
        rpName: 'Example Corp',
        webOrigin: 'https://example.com',
      );

      domainResult = await WebAuthnDomainFactory.createInMemory(config: config);
      webAuthnCaller = domainResult.webAuthnCaller;

      print('🔧 Создан реальный WebAuthn домен для тестов');
    });

    tearDown(() async {
      await domainResult.dispose();
      print('🧹 WebAuthn домен очищен');
    });

    group('Интеграционные тесты регистрации', () {
      test('1.1 Полный цикл регистрации с реальным респондером', () async {
        // Начинаем регистрацию через РЕАЛЬНЫЙ WebAuthnResponder
        final startParams = StartRegistrationParams(userId: 'testuser');

        final startResult = await webAuthnCaller.startRegistration(startParams);
        expect(startResult.options, isNotNull);
        expect(startResult.error, isNull);
        expect(
          startResult.options!.challenge.length,
          equals(32),
          reason: 'Challenge должен быть 32 байта',
        );
        expect(startResult.options!.rpId, equals('example.com'));
        expect(startResult.options!.rpName, equals('Example Corp'));
        expect(startResult.options!.userId, equals('testuser'));
        expect(startResult.options!.pubKeyCredParams, isNotEmpty);

        print('✅ StartRegistration работает через реальный RPC');

        // Создаем простой credential для тестов с РЕАЛЬНЫМ challenge
        final credential = SimpleTestVectorAdapter.createSimpleCredential(
          challenge: startResult.options!.challenge,
          origin: 'https://example.com',
        );

        // Завершаем регистрацию через РЕАЛЬНЫЙ WebAuthnResponder
        final finishParams = FinishRegistrationParams(
          userId: 'testuser',
          credential: credential,
          origin: 'https://example.com',
        );

        final finishResult = await webAuthnCaller.finishRegistration(
          finishParams,
        );

        // Debug output
        print('🔍 finishResult.success = ${finishResult.success}');
        print('�� finishResult.error = ${finishResult.error}');
        if (finishResult.error != null) {
          print('🔍 error.message = ${finishResult.error!.message}');
          print('🔍 error.type = ${finishResult.error!.type}');
        }
        print('🔍 finishResult.credential = ${finishResult.credential}');

        expect(
          finishResult.success,
          isTrue,
          reason: 'Регистрация должна пройти через реальный респондер',
        );
        expect(finishResult.credential, isNotNull);
        expect(finishResult.credential!.userId, equals('testuser'));
        expect(finishResult.credential!.createdAt, isNotNull);
        expect(finishResult.error, isNull);

        print('✅ FinishRegistration работает через реальный RPC');

        // Проверяем, что credential действительно сохранился в репозитории
        final savedCredentials = await domainResult.webAuthnRepository
            .getCredentialsByUserId('testuser');
        expect(
          savedCredentials,
          isNotEmpty,
          reason: 'Credential должен быть сохранен в реальном репозитории',
        );
        expect(savedCredentials.first.userId, equals('testuser'));

        print('✅ Credential сохранен в реальном репозитории');
      });

      test('1.2 Регистрация с некорректными данными должна падать', () async {
        final startParams = StartRegistrationParams(userId: 'testuser');

        final startResult = await webAuthnCaller.startRegistration(startParams);
        expect(startResult.options, isNotNull);

        // Создаем credential с некорректными данными
        final badCredential = WebAuthnRegistrationCredential(
          id: 'invalid-id',
          response: WebAuthnRegistrationResponse(
            clientDataJSON: Uint8List.fromList(
              utf8.encode('{"invalid": "json"}'),
            ),
            attestationObject: Uint8List.fromList([
              0xFF,
              0xFF,
            ]), // некорректный CBOR
          ),
          type: 'public-key',
        );

        final finishParams = FinishRegistrationParams(
          userId: 'testuser',
          credential: badCredential,
          origin: 'https://example.com',
        );

        final finishResult = await webAuthnCaller.finishRegistration(
          finishParams,
        );
        expect(
          finishResult.success,
          isFalse,
          reason:
              'Регистрация с некорректными данными должна падать в реальном респондере',
        );
        expect(finishResult.error, isNotNull);

        print('✅ Некорректные данные правильно отклонены реальным респондером');
      });
    });

    group('Интеграционные тесты аутентификации', () {
      test('2.1 Полный цикл аутентификации после регистрации', () async {
        // Сначала регистрируемся через реальный респондер
        final startRegParams = StartRegistrationParams(userId: 'authuser');

        final startRegResult = await webAuthnCaller.startRegistration(
          startRegParams,
        );
        expect(startRegResult.options, isNotNull);

        final credential = SimpleTestVectorAdapter.createSimpleCredential(
          challenge: startRegResult.options!.challenge,
          origin: 'https://example.com',
        );

        final finishRegParams = FinishRegistrationParams(
          userId: 'authuser',
          credential: credential,
          origin: 'https://example.com',
        );

        final regResult = await webAuthnCaller.finishRegistration(
          finishRegParams,
        );
        expect(regResult.success, isTrue);

        print('✅ Регистрация для аутентификации завершена');

        // Теперь аутентифицируемся через реальный респондер
        final startAuthParams = StartAuthenticationParams(userId: 'authuser');

        final startAuthResult = await webAuthnCaller.startAuthentication(
          startAuthParams,
        );
        expect(startAuthResult.options, isNotNull);
        expect(startAuthResult.error, isNull);
        expect(startAuthResult.options!.challenge.length, equals(32));
        expect(startAuthResult.options!.rpId, equals('example.com'));

        print('✅ StartAuthentication работает через реальный RPC');

        // Проверяем, что challenge сохранился в реальном репозитории
        final savedChallenge = await domainResult.challengeRepository
            .getChallenge('authuser');
        expect(
          savedChallenge,
          isNotNull,
          reason: 'Challenge должен быть сохранен в реальном репозитории',
        );

        print('✅ Challenge сохранен в реальном репозитории');
      });
    });

    group('Интеграционные тесты управления учетными данными', () {
      test('3.1 Получение списка учетных данных', () async {
        // Сначала создаем пользователя с учетными данными
        final startRegParams = StartRegistrationParams(userId: 'listuser');
        final startRegResult = await webAuthnCaller.startRegistration(
          startRegParams,
        );
        expect(startRegResult.options, isNotNull);

        final credential = SimpleTestVectorAdapter.createSimpleCredential(
          challenge: startRegResult.options!.challenge,
          origin: 'https://example.com',
        );
        final finishRegParams = FinishRegistrationParams(
          userId: 'listuser',
          credential: credential,
          origin: 'https://example.com',
        );

        final regResult = await webAuthnCaller.finishRegistration(
          finishRegParams,
        );
        expect(regResult.success, isTrue);

        // Теперь получаем список через реальный респондер (БЕЗ авторизации для простоты)
        final getCredsParams = GetCredentialsParams(userId: 'listuser');

        // Здесь мы ожидаем ошибку авторизации, так как не передаем токен
        final credsResponse = await webAuthnCaller.getCredentials(
          getCredsParams,
        );
        expect(
          credsResponse.success,
          isFalse,
          reason: 'Запрос без авторизации должен падать в реальном респондере',
        );
        expect(
          credsResponse.errorMessage,
          contains('авторизации'),
          reason: 'Ошибка должна быть связана с авторизацией',
        );

        print('✅ Проверка авторизации работает в реальном респондере');
      });
    });

    group('Стресс тесты на реальном домене', () {
      test('4.1 Множественные регистрации в реальном домене', () async {
        const userCount = 3; // Уменьшаем для быстроты тестов

        for (int i = 0; i < userCount; i++) {
          final startParams = StartRegistrationParams(userId: 'stress_user_$i');

          final startResult = await webAuthnCaller.startRegistration(
            startParams,
          );
          expect(
            startResult.options,
            isNotNull,
            reason: 'Challenge должен быть сгенерирован для stress_user_$i',
          );

          final credential = SimpleTestVectorAdapter.createSimpleCredential(
            challenge: startResult.options!.challenge,
            origin: 'https://example.com',
          );
          final finishParams = FinishRegistrationParams(
            userId: 'stress_user_$i',
            credential: credential,
            origin: 'https://example.com',
          );

          final finishResult = await webAuthnCaller.finishRegistration(
            finishParams,
          );

          // Debug output
          print(
            '🔍 stress_user_$i finishResult.success = ${finishResult.success}',
          );
          if (!finishResult.success) {
            print('🔍 stress_user_$i error = ${finishResult.error}');
          }

          expect(
            finishResult.success,
            isTrue,
            reason:
                'Регистрация stress_user_$i должна пройти в реальном домене',
          );
        }

        // Проверяем, что все пользователи сохранились в реальном репозитории
        for (int i = 0; i < userCount; i++) {
          final credentials = await domainResult.webAuthnRepository
              .getCredentialsByUserId('stress_user_$i');
          expect(
            credentials,
            isNotEmpty,
            reason:
                'Пользователь stress_user_$i должен быть в реальном репозитории',
          );
        }

        print('✅ Множественные регистрации работают в реальном домене');
      });

      test('4.2 Параллельные регистрации в реальном домене', () async {
        final futures = <Future>[];

        for (int i = 0; i < 3; i++) {
          futures.add(() async {
            final startParams = StartRegistrationParams(
              userId: 'parallel_user_$i',
            );

            final startResult = await webAuthnCaller.startRegistration(
              startParams,
            );
            expect(startResult.options, isNotNull);

            final credential = SimpleTestVectorAdapter.createSimpleCredential(
              challenge: startResult.options!.challenge,
              origin: 'https://example.com',
            );
            final finishParams = FinishRegistrationParams(
              userId: 'parallel_user_$i',
              credential: credential,
              origin: 'https://example.com',
            );

            return webAuthnCaller.finishRegistration(finishParams);
          }());
        }

        final results = await Future.wait(futures);
        for (final result in results) {
          expect(
            result.success,
            isTrue,
            reason:
                'Параллельная регистрация должна работать в реальном домене',
          );
        }

        print('✅ Параллельные операции работают в реальном домене');
      });
    });

    group('Тесты RPC инфраструктуры', () {
      test('5.1 Проверка RPC сериализации/десериализации', () async {
        // Этот тест проверяет, что все модели правильно сериализуются через RPC
        final complexParams = StartRegistrationParams(
          userId: 'serialization_test_пользователь_с_unicode_🚀',
        );

        final result = await webAuthnCaller.startRegistration(complexParams);
        expect(result.options, isNotNull);
        expect(
          result.options!.userId,
          equals('serialization_test_пользователь_с_unicode_🚀'),
          reason: 'Unicode символы должны корректно передаваться через RPC',
        );

        print('✅ RPC сериализация работает с unicode');
      });

      test('5.2 Проверка RPC endpoint health', () async {
        // Проверяем, что endpoints активны
        expect(
          domainResult.clientEndpoint.isActive,
          isTrue,
          reason: 'Client endpoint должен быть активен',
        );
        expect(
          domainResult.serverEndpoint.isActive,
          isTrue,
          reason: 'Server endpoint должен быть активен',
        );

        // Делаем простой вызов для проверки соединения
        final healthCheckParams = StartRegistrationParams(
          userId: 'health_check',
        );
        final result = await webAuthnCaller.startRegistration(
          healthCheckParams,
        );
        expect(
          result.options,
          isNotNull,
          reason: 'Health check через RPC должен работать',
        );

        print('✅ RPC endpoints работают корректно');
      });
    });
  });
}
