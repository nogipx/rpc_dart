part of '_index.dart';

/// Контекст авторизации WebAuthn
@freezed
abstract class WebAuthnAuthContext
    with _$WebAuthnAuthContext
    implements IRpcSerializable {
  const factory WebAuthnAuthContext({
    /// Идентификатор RP (Relying Party)
    required String rpId,

    /// Origin запроса
    required String origin,

    /// Платформа клиента
    required String platform,

    /// Скопы пользователя
    required List<String> scopes,

    /// Идентификатор сессии
    String? sessionId,

    /// Аутентифицирован ли пользователь
    @Default(false) bool isAuthenticated,

    /// Учетные данные пользователя (если аутентифицирован)
    WebAuthnCredentialPublic? credential,

    /// Дополнительные метаданные
    @Default({}) Map<String, dynamic> metadata,
  }) = _WebAuthnAuthContext;

  /// Создает контекст из JSON
  factory WebAuthnAuthContext.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAuthContextFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnAuthContext> get codec =>
      RpcCodec(WebAuthnAuthContext.fromJson);
}

/// Результат валидации контекста авторизации
@freezed
abstract class AuthContextValidationResult
    with _$AuthContextValidationResult
    implements IRpcSerializable {
  const factory AuthContextValidationResult({
    /// Валиден ли контекст
    required bool isValid,

    /// Сообщение об ошибке (если не валиден)
    String? errorMessage,

    /// Обновлённый контекст (если требуется обновление)
    WebAuthnAuthContext? updatedContext,
  }) = _AuthContextValidationResult;

  /// Создает результат из JSON
  factory AuthContextValidationResult.fromJson(Map<String, dynamic> json) =>
      _$AuthContextValidationResultFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<AuthContextValidationResult> get codec =>
      RpcCodec(AuthContextValidationResult.fromJson);
}
