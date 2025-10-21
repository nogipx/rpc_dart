import 'package:test/test.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';

void main() {
  group('WebAuthn Authorization Tests', () {
    group('Permission Checks', () {
      test('hasPermission возвращает true для прямого права', () {
        final authService = TestAuthorizationHelper();
        final permissions = [WebAuthnPermission.manageOwnCredentials];
        final result = authService.hasPermission(
          permissions,
          WebAuthnPermission.manageOwnCredentials,
        );
        expect(result, isTrue);
      });

      test('hasPermission возвращает true для админа', () {
        final authService = TestAuthorizationHelper();
        final permissions = [WebAuthnPermission.systemAdministration];
        final result = authService.hasPermission(
          permissions,
          WebAuthnPermission.manageOwnCredentials,
        );
        expect(result, isTrue);
      });

      test('hasPermission возвращает false для отсутствующего права', () {
        final authService = TestAuthorizationHelper();
        final permissions = [WebAuthnPermission.authenticateAsUser];
        final result = authService.hasPermission(
          permissions,
          WebAuthnPermission.manageOwnCredentials,
        );
        expect(result, isFalse);
      });
    });

    group('Required Permissions', () {
      test('getUserInfo требует manageOwnCredentials для своих данных', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.getUserInfo,
          currentUserId: 'user1',
          targetUserId: 'user1',
        );
        expect(permissions, contains(WebAuthnPermission.manageOwnCredentials));
      });

      test('getUserInfo требует viewAnyUserInfo для чужих данных', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.getUserInfo,
          currentUserId: 'user1',
          targetUserId: 'user2',
        );
        expect(permissions, contains(WebAuthnPermission.viewAnyUserInfo));
      });

      test('removeCredential требует manageOwnCredentials для своих данных', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.removeCredential,
          currentUserId: 'user1',
          targetUserId: 'user1',
        );
        expect(permissions, contains(WebAuthnPermission.manageOwnCredentials));
      });

      test('removeCredential требует manageAnyCredentials для чужих данных', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.removeCredential,
          currentUserId: 'user1',
          targetUserId: 'user2',
        );
        expect(permissions, contains(WebAuthnPermission.manageAnyCredentials));
      });

      test('revokeSession требует manageOwnSessions для своих сессий', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.revokeSession,
          currentUserId: 'user1',
          targetUserId: 'user1',
        );
        expect(permissions, contains(WebAuthnPermission.manageOwnSessions));
      });

      test('revokeAllSessions требует manageAnySessions для чужих сессий', () {
        final authService = TestAuthorizationHelper();
        final permissions = authService.getRequiredPermissions(
          WebAuthnOperation.revokeAllSessions,
          currentUserId: 'user1',
          targetUserId: 'user2',
        );
        expect(permissions, contains(WebAuthnPermission.manageAnySessions));
      });
    });

    group('Authorization Context', () {
      test('создает контекст с базовыми правами пользователя', () {
        final context = WebAuthnAuthorizationContext(
          currentUserId: 'user1',
          permissions: [
            WebAuthnPermission.authenticateAsUser,
            WebAuthnPermission.manageOwnCredentials,
            WebAuthnPermission.manageOwnSessions,
          ],
        );

        expect(context.currentUserId, equals('user1'));
        expect(context.permissions, hasLength(3));
        expect(context.permissions, contains(WebAuthnPermission.authenticateAsUser));
        expect(context.permissions, contains(WebAuthnPermission.manageOwnCredentials));
        expect(context.permissions, contains(WebAuthnPermission.manageOwnSessions));
      });

      test('создает контекст с административными правами', () {
        final context = WebAuthnAuthorizationContext(
          currentUserId: 'admin1',
          permissions: [
            WebAuthnPermission.systemAdministration,
            WebAuthnPermission.manageAnyCredentials,
            WebAuthnPermission.manageAnySessions,
            WebAuthnPermission.viewAnyUserInfo,
          ],
        );

        expect(context.currentUserId, equals('admin1'));
        expect(context.permissions, contains(WebAuthnPermission.systemAdministration));
        expect(context.permissions, contains(WebAuthnPermission.manageAnyCredentials));
      });
    });

    group('Authorization Results', () {
      test('создает успешный результат авторизации', () {
        final result = AuthorizationResult.authorized();
        expect(result.isAuthorized, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.errorCode, isNull);
      });

      test('создает результат отказа в авторизации', () {
        final result = AuthorizationResult.denied('Access denied', 'INSUFFICIENT_PERMISSIONS');
        expect(result.isAuthorized, isFalse);
        expect(result.errorMessage, equals('Access denied'));
        expect(result.errorCode, equals('INSUFFICIENT_PERMISSIONS'));
      });
    });
  });
}

/// Тестовый helper для проверки логики авторизации
class TestAuthorizationHelper {
  /// Проверяет, имеет ли пользователь определенное право
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

  /// Получает список необходимых прав для операции
  List<WebAuthnPermission> getRequiredPermissions(
    WebAuthnOperation operation, {
    String? currentUserId,
    String? targetUserId,
  }) {
    // Определяем, работает ли пользователь со своими данными
    final isOwnData =
        currentUserId != null && targetUserId != null && currentUserId == targetUserId;

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
}
