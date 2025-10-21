import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

void main() {
  group('StartRegistrationUseCase', () {
    late IChallengeRepository challengeRepository;
    late StartRegistrationUseCase useCase;

    setUp(() {
      challengeRepository = MemoryChallengeRepositoryImpl();

      useCase = StartRegistrationUseCase(
        challengeRepository,
        rpId: 'example.com',
        rpName: 'Example App',
      );
    });

    test('должен генерировать опции регистрации и сохранять challenge',
        () async {
      // Arrange
      final params = StartRegistrationParams(userId: '1');

      // Act
      final result = await useCase.execute(params);

      // Assert
      expect(result, isNotNull);
      expect(result.options?.challenge, isNotEmpty);
      expect(result.options?.rpId, equals('example.com'));
      expect(result.options?.rpName, equals('Example App'));
      expect(result.options?.userId, equals('1'));

      // Проверяем, что challenge был сохранен в репозитории
      final savedChallenge = await challengeRepository.getChallenge('1');
      expect(savedChallenge, equals(result.options?.challenge));
    });

    test('должен иметь корректные параметры для pubKeyCredParams', () async {
      // Arrange
      final params = StartRegistrationParams(userId: '1');

      // Act
      final result = await useCase.execute(params);

      // Assert
      expect(result.options?.pubKeyCredParams, isNotEmpty);

      // Должны быть алгоритмы ES256 и RS256
      expect(
        result.options?.pubKeyCredParams
            .any((p) => p['alg'] == -7 && p['type'] == 'public-key'),
        isTrue,
      );
      expect(
        result.options?.pubKeyCredParams
            .any((p) => p['alg'] == -257 && p['type'] == 'public-key'),
        isTrue,
      );
    });

    test('должен иметь корректные параметры аутентификатора', () async {
      // Arrange
      final params = StartRegistrationParams(userId: '1');

      // Act
      final result = await useCase.execute(params);

      // Assert
      expect(result.options?.authenticatorSelection, isNotNull);
      expect(result.options?.authenticatorSelection['authenticatorAttachment'],
          equals('platform'));
      expect(result.options?.authenticatorSelection['userVerification'],
          equals('preferred'));
      expect(result.options?.authenticatorSelection['requireResidentKey'],
          equals(false));
    });

    test('должен конвертировать опции в формат для клиента', () async {
      // Arrange
      final params = StartRegistrationParams(userId: '1');

      // Act
      final options = await useCase.execute(params);
      final clientFormat = options.toJson()['options'].toJson();

      // Assert
      expect(clientFormat, isNotNull);
      expect(clientFormat, isA<Map<String, dynamic>>());
      expect(clientFormat['publicKey'], isNotNull);
      expect(clientFormat['publicKey']['challenge'], isNotNull);
      expect(clientFormat['publicKey']['rp'], isNotNull);
      expect(clientFormat['publicKey']['user'], isNotNull);
      expect(clientFormat['publicKey']['pubKeyCredParams'], isNotNull);
    });
  });
}
