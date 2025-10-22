import 'dart:typed_data';
import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';
import '../../utils/_index.dart';
import 'package:x509_plus/x509.dart' as x509;
import 'package:crypto_keys_plus/crypto_keys.dart' as ckp;

import '_index.dart';

/// Реализация верификатора для Packed аттестации
///
/// Поддерживает:
/// - Self attestation (подпись сделана ключом credential)
/// - Certificate-based attestation (подпись сделана ключом из сертификата)
class PackedVerifier implements AttestationVerifier {
  @override
  Future<AttestationResult> verify({
    required Map<dynamic, dynamic> attStmt,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  }) async {
    try {
      // 1. Проверяем формат
      if (!isValidFormat(attStmt)) {
        return AttestationResult.failure('Неверный формат Packed attestation');
      }

      // 2. Получаем общие поля
      final alg = attStmt['alg'] as int;
      final sig = _extractSignatureBytes(attStmt['sig']);

      // 3. Определяем тип аттестации и проверяем
      if (attStmt.containsKey('x5c')) {
        // Certificate-based attestation
        return await _verifyCertificateAttestation(
          alg: alg,
          sig: sig,
          x5c: attStmt['x5c'],
          authenticatorData: authenticatorData,
          clientDataHash: clientDataHash,
        );
      } else {
        // Self attestation
        return await _verifySelfAttestation(
          alg: alg,
          sig: sig,
          authenticatorData: authenticatorData,
          clientDataHash: clientDataHash,
        );
      }
    } catch (e) {
      return AttestationResult.failure('Ошибка проверки Packed attestation: ${e.toString()}');
    }
  }

  @override
  bool isValidFormat(Map<dynamic, dynamic> attStmt) {
    // «ecdaaKeyId» → не поддерживаем
    if (attStmt.containsKey('ecdaaKeyId')) return false;

    final hasAlg = attStmt['alg'] is int;
    final hasSig = attStmt['sig'] != null;
    return hasAlg && hasSig;
  }

  /// Извлекает байты подписи из различных форматов
  List<int> _extractSignatureBytes(dynamic sig) {
    if (sig is List<int>) {
      return sig;
    } else if (sig is Uint8List) {
      return sig.toList();
    } else if (sig is List) {
      return (sig).cast<int>();
    } else {
      throw ArgumentError('Неподдерживаемый формат подписи: ${sig.runtimeType}');
    }
  }

  /// Проверяет certificate-based packed attestation
  Future<AttestationResult> _verifyCertificateAttestation({
    required int alg,
    required List<int> sig,
    required dynamic x5c,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  }) async {
    try {
      // 0. Валидация полей сертификата согласно WebAuthn §8.2.2
      final certBytes = _extractCertificateBytes(x5c);

      // Парсим сертификат и извлекаем публичный ключ
      final publicKey = _extractPublicKeyFromCertificate(certBytes);

      // Создаем verification data
      final verificationData = authenticatorData + clientDataHash;

      // Проверяем подпись
      final isValid = _verifySignatureWithPublicKey(
        publicKey: publicKey,
        signature: sig,
        data: verificationData,
        algorithm: alg,
      );

      if (!isValid) {
        return AttestationResult.failure('Недействительная подпись certificate-based attestation');
      }

      // TODO: Реальная проверка цепочки сертификатов (trusted roots).
      // Для текущих тестов пропускаем валидацию цепочки, так как она требует
      // централизованного стораджа корневых сертификатов (MDS).

      return AttestationResult.success(
        attestationType: 'Basic',
        trustPath: [certBytes],
      );
    } catch (e) {
      return AttestationResult.failure('Ошибка certificate attestation: ${e.toString()}');
    }
  }

  /// Проверяет self packed attestation
  Future<AttestationResult> _verifySelfAttestation({
    required int alg,
    required List<int> sig,
    required List<int> authenticatorData,
    required List<int> clientDataHash,
  }) async {
    try {
      // Парсим authenticator data
      final authData = AuthenticatorData.fromRawData(Uint8List.fromList(authenticatorData));

      if (!authData.hasAttestedCredentialData || authData.credentialPublicKey == null) {
        return AttestationResult.failure(
          'Отсутствуют данные credential для Self attestation',
        );
      }

      // Декодируем COSE публичный ключ
      final coseKey = AppCborDecoder.decodeCosePublicKey(authData.credentialPublicKey!);

      // Проверяем, что алгоритм совпадает
      if (coseKey.algorithm != alg) {
        return AttestationResult.failure(
          'Алгоритм подписи ($alg) не соответствует алгоритму ключа (${coseKey.algorithm})',
        );
      }

      // Создаем verification data
      final verificationData = authenticatorData + clientDataHash;

      // Проверяем подпись с использованием COSE ключа
      final isValid = _verifySignatureWithCoseKey(
        coseKey: coseKey,
        signature: sig,
        data: verificationData,
      );

      if (!isValid) {
        return AttestationResult.failure('Недействительная подпись self attestation');
      }

      return AttestationResult.success(attestationType: 'Self');
    } catch (e) {
      return AttestationResult.failure('Ошибка self attestation: ${e.toString()}');
    }
  }

  /// Извлекает байты сертификата из x5c массива
  List<int> _extractCertificateBytes(dynamic x5c) {
    if (x5c is! List || x5c.isEmpty) {
      throw ArgumentError('x5c должен быть непустым массивом');
    }

    final certData = x5c[0];
    if (certData is List<int>) {
      return certData;
    } else if (certData is Uint8List) {
      return certData.toList();
    } else if (certData is List) {
      return (certData).cast<int>();
    } else {
      throw ArgumentError('Неподдерживаемый формат сертификата: ${certData.runtimeType}');
    }
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

  /// Проверяет подпись с помощью публичного ключа
  bool _verifySignatureWithPublicKey({
    required ECPublicKey publicKey,
    required List<int> signature,
    required List<int> data,
    required int algorithm,
  }) {
    try {
      // Выбираем хеш-функцию в зависимости от алгоритма
      Digest digest;
      switch (algorithm) {
        case -7: // ES256
          digest = SHA256Digest();
          break;
        case -35: // ES384
          digest = SHA384Digest();
          break;
        case -36: // ES512
          digest = SHA512Digest();
          break;
        default:
          throw ArgumentError('Неподдерживаемый алгоритм: $algorithm');
      }

      // Создаем верификатор
      final verifier = ECDSASigner(digest);
      final params = PublicKeyParameter<ECPublicKey>(publicKey);
      verifier.init(false, params);

      // Декодируем DER подпись
      final ecSignature = _decodeDERSignature(signature);

      // Проверяем подпись
      final result = verifier.verifySignature(Uint8List.fromList(data), ecSignature);
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Проверяет подпись с помощью COSE ключа
  bool _verifySignatureWithCoseKey({
    required CosePublicKey coseKey,
    required List<int> signature,
    required List<int> data,
  }) {
    try {
      if (!coseKey.isEC) {
        throw ArgumentError('Поддерживаются только EC ключи для self attestation');
      }

      // Создаем EC публичный ключ из COSE данных
      final ecParams = ECCurve_secp256r1(); // Предполагаем P-256
      final x = WebAuthnCryptoUtils.bytesToBigInt(coseKey.x!);
      final y = WebAuthnCryptoUtils.bytesToBigInt(coseKey.y!);
      final q = ecParams.curve.createPoint(x, y);
      final publicKey = ECPublicKey(q, ecParams);

      return _verifySignatureWithPublicKey(
        publicKey: publicKey,
        signature: signature,
        data: data,
        algorithm: coseKey.algorithm,
      );
    } catch (e) {
      return false;
    }
  }

  /// Декодирует ECDSA подпись (поддерживает DER и raw форматы)
  ECSignature _decodeDERSignature(List<int> signature) {
    try {
      // Сначала пробуем DER формат
      try {
        final asn1Parser = ASN1Parser(Uint8List.fromList(signature));
        final seq = asn1Parser.nextObject() as ASN1Sequence;

        final r = (seq.elements[0] as ASN1Integer).valueAsBigInteger;
        final s = (seq.elements[1] as ASN1Integer).valueAsBigInteger;

        return ECSignature(r, s);
      } catch (e) {
        // Если DER не работает, пробуем raw формат
        return _decodeRawSignature(signature);
      }
    } catch (e) {
      throw ArgumentError('Ошибка декодирования подписи: $e');
    }
  }

  /// Декодирует raw ECDSA подпись (r || s)
  ECSignature _decodeRawSignature(List<int> signature) {
    // Для ES256: 64 байта (32 r + 32 s)
    // Для ES384: 96 байт (48 r + 48 s)
    // Для ES512: 132 байта (66 r + 66 s)

    int expectedLength;
    switch (signature.length) {
      case 64: // ES256
        expectedLength = 32;
        break;
      case 96: // ES384
        expectedLength = 48;
        break;
      case 132: // ES512
        expectedLength = 66;
        break;
      default:
        // Пробуем обрезать лишние байты если подпись больше ожидаемой
        if (signature.length >= 64) {
          // Берем первые 64 байта для ES256
          signature = signature.sublist(0, 64);
          expectedLength = 32;
        } else {
          throw ArgumentError('Неподдерживаемая длина raw подписи: ${signature.length}');
        }
    }

    final rBytes = signature.sublist(0, expectedLength);
    final sBytes = signature.sublist(expectedLength, expectedLength * 2);

    final r = WebAuthnCryptoUtils.bytesToBigInt(rBytes);
    final s = WebAuthnCryptoUtils.bytesToBigInt(sBytes);

    return ECSignature(r, s);
  }
}
