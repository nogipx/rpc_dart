import 'package:test/test.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';

void main() {
  group('WebAuthn Authorization Tests', () {
    late MemorySessionRepositoryImpl sessionRepository;
    late MemoryTokenBlacklistRepositoryImpl tokenBlacklistRepository;
    late PasetoUtils pasetoUtils;
    late RevokeSessionUseCase revokeSessionUseCase;

    setUp(() {
      sessionRepository = MemorySessionRepositoryImpl();
      tokenBlacklistRepository = MemoryTokenBlacklistRepositoryImpl();

      // Создаем PasetoUtils с тестовым ключом
      final secretKey = List.generate(32, (index) => index);
      pasetoUtils = PasetoUtils(secretKeyBytes: secretKey);

      revokeSessionUseCase = RevokeSessionUseCase(
        sessionRepository,
      );
    });

    test('Создание и валидация сессии', () async {
      const userId = 'test-user-123';
      const sessionId = 'session-456';

      // Создаем сессию
      await sessionRepository.storeActiveSession(
        sessionId,
        userId,
        expiresAt: DateTime.now().add(Duration(hours: 1)),
        metadata: {'platform': 'web'},
      );

      // Проверяем, что сессия активна
      final isActive = await sessionRepository.isSessionActive(sessionId);
      expect(isActive, isTrue);

      // Получаем информацию о сессии
      final session = await sessionRepository.getSession(sessionId);
      expect(session, isNotNull);
      expect(session!.userId, equals(userId));
      expect(session.sessionId, equals(sessionId));
      expect(session.isActive, isTrue);
    });

    test('Отзыв сессии', () async {
      const userId = 'test-user-123';
      const sessionId = 'session-456';

      // Создаем сессию
      await sessionRepository.storeActiveSession(sessionId, userId);

      // Проверяем, что сессия активна
      expect(await sessionRepository.isSessionActive(sessionId), isTrue);

      // Отзываем сессию
      final result = await revokeSessionUseCase.revokeSession(
        RevokeSessionParams(sessionId: sessionId, reason: 'Test revocation'),
      );

      expect(result.success, isTrue);
      expect(result.revokedCount, equals(1));

      // Проверяем, что сессия больше не активна
      expect(await sessionRepository.isSessionActive(sessionId), isFalse);
    });

    test('Отзыв всех сессий пользователя', () async {
      const userId = 'test-user-123';

      // Создаем несколько сессий
      await sessionRepository.storeActiveSession('session-1', userId);
      await sessionRepository.storeActiveSession('session-2', userId);
      await sessionRepository.storeActiveSession('session-3', userId);

      // Проверяем количество активных сессий
      final activeSessions = await sessionRepository.getUserActiveSessions(userId);
      expect(activeSessions.length, equals(3));

      // Отзываем все сессии
      final result = await revokeSessionUseCase.revokeAllSessions(
        RevokeAllSessionsParams(userId: userId, reason: 'Security cleanup'),
      );

      expect(result.success, isTrue);
      expect(result.revokedCount, equals(3));

      // Проверяем, что сессий больше нет
      final remainingSessions = await sessionRepository.getUserActiveSessions(userId);
      expect(remainingSessions.length, equals(0));
    });

    test('Работа с чёрным списком токенов', () async {
      const tokenId = 'test-token-123';

      // Проверяем, что токен не в чёрном списке
      expect(await tokenBlacklistRepository.isBlacklisted(tokenId), isFalse);

      // Добавляем токен в чёрный список
      await tokenBlacklistRepository.addToBlacklist(
        tokenId,
        reason: 'Security breach',
        expiresAt: DateTime.now().add(Duration(hours: 1)),
      );

      // Проверяем, что токен теперь в чёрном списке
      expect(await tokenBlacklistRepository.isBlacklisted(tokenId), isTrue);

      // Получаем информацию о заблокированном токене
      final blacklistedToken = await tokenBlacklistRepository.getBlacklistedToken(tokenId);
      expect(blacklistedToken, isNotNull);
      expect(blacklistedToken!.tokenId, equals(tokenId));
      expect(blacklistedToken.reason, equals('Security breach'));
    });

    test('Автоматическая очистка истёкших сессий', () async {
      const userId = 'test-user-123';
      const sessionId = 'expired-session';

      // Создаем сессию с истёкшим сроком действия
      await sessionRepository.storeActiveSession(
        sessionId,
        userId,
        expiresAt: DateTime.now().subtract(Duration(hours: 1)), // Уже истекла
      );

      // Проверяем, что сессия считается неактивной
      expect(await sessionRepository.isSessionActive(sessionId), isFalse);

      // Запускаем очистку
      await sessionRepository.cleanupExpiredSessions();

      // Проверяем, что сессия удалена
      final session = await sessionRepository.getSession(sessionId);
      expect(session, isNull);
    });

    test('Создание токена с сессией', () async {
      const userId = 'test-user-123';
      const sessionId = 'session-456';

      // Создаем токен с ID сессии
      final token = await pasetoUtils.createToken(
        userId: userId,
        scopes: ['user', 'webauthn.authenticated'],
        extra: {
          'sessionId': sessionId,
          'platform': 'web',
        },
      );

      expect(token, isNotEmpty);

      // Валидируем токен
      final payload = await pasetoUtils.validateToken(token);
      expect(payload, isNotNull);
      expect(payload!.sub, equals(userId));
      expect(payload.extra?['sessionId'], equals(sessionId));
      expect(payload.scopes, contains('user'));
      expect(payload.scopes, contains('webauthn.authenticated'));
    });
  });
}
