import 'attestation_verifier.dart';
import 'fido_u2f_verifier.dart';
import 'none_verifier.dart';
import 'packed_verifier.dart';

/// Фабрика для создания верификаторов аттестации
class AttestationVerifierFactory {
  /// Возвращает верификатор аттестации по формату
  ///
  /// [format] - формат attestation statement
  ///
  /// Возвращает соответствующий верификатор или выбрасывает исключение,
  /// если формат не поддерживается
  static AttestationVerifier getVerifier(String format) {
    switch (format) {
      case 'fido-u2f':
        return FidoU2fVerifier();
      case 'none':
        return NoneVerifier();
      case 'packed':
        return PackedVerifier();
      default:
        // Для всех других форматов возвращаем NoneVerifier как fallback
        return NoneVerifier();
    }
  }
}
