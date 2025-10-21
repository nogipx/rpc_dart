part of '_index.dart';

/// Типы операций в WebAuthn домене
enum WebAuthnOperation {
  // Регистрация
  startRegistration,
  finishRegistration,

  // Аутентификация
  startAuthentication,
  finishAuthentication,

  // Управление учетными данными
  getUserInfo,
  removeCredential,
  getCredentials,

  // Управление токенами и сессиями
  validateToken,
  revokeToken,
  isAuthenticated,
  revokeSession,
  revokeAllSessions,
}

/// Права доступа в WebAuthn домене
enum WebAuthnPermission {
  // Базовые права пользователя
  manageOwnCredentials, // Управление своими учетными данными
  manageOwnSessions, // Управление своими сессиями
  authenticateAsUser, // Аутентификация как пользователь

  // Административные права
  manageAnyCredentials, // Управление любыми учетными данными
  manageAnySessions, // Управление любыми сессиями
  viewAnyUserInfo, // Просмотр информации любого пользователя
  systemAdministration, // Системное администрирование
}

/// Контекст авторизации для проверки прав доступа
@freezed
abstract class WebAuthnAuthorizationContext
    with _$WebAuthnAuthorizationContext
    implements IRpcSerializable {
  const factory WebAuthnAuthorizationContext({
    /// Идентификатор текущего пользователя
    required String currentUserId,

    /// Права доступа текущего пользователя
    required List<WebAuthnPermission> permissions,

    /// Идентификатор сессии
    String? sessionId,

    /// Дополнительные метаданные
    @Default({}) Map<String, dynamic> metadata,
  }) = _WebAuthnAuthorizationContext;

  factory WebAuthnAuthorizationContext.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAuthorizationContextFromJson(json);

  static RpcCodec<WebAuthnAuthorizationContext> get codec =>
      RpcCodec(WebAuthnAuthorizationContext.fromJson);
}

/// Результат проверки авторизации
@freezed
abstract class AuthorizationResult with _$AuthorizationResult implements IRpcSerializable {
  const factory AuthorizationResult({
    /// Разрешена ли операция
    required bool isAuthorized,

    /// Сообщение об ошибке (если не разрешена)
    String? errorMessage,

    /// Код ошибки
    String? errorCode,
  }) = _AuthorizationResult;

  factory AuthorizationResult.fromJson(Map<String, dynamic> json) =>
      _$AuthorizationResultFromJson(json);

  static RpcCodec<AuthorizationResult> get codec => RpcCodec(AuthorizationResult.fromJson);

  /// Создает успешный результат авторизации
  factory AuthorizationResult.authorized() {
    return const AuthorizationResult(isAuthorized: true);
  }

  /// Создает результат отказа в авторизации
  factory AuthorizationResult.denied(String message, [String? errorCode]) {
    return AuthorizationResult(
      isAuthorized: false,
      errorMessage: message,
      errorCode: errorCode,
    );
  }
}

/// Исключение авторизации
class WebAuthnAuthorizationException {
  final String message;
  final String operation;
  final String userId;
  final List<WebAuthnPermission> requiredPermissions;

  WebAuthnAuthorizationException(
    this.message, {
    required this.operation,
    required this.userId,
    required this.requiredPermissions,
  });

  /// Создает WebAuthnException для авторизации
  WebAuthnException toWebAuthnException() {
    return WebAuthnException(
      type: WebAuthnExceptionType.authorization,
      message: message,
      stackTrace: StackTrace.current,
    );
  }

  @override
  String toString() {
    return 'WebAuthnAuthorizationException: $message '
        '(operation: $operation, userId: $userId, '
        'requiredPermissions: $requiredPermissions)';
  }
}
