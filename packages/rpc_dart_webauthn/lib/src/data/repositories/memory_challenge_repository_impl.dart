// Реализация хранилища challenge в памяти
// Подходит для тестов или временного хранения в production
import '../../../rpc_dart_webauthn.dart';

class MemoryChallengeRepositoryImpl implements IChallengeRepository {
  final Map<String, Map<String, dynamic>> _store = {};
  final Duration _defaultValidDuration;

  MemoryChallengeRepositoryImpl(
      {Duration validDuration = const Duration(minutes: 10)})
      : _defaultValidDuration = validDuration;

  @override
  Future<void> storeChallenge(String userId, List<int> challenge,
      {int? expiresInSeconds}) async {
    final validDuration = expiresInSeconds != null
        ? Duration(seconds: expiresInSeconds)
        : _defaultValidDuration;

    _store[userId] = {
      'challenge': challenge,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'validUntil': DateTime.now().add(validDuration).millisecondsSinceEpoch,
    };
  }

  @override
  Future<List<int>?> getChallenge(String userId) async {
    final challenge = _store[userId]?['challenge'];
    if (challenge == null) return null;
    return (challenge as List<dynamic>).cast<int>();
  }

  @override
  Future<void> removeChallenge(String userId) async {
    _store.remove(userId);
  }

  @override
  Future<bool> isValidTimestamp(String userId) async {
    final stored = _store[userId];
    if (stored == null) return false;

    final validUntil = stored['validUntil'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    return now <= validUntil;
  }
}
