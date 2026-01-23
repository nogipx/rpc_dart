// Абстрактный интерфейс репозитория для хранения challenge в доменном слое
import '../exceptions/web_authn_exceptions.dart';

/// Интерфейс репозитория для хранения и управления WebAuthn challenge
///
/// Репозиторий отвечает за:
/// - Сохранение challenge для пользователя
/// - Получение challenge для проверки
/// - Проверку срока действия challenge
/// - Удаление использованного challenge
abstract class IChallengeRepository {
  /// Сохранение challenge для пользователя
  ///
  /// [userId] - идентификатор пользователя
  /// [challenge] - сгенерированный challenge в виде массива байт
  /// [expiresInSeconds] - время жизни challenge в секундах (опционально)
  ///
  /// Throws [WebAuthnException] в случае ошибки при сохранении
  Future<void> storeChallenge(
    String userId,
    List<int> challenge, {
    int? expiresInSeconds,
  });

  /// Получение сохраненного challenge
  ///
  /// [userId] - идентификатор пользователя
  ///
  /// Returns null, если challenge не найден
  /// Throws [WebAuthnException] в случае ошибки при получении
  Future<List<int>?> getChallenge(String userId);

  /// Удаление challenge после использования
  ///
  /// [userId] - идентификатор пользователя
  ///
  /// Throws [WebAuthnException] в случае ошибки при удалении
  Future<void> removeChallenge(String userId);

  /// Проверка времени создания challenge (для защиты от replay-атак)
  ///
  /// [userId] - идентификатор пользователя
  ///
  /// Returns true, если challenge действителен, false - если истек или не найден
  /// Throws [WebAuthnException] в случае ошибки при проверке
  Future<bool> isValidTimestamp(String userId);
}
