import '../../../rpc_dart_webauthn.dart';

/// Реализация репозитория чёрного списка токенов в памяти
class MemoryTokenBlacklistRepositoryImpl implements ITokenBlacklistRepository {
  final Map<String, BlacklistedTokenInfo> _blacklistedTokens = {};
  final Map<String, List<String>> _userBlacklistedTokens = {};

  @override
  Future<void> addToBlacklist(
    String tokenId, {
    String? userId,
    DateTime? expiresAt,
    String? reason,
  }) async {
    final resolvedUserId = userId ?? 'unknown';

    final blacklistedToken = BlacklistedTokenInfo(
      tokenId: tokenId,
      userId: resolvedUserId,
      blacklistedAt: DateTime.now(),
      expiresAt: expiresAt,
      reason: reason,
    );

    _blacklistedTokens[tokenId] = blacklistedToken;

    // Добавляем в список заблокированных токенов пользователя
    _userBlacklistedTokens.putIfAbsent(resolvedUserId, () => []).add(tokenId);
  }

  @override
  Future<bool> isBlacklisted(String tokenId) async {
    final blacklistedToken = _blacklistedTokens[tokenId];
    if (blacklistedToken == null) return false;

    // Проверяем срок действия блокировки
    if (blacklistedToken.isExpired) {
      await _removeExpiredToken(tokenId);
      return false;
    }

    return true;
  }

  @override
  Future<BlacklistedTokenInfo?> getBlacklistedToken(String tokenId) async {
    final blacklistedToken = _blacklistedTokens[tokenId];
    if (blacklistedToken == null) return null;

    // Проверяем срок действия блокировки
    if (blacklistedToken.isExpired) {
      await _removeExpiredToken(tokenId);
      return null;
    }

    return blacklistedToken;
  }

  @override
  Future<void> cleanupExpiredTokens() async {
    final expiredTokens = _blacklistedTokens.entries
        .where((entry) => entry.value.isExpired)
        .map((entry) => entry.key)
        .toList();

    for (final tokenId in expiredTokens) {
      await _removeExpiredToken(tokenId);
    }
  }

  @override
  Future<List<BlacklistedTokenInfo>> getUserBlacklistedTokens(
    String userId,
  ) async {
    final userTokens = _userBlacklistedTokens[userId];
    if (userTokens == null) return [];

    final activeBlacklistedTokens = <BlacklistedTokenInfo>[];
    for (final tokenId in userTokens) {
      final token = await getBlacklistedToken(tokenId);
      if (token != null) {
        activeBlacklistedTokens.add(token);
      }
    }

    return activeBlacklistedTokens;
  }

  @override
  Future<void> clearUserBlacklistedTokens(String userId) async {
    final userTokens = _userBlacklistedTokens[userId];
    if (userTokens != null) {
      for (final tokenId in List.from(userTokens)) {
        await _removeExpiredToken(tokenId);
      }
    }
  }

  /// Удаляет истёкший токен из всех структур данных
  Future<void> _removeExpiredToken(String tokenId) async {
    final blacklistedToken = _blacklistedTokens.remove(tokenId);
    if (blacklistedToken != null) {
      final userTokens = _userBlacklistedTokens[blacklistedToken.userId];
      if (userTokens != null) {
        userTokens.remove(tokenId);
        if (userTokens.isEmpty) {
          _userBlacklistedTokens.remove(blacklistedToken.userId);
        }
      }
    }
  }

  /// Очищает все заблокированные токены (для тестирования)
  void clear() {
    _blacklistedTokens.clear();
    _userBlacklistedTokens.clear();
  }

  /// Получает количество заблокированных токенов
  int get blacklistedTokenCount => _blacklistedTokens.length;
}
