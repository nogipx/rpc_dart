import '_models.dart';
import 'attestation_verifier.dart';

/// Реализация верификатора для None аттестации (self attestation)
class NoneVerifier implements AttestationVerifier {
  @override
  Future<AttestationResult> verify({
    required Map<dynamic, dynamic> attStmt,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  }) async {
    try {
      // None attestation просто проверяет, что attStmt пуст
      if (!isValidFormat(attStmt)) {
        return AttestationResult.failure('Неверный формат None attestation');
      }

      // None attestation не требует проверки подписи или других данных
      // Просто доверяем, что учетные данные созданы правильно

      return AttestationResult.success(attestationType: 'None');
    } catch (e) {
      return AttestationResult.failure(
        'Ошибка проверки None attestation: ${e.toString()}',
      );
    }
  }

  @override
  bool isValidFormat(Map<dynamic, dynamic> attStmt) {
    // В случае None attestation, attStmt должен быть пустым
    return attStmt.isEmpty;
  }
}
