part of '_index.dart';

// Параметры для usecase
@freezed
abstract class StartRegistrationParams
    with _$StartRegistrationParams
    implements IRpcSerializable {
  const factory StartRegistrationParams({
    required String userId,
    List<int>? userHandle,
    String? username,
    String? displayName,
  }) = _StartRegistrationParams;

  static IRpcCodec<StartRegistrationParams> get codec =>
      RpcCodec(StartRegistrationParams.fromJson);

  factory StartRegistrationParams.fromJson(Map<String, dynamic> json) =>
      _$StartRegistrationParamsFromJson(json);
}

// Результат выполнения usecase
@freezed
abstract class StartRegistrationResult
    with _$StartRegistrationResult
    implements IRpcSerializable {
  const StartRegistrationResult._();
  const factory StartRegistrationResult({
    RegistrationOptions? options,
    WebAuthnException? error,
  }) = _StartRegistrationResult;

  static IRpcCodec<StartRegistrationResult> get codec =>
      RpcCodec(StartRegistrationResult.fromJson);

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
  final WebAuthnSettings _settings;

  const StartRegistrationUseCase(
    this._challengeRepository, {
    required WebAuthnSettings settings,
  }) : _settings = settings;

  // Выполнение usecase
  Future<StartRegistrationResult> execute(
    StartRegistrationParams params, {
    List<int>? precomputedChallenge,
  }) async {
    // Генерация случайного challenge или использование предвычисленного для тестов
    final challenge = precomputedChallenge ?? _generateRandomBytes(32);

    // Сохранение challenge в репозитории
    await _challengeRepository.storeChallenge(
      params.userId,
      challenge,
      expiresInSeconds: _settings.challengeTimeout,
    );

    final userHandle = params.userHandle ?? utf8.encode(params.userId);
    final username = params.username ?? params.userId;
    final displayName = params.displayName ?? username;

    // Создание опций регистрации
    return StartRegistrationResult.success(
      RegistrationOptions(
        challenge: challenge,
        rpId: _settings.rpId,
        rpName: _settings.rpName,
        userId: params.userId,
        userHandle: userHandle,
        userName: username,
        userDisplayName: displayName,
        pubKeyCredParams: [
          {'type': 'public-key', 'alg': -7}, // ES256
          {'type': 'public-key', 'alg': -257}, // RS256
        ],
        authenticatorSelection: {
          'authenticatorAttachment': 'platform',
          'userVerification': _settings.requireUserVerification
              ? 'required'
              : 'preferred',
          'requireResidentKey': false,
        },
        timeout: _settings.challengeTimeout * 1000,
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
