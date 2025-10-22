import '../../../rpc_dart_webauthn.dart';

/// Сервис авторизации для WebAuthn операций
abstract interface class IWebAuthnAuthorizationService {
  /// Проверяет права доступа для выполнения операции
  Future<AuthorizationResult> checkPermission({
    required WebAuthnOperation operation,
    required WebAuthnAuthorizationContext authContext,
    String? targetUserId,
    String? targetSessionId,
    Map<String, dynamic>? additionalParams,
  });

  /// Извлекает контекст авторизации из токена
  Future<WebAuthnAuthorizationContext?> extractAuthorizationContext(
    String token,
  );

  /// Проверяет, имеет ли пользователь определенное право
  bool hasPermission(
    List<WebAuthnPermission> userPermissions,
    WebAuthnPermission requiredPermission,
  );

  /// Получает список необходимых прав для операции
  List<WebAuthnPermission> getRequiredPermissions(
    WebAuthnOperation operation, {
    String? currentUserId,
    String? targetUserId,
  });
}

/// Реализация сервиса авторизации
class WebAuthnAuthorizationService implements IWebAuthnAuthorizationService {
  final ValidateTokenUseCase _validateTokenUseCase;

  const WebAuthnAuthorizationService(this._validateTokenUseCase);

  @override
  Future<AuthorizationResult> checkPermission({
    required WebAuthnOperation operation,
    required WebAuthnAuthorizationContext authContext,
    String? targetUserId,
    String? targetSessionId,
    Map<String, dynamic>? additionalParams,
  }) async {
    try {
      // 1. Получаем необходимые права для операции
      final requiredPermissions = getRequiredPermissions(
        operation,
        currentUserId: authContext.currentUserId,
        targetUserId: targetUserId,
      );

      // 2. Проверяем каждое необходимое право
      for (final permission in requiredPermissions) {
        if (!hasPermission(authContext.permissions, permission)) {
          return AuthorizationResult.denied(
            'Недостаточно прав для выполнения операции ${operation.name}. '
                'Требуется право: ${permission.name}',
            'INSUFFICIENT_PERMISSIONS',
          );
        }
      }

      // 3. Дополнительные проверки для конкретных операций
      final additionalCheck = await _performAdditionalChecks(
        operation,
        authContext,
        targetUserId,
        targetSessionId,
        additionalParams,
      );

      if (!additionalCheck.isAuthorized) {
        return additionalCheck;
      }

      return AuthorizationResult.authorized();
    } catch (e) {
      return AuthorizationResult.denied(
        'Ошибка проверки авторизации: ${e.toString()}',
        'AUTHORIZATION_ERROR',
      );
    }
  }

  @override
  Future<WebAuthnAuthorizationContext?> extractAuthorizationContext(
    String token,
  ) async {
    try {
      // Валидируем токен и извлекаем информацию
      final validateResult = await _validateTokenUseCase.execute(
        ValidateTokenParams(token: token),
      );

      if (!validateResult.isValid || validateResult.credential == null) {
        return null;
      }

      final credential = validateResult.credential!;

      // Определяем права пользователя на основе его роли/статуса
      // В реальном приложении это может быть более сложная логика
      final permissions = _getUserPermissions(credential.userId);

      return WebAuthnAuthorizationContext(
        currentUserId: credential.userId,
        permissions: permissions,
        sessionId: validateResult.context?.sessionId,
      );
    } catch (e) {
      return null;
    }
  }

  @override
  bool hasPermission(
    List<WebAuthnPermission> userPermissions,
    WebAuthnPermission requiredPermission,
  ) {
    // Проверяем прямое наличие права
    if (userPermissions.contains(requiredPermission)) {
      return true;
    }

    // Проверяем административные права (админ может все)
    if (userPermissions.contains(WebAuthnPermission.systemAdministration)) {
      return true;
    }

    return false;
  }

  @override
  List<WebAuthnPermission> getRequiredPermissions(
    WebAuthnOperation operation, {
    String? currentUserId,
    String? targetUserId,
  }) {
    // Определяем, работает ли пользователь со своими данными
    final isOwnData =
        currentUserId != null &&
        targetUserId != null &&
        currentUserId == targetUserId;

    switch (operation) {
      // Регистрация - базовые права
      case WebAuthnOperation.startRegistration:
      case WebAuthnOperation.finishRegistration:
        return [WebAuthnPermission.authenticateAsUser];

      // Аутентификация - базовые права
      case WebAuthnOperation.startAuthentication:
      case WebAuthnOperation.finishAuthentication:
        return [WebAuthnPermission.authenticateAsUser];

      // Управление учетными данными
      case WebAuthnOperation.getUserInfo:
      case WebAuthnOperation.getCredentials:
        if (isOwnData) {
          return [WebAuthnPermission.manageOwnCredentials];
        } else {
          return [WebAuthnPermission.viewAnyUserInfo];
        }

      case WebAuthnOperation.removeCredential:
        if (isOwnData) {
          return [WebAuthnPermission.manageOwnCredentials];
        } else {
          return [WebAuthnPermission.manageAnyCredentials];
        }

      // Управление токенами и сессиями
      case WebAuthnOperation.validateToken:
      case WebAuthnOperation.refreshToken:
      case WebAuthnOperation.isAuthenticated:
        return [WebAuthnPermission.authenticateAsUser];

      case WebAuthnOperation.revokeToken:
      case WebAuthnOperation.revokeSession:
        if (isOwnData) {
          return [WebAuthnPermission.manageOwnSessions];
        } else {
          return [WebAuthnPermission.manageAnySessions];
        }

      case WebAuthnOperation.revokeAllSessions:
        if (isOwnData) {
          return [WebAuthnPermission.manageOwnSessions];
        } else {
          return [WebAuthnPermission.manageAnySessions];
        }
    }
  }

  /// Выполняет дополнительные проверки для конкретных операций
  Future<AuthorizationResult> _performAdditionalChecks(
    WebAuthnOperation operation,
    WebAuthnAuthorizationContext authContext,
    String? targetUserId,
    String? targetSessionId,
    Map<String, dynamic>? additionalParams,
  ) async {
    switch (operation) {
      // Для операций с сессиями проверяем, что сессия принадлежит пользователю
      case WebAuthnOperation.revokeSession:
        if (targetSessionId != null &&
            authContext.sessionId != null &&
            targetSessionId != authContext.sessionId &&
            !hasPermission(
              authContext.permissions,
              WebAuthnPermission.manageAnySessions,
            )) {
          return AuthorizationResult.denied(
            'Нельзя отозвать чужую сессию без административных прав',
            'SESSION_ACCESS_DENIED',
          );
        }
        break;

      // Для удаления учетных данных проверяем дополнительные ограничения
      case WebAuthnOperation.removeCredential:
        // Можно добавить проверку, что пользователь не удаляет последние учетные данные
        break;

      default:
        // Для остальных операций дополнительных проверок не требуется
        break;
    }

    return AuthorizationResult.authorized();
  }

  /// Определяет права пользователя
  /// В реальном приложении это может быть более сложная логика с ролями
  List<WebAuthnPermission> _getUserPermissions(String userId) {
    // Базовые права для всех пользователей
    final permissions = <WebAuthnPermission>[
      WebAuthnPermission.authenticateAsUser,
      WebAuthnPermission.manageOwnCredentials,
      WebAuthnPermission.manageOwnSessions,
    ];

    // Здесь можно добавить логику определения административных прав
    // Например, на основе роли пользователя из базы данных
    // if (isAdmin(userId)) {
    //   permissions.addAll([
    //     WebAuthnPermission.systemAdministration,
    //     WebAuthnPermission.manageAnyCredentials,
    //     WebAuthnPermission.manageAnySessions,
    //     WebAuthnPermission.viewAnyUserInfo,
    //   ]);
    // }

    return permissions;
  }
}
