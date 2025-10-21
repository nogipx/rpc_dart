import '_models.dart';

/// Абстрактный класс для верификаторов аттестации WebAuthn
abstract class AttestationVerifier {
  /// Проверка аттестационного заявления
  ///
  /// [attStmt] - аттестационное заявление (дополнительные данные от аутентификатора)
  /// [authenticatorData] - данные аутентификатора
  /// [clientDataHash] - хеш clientDataJSON
  ///
  /// Возвращает результат проверки аттестации [AttestationResult]
  Future<AttestationResult> verify({
    required Map<dynamic, dynamic> attStmt,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  });

  /// Проверка формата аттестационного заявления
  ///
  /// [attStmt] - аттестационное заявление (дополнительные данные от аутентификатора)
  ///
  /// Возвращает true, если формат заявления соответствует ожидаемому
  bool isValidFormat(Map<dynamic, dynamic> attStmt);
}
