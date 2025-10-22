// Реализация репозитория WebAuthn в памяти
// Подходит для тестов и небольших приложений
import '../../../rpc_dart_webauthn.dart';

class MemoryWebAuthnRepositoryImpl implements IWebAuthnRepository {
  final Map<String, WebAuthnCredentialPrivate> _credentials = {};

  @override
  Future<void> saveCredential(WebAuthnCredentialPrivate credential) async {
    _credentials[credential.credentialId] = credential;
  }

  @override
  Future<WebAuthnCredentialPrivate?> getCredentialById(
      String credentialId) async {
    return _credentials[credentialId];
  }

  @override
  Future<List<WebAuthnCredentialPrivate>> getCredentialsByUserId(
      String userId) async {
    return _credentials.values.where((cred) => cred.userId == userId).toList();
  }

  @override
  Future<void> updateCounter(String credentialId, int newCounter) async {
    final credential = _credentials[credentialId];
    if (credential != null) {
      final updated = credential.copyWith(counter: newCounter);
      _credentials[credentialId] = updated;
    }
  }

  // Добавляем метод для удаления учетных данных
  @override
  Future<void> removeCredential(String credentialId) async {
    _credentials.remove(credentialId);
  }
}
