import '../../../rpc_dart_webauthn.dart';

/// Реализация репозитория сессий в памяти
class MemorySessionRepositoryImpl implements ISessionRepository {
  final Map<String, SessionInfo> _sessions = {};
  final Map<String, List<String>> _userSessions = {};

  @override
  Future<void> storeActiveSession(
    String sessionId,
    String userId, {
    DateTime? expiresAt,
    Map<String, dynamic>? metadata,
  }) async {
    final session = SessionInfo(
      sessionId: sessionId,
      userId: userId,
      createdAt: DateTime.now(),
      expiresAt: expiresAt ?? DateTime.now().add(Duration(hours: 1)),
      metadata: metadata ?? {},
      isActive: true,
    );

    _sessions[sessionId] = session;

    // Добавляем в список сессий пользователя
    _userSessions.putIfAbsent(userId, () => []).add(sessionId);
  }

  @override
  Future<bool> isSessionActive(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return false;

    // Проверяем срок действия
    if (DateTime.now().isAfter(session.expiresAt)) {
      await revokeSession(sessionId);
      return false;
    }

    return session.isActive;
  }

  @override
  Future<SessionInfo?> getSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return null;

    // Проверяем срок действия
    if (DateTime.now().isAfter(session.expiresAt)) {
      await revokeSession(sessionId);
      return null;
    }

    return session;
  }

  @override
  Future<void> revokeSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session != null) {
      _sessions[sessionId] = session.copyWith(isActive: false);

      // Удаляем из списка активных сессий пользователя
      final userSessions = _userSessions[session.userId];
      if (userSessions != null) {
        userSessions.remove(sessionId);
        if (userSessions.isEmpty) {
          _userSessions.remove(session.userId);
        }
      }
    }
  }

  @override
  Future<void> revokeAllUserSessions(String userId) async {
    final userSessions = _userSessions[userId];
    if (userSessions != null) {
      for (final sessionId in List.from(userSessions)) {
        await revokeSession(sessionId);
      }
    }
  }

  @override
  Future<List<SessionInfo>> getUserActiveSessions(String userId) async {
    final userSessions = _userSessions[userId];
    if (userSessions == null) return [];

    final activeSessions = <SessionInfo>[];
    for (final sessionId in userSessions) {
      final session = await getSession(sessionId);
      if (session != null && session.isActive) {
        activeSessions.add(session);
      }
    }

    return activeSessions;
  }

  @override
  Future<void> cleanupExpiredSessions() async {
    final now = DateTime.now();
    final expiredSessions = _sessions.entries
        .where((entry) => now.isAfter(entry.value.expiresAt))
        .map((entry) => entry.key)
        .toList();

    for (final sessionId in expiredSessions) {
      await revokeSession(sessionId);
    }
  }

  /// Очищает все сессии (для тестирования)
  void clear() {
    _sessions.clear();
    _userSessions.clear();
  }

  /// Получает количество активных сессий
  int get activeSessionCount =>
      _sessions.values.where((s) => s.isActive).length;
}
