/// Репозиторий для управления активными сессиями пользователей
abstract interface class ISessionRepository {
  /// Сохраняет активную сессию пользователя
  Future<void> storeActiveSession(
    String sessionId,
    String userId, {
    DateTime? expiresAt,
    Map<String, dynamic>? metadata,
  });

  /// Проверяет, активна ли сессия
  Future<bool> isSessionActive(String sessionId);

  /// Получает информацию о сессии
  Future<SessionInfo?> getSession(String sessionId);

  /// Отзывает конкретную сессию
  Future<void> revokeSession(String sessionId);

  /// Отзывает все сессии пользователя
  Future<void> revokeAllUserSessions(String userId);

  /// Получает все активные сессии пользователя
  Future<List<SessionInfo>> getUserActiveSessions(String userId);

  /// Продлевает срок действия сессии и при необходимости обновляет метаданные
  Future<SessionInfo?> extendSession(
    String sessionId, {
    DateTime? newExpiresAt,
    Map<String, dynamic>? metadataUpdates,
  });

  /// Очищает истёкшие сессии
  Future<void> cleanupExpiredSessions();
}

/// Информация о сессии
class SessionInfo {
  final String sessionId;
  final String userId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Map<String, dynamic> metadata;
  final bool isActive;

  const SessionInfo({
    required this.sessionId,
    required this.userId,
    required this.createdAt,
    required this.expiresAt,
    required this.metadata,
    required this.isActive,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      sessionId: json['sessionId'] as String,
      userId: json['userId'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
      metadata: Map<String, dynamic>.from(json['metadata'] as Map),
      isActive: json['isActive'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'userId': userId,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'expiresAt': expiresAt.millisecondsSinceEpoch,
      'metadata': metadata,
      'isActive': isActive,
    };
  }

  SessionInfo copyWith({
    String? sessionId,
    String? userId,
    DateTime? createdAt,
    DateTime? expiresAt,
    Map<String, dynamic>? metadata,
    bool? isActive,
  }) {
    return SessionInfo(
      sessionId: sessionId ?? this.sessionId,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      metadata: metadata ?? this.metadata,
      isActive: isActive ?? this.isActive,
    );
  }
}
