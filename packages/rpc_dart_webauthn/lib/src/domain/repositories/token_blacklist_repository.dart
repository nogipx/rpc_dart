/// Репозиторий для управления чёрным списком отозванных токенов
abstract interface class ITokenBlacklistRepository {
  /// Добавляет токен в чёрный список
  Future<void> addToBlacklist(
    String tokenId, {
    DateTime? expiresAt,
    String? reason,
  });

  /// Проверяет, находится ли токен в чёрном списке
  Future<bool> isBlacklisted(String tokenId);

  /// Получает информацию о заблокированном токене
  Future<BlacklistedTokenInfo?> getBlacklistedToken(String tokenId);

  /// Удаляет истёкшие токены из чёрного списка
  Future<void> cleanupExpiredTokens();

  /// Получает все заблокированные токены пользователя
  Future<List<BlacklistedTokenInfo>> getUserBlacklistedTokens(String userId);

  /// Очищает все заблокированные токены пользователя
  Future<void> clearUserBlacklistedTokens(String userId);
}

/// Информация о заблокированном токене
class BlacklistedTokenInfo {
  final String tokenId;
  final String userId;
  final DateTime blacklistedAt;
  final DateTime? expiresAt;
  final String? reason;

  const BlacklistedTokenInfo({
    required this.tokenId,
    required this.userId,
    required this.blacklistedAt,
    this.expiresAt,
    this.reason,
  });

  factory BlacklistedTokenInfo.fromJson(Map<String, dynamic> json) {
    return BlacklistedTokenInfo(
      tokenId: json['tokenId'] as String,
      userId: json['userId'] as String,
      blacklistedAt: DateTime.fromMillisecondsSinceEpoch(json['blacklistedAt'] as int),
      expiresAt: json['expiresAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int)
          : null,
      reason: json['reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tokenId': tokenId,
      'userId': userId,
      'blacklistedAt': blacklistedAt.millisecondsSinceEpoch,
      'expiresAt': expiresAt?.millisecondsSinceEpoch,
      'reason': reason,
    };
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
}
