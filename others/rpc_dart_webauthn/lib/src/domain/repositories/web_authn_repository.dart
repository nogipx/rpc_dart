import '../../../rpc_dart_webauthn.dart';

/// Интерфейс репозитория для хранения и управления WebAuthn учетными данными
///
/// Репозиторий отвечает за:
/// - Сохранение учетных данных после регистрации
/// - Получение учетных данных для аутентификации
/// - Обновление счетчика при успешной аутентификации
/// - Удаление учетных данных
abstract class IWebAuthnRepository {
  /// Сохранение учетных данных
  ///
  /// [credential] - учетные данные WebAuthn, которые нужно сохранить
  ///
  /// Throws [WebAuthnCredentialException] в случае ошибки при сохранении
  Future<void> saveCredential(WebAuthnCredentialPrivate credential);

  /// Получение учетных данных по ID
  ///
  /// [credentialId] - идентификатор учетных данных
  ///
  /// Returns WebAuthnCredential или null, если не найдено
  /// Throws [WebAuthnCredentialException] в случае ошибки при получении
  Future<WebAuthnCredentialPrivate?> getCredentialById(String credentialId);

  /// Получение всех учетных данных пользователя
  ///
  /// [userId] - идентификатор пользователя
  ///
  /// Returns список учетных данных пользователя (может быть пустым)
  /// Throws [WebAuthnCredentialException] в случае ошибки при получении
  Future<List<WebAuthnCredentialPrivate>> getCredentialsByUserId(String userId);

  /// Обновление счетчика для защиты от клонирования
  ///
  /// [credentialId] - идентификатор учетных данных
  /// [newCounter] - новое значение счетчика
  ///
  /// Throws [WebAuthnCredentialException] в случае ошибки при обновлении
  Future<void> updateCounter(String credentialId, int newCounter);

  /// Удаление учетных данных
  ///
  /// [credentialId] - идентификатор учетных данных
  ///
  /// Throws [WebAuthnCredentialException] в случае ошибки при удалении
  Future<void> removeCredential(String credentialId);
}
