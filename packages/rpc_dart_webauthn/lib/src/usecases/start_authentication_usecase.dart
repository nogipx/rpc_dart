part of '_index.dart';

// Параметры для usecase
@freezed
abstract class StartAuthenticationParams
    with _$StartAuthenticationParams
    implements IRpcSerializable {
  const factory StartAuthenticationParams({required String userId}) = _StartAuthenticationParams;

  static IRpcCodec<StartAuthenticationParams> get codec =>
      RpcCodec(StartAuthenticationParams.fromJson);

  factory StartAuthenticationParams.fromJson(Map<String, dynamic> json) =>
      _$StartAuthenticationParamsFromJson(json);
}

// Результат выполнения usecase
@freezed
abstract class StartAuthenticationResult
    with _$StartAuthenticationResult
    implements IRpcSerializable {
  const StartAuthenticationResult._();
  const factory StartAuthenticationResult({
    AuthenticationOptions? options,
    WebAuthnException? error,
  }) = _StartAuthenticationResult;

  static IRpcCodec<StartAuthenticationResult> get codec =>
      RpcCodec(StartAuthenticationResult.fromJson);

  factory StartAuthenticationResult.fromJson(Map<String, dynamic> json) =>
      _$StartAuthenticationResultFromJson(json);

  // Фабричный метод для создания успешного результата
  factory StartAuthenticationResult.success(AuthenticationOptions options) {
    return StartAuthenticationResult(options: options);
  }

  factory StartAuthenticationResult.failure(WebAuthnException error) {
    return StartAuthenticationResult(error: error, options: null);
  }
}

// UseCase для начала процесса аутентификации WebAuthn
class StartAuthenticationUseCase {
  final IWebAuthnRepository _webAuthnRepository;
  final IChallengeRepository _challengeRepository;
  final WebAuthnSettings _settings;

  const StartAuthenticationUseCase(
    this._webAuthnRepository,
    this._challengeRepository, {
    required WebAuthnSettings settings,
  }) : _settings = settings;

  // Выполнение usecase
  Future<StartAuthenticationResult> execute(StartAuthenticationParams params) async {
    // 1. Генерация случайного challenge
    final challenge = _generateRandomBytes(32);

    // 2. Сохранение challenge в репозитории
    await _challengeRepository.storeChallenge(
      params.userId,
      challenge,
      expiresInSeconds: _settings.challengeTimeout,
    );

    // 3. Получение всех учетных данных пользователя
    final credentials = await _webAuthnRepository.getCredentialsByUserId(params.userId);

    if (credentials.isEmpty) {
      final errorMessage = 'У пользователя нет зарегистрированных учетных данных';
      return StartAuthenticationResult.failure(WebAuthnException.credential(errorMessage));
    }

    // 4. Формирование списка допустимых учетных данных
    final allowCredentials = credentials
        .map(
          (cred) => {
            'id': cred.credentialId,
            'type': 'public-key',
            'transports': ['internal', 'usb', 'ble', 'nfc'],
          },
        )
        .toList();

    // 5. Создание опций аутентификации
    final options = AuthenticationOptions(
      challenge: challenge,
      timeout: _settings.challengeTimeout * 1000, // в миллисекундах
      rpId: _settings.rpId,
      allowCredentials: allowCredentials,
      userVerification: _settings.requireUserVerification ? 'required' : 'preferred',
    );

    return StartAuthenticationResult.success(options);
  }

  // Генерация случайных байтов для challenge
  List<int> _generateRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
