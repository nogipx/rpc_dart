part of '_index.dart';

// Параметры для usecase
@freezed
abstract class StartRegistrationParams with _$StartRegistrationParams implements IRpcSerializable {
  const factory StartRegistrationParams({required String userId}) = _StartRegistrationParams;

  static IRpcCodec<StartRegistrationParams> get codec => RpcCodec(StartRegistrationParams.fromJson);

  factory StartRegistrationParams.fromJson(Map<String, dynamic> json) =>
      _$StartRegistrationParamsFromJson(json);
}

// Результат выполнения usecase
@freezed
abstract class StartRegistrationResult with _$StartRegistrationResult implements IRpcSerializable {
  const StartRegistrationResult._();
  const factory StartRegistrationResult({RegistrationOptions? options, WebAuthnException? error}) =
      _StartRegistrationResult;

  static IRpcCodec<StartRegistrationResult> get codec => RpcCodec(StartRegistrationResult.fromJson);

  factory StartRegistrationResult.fromJson(Map<String, dynamic> json) =>
      _$StartRegistrationResultFromJson(json);

  // Фабричный метод для создания успешного результата
  factory StartRegistrationResult.success(RegistrationOptions options) {
    return StartRegistrationResult(options: options);
  }

  factory StartRegistrationResult.failure(WebAuthnException error) {
    return StartRegistrationResult(error: error, options: null);
  }
}

// UseCase для начала процесса регистрации WebAuthn
class StartRegistrationUseCase {
  final IChallengeRepository _challengeRepository;
  final String _rpId;
  final String _rpName;

  const StartRegistrationUseCase(
    this._challengeRepository, {
    required String rpId,
    required String rpName,
  })  : _rpId = rpId,
        _rpName = rpName;

  // Выполнение usecase
  Future<StartRegistrationResult> execute(
    StartRegistrationParams params, {
    List<int>? precomputedChallenge,
  }) async {
    // Генерация случайного challenge или использование предвычисленного для тестов
    final challenge = precomputedChallenge ?? _generateRandomBytes(32);

    // Сохранение challenge в репозитории
    await _challengeRepository.storeChallenge(params.userId, challenge);

    // Создание опций регистрации
    return StartRegistrationResult.success(
      RegistrationOptions(
        challenge: challenge,
        rpId: _rpId,
        rpName: _rpName,
        userId: params.userId,
        pubKeyCredParams: [
          {'type': 'public-key', 'alg': -7}, // ES256
          {'type': 'public-key', 'alg': -257}, // RS256
        ],
        authenticatorSelection: {
          'authenticatorAttachment': 'platform',
          'userVerification': 'preferred',
          'requireResidentKey': false,
        },
        timeout: 60000,
        attestation: 'direct',
      ),
    );
  }

  // Генерация случайных байтов для challenge
  List<int> _generateRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
