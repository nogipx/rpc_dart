import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';
import '../../utils/_index.dart';
import 'package:x509_plus/x509.dart' as x509;
import 'package:crypto_keys_plus/crypto_keys.dart' as ckp;

import '_index.dart';

/// Реализация верификатора для FIDO U2F аттестации
class FidoU2fVerifier implements AttestationVerifier {
  @override
  Future<AttestationResult> verify({
    required Map<dynamic, dynamic> attStmt,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  }) async {
    try {
      // 1. Проверяем наличие сертификата и подписи
      if (!isValidFormat(attStmt)) {
        return AttestationResult.failure('Неверный формат FIDO U2F attestation');
      }

      final x5c = attStmt['x5c'] as List;
      final sig = (attStmt['sig'] as List<dynamic>).cast<int>();

      // Получаем сертификат для проверки подписи
      final certBytes = (x5c[0] as List<dynamic>).cast<int>();

      // Парсим X.509 сертификат и получаем публичный ключ
      final publicKey = _extractPublicKeyFromCertificate(certBytes);

      // Проверяем, что ключ сертификата является ECDSA P-256
      if (publicKey.parameters is! ECCurve_secp256r1) {
        return AttestationResult.failure('Сертификат не содержит ECDSA P-256 ключ');
      }

      // Парсим данные authenticator data
      final authData = AuthenticatorData.fromRawData(Uint8List.fromList(authenticatorData));

      // Извлекаем RP ID Hash
      final rpIdHash = authData.rpIdHash;

      // Для FIDO U2F нам нужны сырые данные credentialId и publicKey
      if (!authData.hasAttestedCredentialData ||
          authData.credentialId == null ||
          authData.credentialPublicKey == null) {
        return AttestationResult.failure('AuthenticatorData не содержит учетных данных');
      }

      // Получаем credentialId
      final credentialId = authData.credentialId!;

      // Декодируем COSE публичный ключ
      final coseKey = AppCborDecoder.decodeCosePublicKey(authData.credentialPublicKey!);

      if (!coseKey.isEC) {
        return AttestationResult.failure('COSE ключ не является EC ключом');
      }

      final x = coseKey.x!;
      final y = coseKey.y!;

      // Преобразуем координаты в формат U2F (uncompressed point format)
      // U2F использует формат: 0x04 || x || y
      final u2fPublicKey = [0x04] + x + y;

      // Создаем verification data для U2F формата
      // В U2F используется формат: 0x00 + rpIdHash + clientDataHash + credentialId + u2fPublicKey
      final verificationData = [0x00] + rpIdHash + clientDataHash + credentialId + u2fPublicKey;

      // Проверяем подпись с использованием публичного ключа из сертификата
      final isValid = _verifySignature(publicKey, verificationData, sig);

      if (!isValid) {
        return AttestationResult.failure('Недействительная подпись FIDO U2F attestation');
      }

      // Проверка успешна, возвращаем результат с типом "Basic"
      return AttestationResult.success(attestationType: 'Basic', trustPath: [certBytes]);
    } catch (e) {
      return AttestationResult.failure('Ошибка проверки FIDO U2F attestation: ${e.toString()}');
    }
  }

  @override
  bool isValidFormat(Map<dynamic, dynamic> attStmt) {
    // Проверяем наличие x5c и sig в attestation statement
    final hasX5c =
        attStmt.containsKey('x5c') && attStmt['x5c'] is List && (attStmt['x5c'] as List).isNotEmpty;
    final hasSig = attStmt.containsKey('sig') && attStmt['sig'] is List<int>;

    return hasX5c && hasSig;
  }

  /// Извлекает публичный ключ из X.509 сертификата
  ECPublicKey _extractPublicKeyFromCertificate(List<int> certBytes) {
    try {
      // Парсим сертификат через x509_plus
      final certAsn1 = ASN1Parser(Uint8List.fromList(certBytes)).nextObject() as ASN1Sequence;
      final cert = x509.X509Certificate.fromAsn1(certAsn1);

      final pub = cert.tbsCertificate.subjectPublicKeyInfo!.subjectPublicKey;

      if (pub is! ckp.EcPublicKey) {
        throw ArgumentError('Поддерживаются только EC публичные ключи');
      }

      // Конвертируем EcPublicKey (crypto_keys_plus) в pointycastle ECPublicKey
      final ecParams = ECCurve_secp256r1();
      final q = ecParams.curve.createPoint(pub.xCoordinate, pub.yCoordinate);
      return ECPublicKey(q, ecParams);
    } catch (e) {
      throw ArgumentError('Ошибка извлечения публичного ключа из сертификата: $e');
    }
  }

  // Проверка подписи с использованием ECDSA
  bool _verifySignature(ECPublicKey publicKey, List<int> data, List<int> signature) {
    final signer = Signer('SHA-256/ECDSA');
    final params = PublicKeyParameter<ECPublicKey>(publicKey);
    signer.init(false, params);

    final ecSignature = _decodeECDSASignature(signature);

    return signer.verifySignature(Uint8List.fromList(data), ecSignature);
  }

  // Декодирование ECDSA подписи из формата ASN.1 DER
  ECSignature _decodeECDSASignature(List<int> signature) {
    final asn1Parser = ASN1Parser(Uint8List.fromList(signature));
    final seq = asn1Parser.nextObject() as ASN1Sequence;

    final r = (seq.elements[0] as ASN1Integer).valueAsBigInteger;
    final s = (seq.elements[1] as ASN1Integer).valueAsBigInteger;

    return ECSignature(r, s);
  }
}
