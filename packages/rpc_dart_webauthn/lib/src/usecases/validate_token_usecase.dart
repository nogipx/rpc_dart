part of '_index.dart';

/// Параметры для валидации токена
@freezed
abstract class ValidateTokenParams with _$ValidateTokenParams implements IRpcSerializable {
  factory ValidateTokenParams({
    required String token,
    WebAuthnAuthContext? context,
  }) = _ValidateTokenParams;

  static IRpcCodec<ValidateTokenParams> get codec => RpcCodec(ValidateTokenParams.fromJson);

  factory ValidateTokenParams.fromJson(Map<String, dynamic> json) =>
      _$ValidateTokenParamsFromJson(json);
}

/// Результат валидации токена
@freezed
abstract class ValidateTokenResult with _$ValidateTokenResult implements IRpcSerializable {
  factory ValidateTokenResult._({
    required bool isValid,
    WebAuthnCredentialPublic? credential,
    WebAuthnAuthContext? context,
    String? errorMessage,
    WebAuthnException? error,
  }) = _ValidateTokenResult;

  static IRpcCodec<ValidateTokenResult> get codec => RpcCodec(ValidateTokenResult.fromJson);

  factory ValidateTokenResult.fromJson(Map<String, dynamic> json) =>
      _$ValidateTokenResultFromJson(json);

  factory ValidateTokenResult.success({
    required WebAuthnCredentialPublic credential,
    WebAuthnAuthContext? context,
  }) {
    return ValidateTokenResult._(
      isValid: true,
      credential: credential,
      context: context,
    );
  }

  factory ValidateTokenResult.failure(String message, [WebAuthnException? error]) {
    return ValidateTokenResult._(
      isValid: false,
      errorMessage: message,
      error: error,
    );
  }
}

/// Use Case для валидации PASETO токенов
class ValidateTokenUseCase {
  final IWebAuthnRepository _webAuthnRepository;
  final ISessionRepository _sessionRepository;
  final ITokenBlacklistRepository _tokenBlacklistRepository;
  final PasetoUtils _pasetoUtils;

  ValidateTokenUseCase(
    this._webAuthnRepository,
    this._sessionRepository,
    this._tokenBlacklistRepository,
    this._pasetoUtils,
  );

  Future<ValidateTokenResult> execute(ValidateTokenParams params) async {
    try {
      // 1. Валидируем токен
      final tokenPayload = await _pasetoUtils.validateToken(params.token);
      if (tokenPayload == null) {
        return ValidateTokenResult.failure('Недействительный токен');
      }

      // 2. Проверяем, не находится ли токен в чёрном списке
      final isBlacklisted = await _tokenBlacklistRepository.isBlacklisted(tokenPayload.jti);
      if (isBlacklisted) {
        return ValidateTokenResult.failure('Токен отозван');
      }

      // 3. Получаем ID сессии из токена
      final sessionId = tokenPayload.extra?['sessionId'] as String?;
      if (sessionId != null) {
        // Проверяем активность сессии
        final isSessionActive = await _sessionRepository.isSessionActive(sessionId);
        if (!isSessionActive) {
          return ValidateTokenResult.failure('Сессия неактивна или истекла');
        }
      }

      // 4. Получаем учетные данные из токена
      final credentialData = tokenPayload.extra;
      if (credentialData == null) {
        return ValidateTokenResult.failure('Токен не содержит данных учетных записей');
      }

      final credential = WebAuthnCredentialPublic.fromJson(
        Map<String, dynamic>.from(credentialData),
      );

      // 5. Проверяем, существуют ли учетные данные в репозитории
      final existingCredential =
          await _webAuthnRepository.getCredentialById(credential.credentialId);
      if (existingCredential == null) {
        return ValidateTokenResult.failure('Учетные данные не найдены');
      }

      // 6. Проверяем соответствие пользователя
      if (existingCredential.userId != tokenPayload.sub) {
        return ValidateTokenResult.failure('Несоответствие пользователя в токене');
      }

      // 7. Создаем обновлённый контекст авторизации
      final updatedContext = params.context?.copyWith(
            isAuthenticated: true,
            credential: existingCredential.public,
            sessionId: sessionId,
          ) ??
          WebAuthnAuthContext(
            rpId: 'unknown',
            origin: 'unknown',
            platform: 'unknown',
            scopes: tokenPayload.scopes,
            sessionId: sessionId,
            isAuthenticated: true,
            credential: existingCredential.public,
          );

      return ValidateTokenResult.success(
        credential: existingCredential.public,
        context: updatedContext,
      );
    } on WebAuthnException catch (e) {
      return ValidateTokenResult.failure(e.message, e);
    } catch (e) {
      return ValidateTokenResult.failure('Ошибка валидации токена: ${e.toString()}');
    }
  }
}
