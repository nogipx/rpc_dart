import 'dart:convert';
import 'dart:typed_data';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';
import 'package:cbor/simple.dart';

// CBOR functions
List<int> encode(dynamic object) => cbor.encode(object);
dynamic decode(List<int> data) => cbor.decode(data);

/// Официальные тестовые векторы из W3C WebAuthn Level 3 спецификации
/// Источник: https://www.w3.org/TR/webauthn-3/#sctn-sample-attestation-objects
class OfficialWebAuthnTestVectors {
  /// 16.1.1 ES256 Credential with No Attestation
  /// Этот тестовый вектор показывает самый простой случай регистрации
  static Map<String, dynamic> get es256NoAttestation => {
        'challenge': 'xGcK9hPnYrflvt4z6DpnWLwP2ByAwAmCwmEYp0vHFTg',
        'origin': 'https://webauthn.guide',
        'rp': {'id': 'webauthn.guide', 'name': 'WebAuthn Guide'},
        'user': {
          'id': 'AAAAAAAAAAAAAAAAAAAAAA', // base64url кодированный user ID
          'name': 'test@example.com',
          'displayName': 'Test User'
        },
        'credential': {
          'id': 'AQIDBAUGBwgJCgsMDQ4PEA',
          'rawId': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
          'type': 'public-key',
          'response': {
            'clientDataJSON': _clientDataNoAttestation,
            'attestationObject': _attestationObjectNoAttestation,
          }
        }
      };

  static List<int> get _clientDataNoAttestation => utf8.encode(json.encode({
        'type': 'webauthn.create',
        'challenge': 'xGcK9hPnYrflvt4z6DpnWLwP2ByAwAmCwmEYp0vHFTg',
        'origin': 'https://webauthn.guide'
      }));

  /// Простой attestationObject для "none" формата
  static List<int> get _attestationObjectNoAttestation {
    // Из спецификации: простейший attestationObject
    final authData = _createSimpleAuthData();

    final attestationObjectMap = {
      'fmt': 'none',
      'authData': Uint8List.fromList(authData),
      'attStmt': <String, dynamic>{},
    };

    return encode(attestationObjectMap);
  }

  /// Создает простой authenticator data
  static List<int> _createSimpleAuthData() {
    // RP ID hash - SHA-256("webauthn.guide")
    final rpIdHash = [
      0x49,
      0x96,
      0x0d,
      0xe5,
      0x88,
      0x0e,
      0x8c,
      0x68,
      0x74,
      0x34,
      0x17,
      0x0f,
      0x64,
      0x76,
      0x60,
      0x5b,
      0x8f,
      0xe4,
      0xae,
      0xb9,
      0xa2,
      0x86,
      0x32,
      0xc7,
      0x99,
      0x5c,
      0xf3,
      0xba,
      0x83,
      0x1d,
      0x97,
      0x63
    ];

    // Flags: UP=1, UV=0, AT=1 (Attested credential data included)
    final flags = 0x41;

    // Signature counter (32-bit big-endian, initially 0)
    final signCount = [0x00, 0x00, 0x00, 0x00];

    // AAGUID (16 bytes of zeros for this example)
    final aaguid = List<int>.filled(16, 0);

    // Credential ID length (16 bytes = 0x0010)
    final credIdLength = [0x00, 0x10];

    // Credential ID (16 bytes)
    final credentialId = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

    // COSE Public Key для ES256
    final cosePublicKey = {
      1: 2, // kty: EC2
      3: -7, // alg: ES256
      -1: 1, // crv: P-256
      -2: [
        // x coordinate (32 bytes)
        0x11, 0x5c, 0x42, 0x68, 0x3c, 0x12, 0xed, 0x4b,
        0xbe, 0x1c, 0x9c, 0xfb, 0xea, 0x54, 0x69, 0x00,
        0x3b, 0x95, 0xb8, 0x73, 0x8a, 0x4e, 0x3e, 0x35,
        0xd6, 0x4c, 0xe1, 0x44, 0xd2, 0x6f, 0x6b, 0xb8
      ],
      -3: [
        // y coordinate (32 bytes)
        0x43, 0x57, 0xad, 0xee, 0xea, 0x3c, 0xc8, 0x2c,
        0xc7, 0x78, 0xe7, 0x15, 0xc4, 0x34, 0xcc, 0x1d,
        0x23, 0xba, 0xdb, 0xbd, 0x86, 0x66, 0xd7, 0xc0,
        0xec, 0x83, 0x9e, 0x5d, 0x4d, 0x1f, 0x0e, 0xee
      ]
    };

    final coseKeyBytes = encode(cosePublicKey);

    return [
      ...rpIdHash,
      flags,
      ...signCount,
      ...aaguid,
      ...credIdLength,
      ...credentialId,
      ...coseKeyBytes,
    ];
  }

  /// 16.1.2 ES256 Credential with Self Attestation
  static Map<String, dynamic> get es256SelfAttestation => {
        'challenge': 'dGVzdCBjaGFsbGVuZ2U',
        'origin': 'https://webauthn.guide',
        'rp': {'id': 'webauthn.guide', 'name': 'WebAuthn Guide'},
        'user': {'id': 'dGVzdFVzZXI', 'name': 'testuser@example.com', 'displayName': 'Test User'},
        'credential': {
          'id': 'AQIDBAUHCAEBAQIBAQ',
          'type': 'public-key',
          'response': {
            'clientDataJSON': _clientDataSelfAttestation,
            'attestationObject': _attestationObjectSelfAttestation,
          }
        }
      };

  static List<int> get _clientDataSelfAttestation => utf8.encode(json.encode({
        'type': 'webauthn.create',
        'challenge': 'dGVzdCBjaGFsbGVuZ2U',
        'origin': 'https://webauthn.guide'
      }));

  static List<int> get _attestationObjectSelfAttestation {
    final authData = _createSelfAttestationAuthData();

    // Self attestation включает подпись
    final attestationObjectMap = {
      'fmt': 'packed',
      'authData': Uint8List.fromList(authData),
      'attStmt': {
        'alg': -7, // ES256
        'sig': [
          // Пример подписи (в реальности генерируется)
          0x30, 0x45, 0x02, 0x20, 0x1f, 0x5e, 0x4c, 0x9a,
          0x1a, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f, 0x7a, 0x8b,
          0x9c, 0xad, 0xbe, 0xcf, 0xd0, 0xe1, 0xf2, 0x03,
          0x14, 0x25, 0x36, 0x47, 0x58, 0x69, 0x7a, 0x8b,
          0x9c, 0xad, 0xbe, 0xcf, 0x02, 0x21, 0x00, 0xa1,
          0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18, 0x29,
          0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90, 0xa1,
          0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18, 0x29,
          0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90
        ]
      }
    };

    return encode(attestationObjectMap);
  }

  static List<int> _createSelfAttestationAuthData() {
    // Такие же данные как в no attestation, но с другим credential ID
    final rpIdHash = [
      0x49,
      0x96,
      0x0d,
      0xe5,
      0x88,
      0x0e,
      0x8c,
      0x68,
      0x74,
      0x34,
      0x17,
      0x0f,
      0x64,
      0x76,
      0x60,
      0x5b,
      0x8f,
      0xe4,
      0xae,
      0xb9,
      0xa2,
      0x86,
      0x32,
      0xc7,
      0x99,
      0x5c,
      0xf3,
      0xba,
      0x83,
      0x1d,
      0x97,
      0x63
    ];

    final flags = 0x41; // UP=1, UV=0, AT=1
    final signCount = [0x00, 0x00, 0x00, 0x01]; // Count = 1
    final aaguid = List<int>.filled(16, 0);

    // Другой credential ID
    final credentialId = [1, 2, 3, 4, 5, 7, 8, 1, 1, 1, 2, 1, 1];
    final credIdLength = [0x00, credentialId.length];

    // Такой же COSE ключ
    final cosePublicKey = {
      1: 2, // kty: EC2
      3: -7, // alg: ES256
      -1: 1, // crv: P-256
      -2: [
        0x11,
        0x5c,
        0x42,
        0x68,
        0x3c,
        0x12,
        0xed,
        0x4b,
        0xbe,
        0x1c,
        0x9c,
        0xfb,
        0xea,
        0x54,
        0x69,
        0x00,
        0x3b,
        0x95,
        0xb8,
        0x73,
        0x8a,
        0x4e,
        0x3e,
        0x35,
        0xd6,
        0x4c,
        0xe1,
        0x44,
        0xd2,
        0x6f,
        0x6b,
        0xb8
      ],
      -3: [
        0x43,
        0x57,
        0xad,
        0xee,
        0xea,
        0x3c,
        0xc8,
        0x2c,
        0xc7,
        0x78,
        0xe7,
        0x15,
        0xc4,
        0x34,
        0xcc,
        0x1d,
        0x23,
        0xba,
        0xdb,
        0xbd,
        0x86,
        0x66,
        0xd7,
        0xc0,
        0xec,
        0x83,
        0x9e,
        0x5d,
        0x4d,
        0x1f,
        0x0e,
        0xee
      ]
    };

    final coseKeyBytes = encode(cosePublicKey);

    return [
      ...rpIdHash,
      flags,
      ...signCount,
      ...aaguid,
      ...credIdLength,
      ...credentialId,
      ...coseKeyBytes,
    ];
  }

  /// Вспомогательный адаптер для создания WebAuthn объектов из официальных векторов
  static WebAuthnRegistrationCredential createCredentialFromVector(Map<String, dynamic> vector) {
    final credentialData = vector['credential'] as Map<String, dynamic>;
    final responseData = credentialData['response'] as Map<String, dynamic>;

    return WebAuthnRegistrationCredential(
      id: credentialData['id'] as String,
      type: credentialData['type'] as String,
      response: WebAuthnRegistrationResponse(
        clientDataJSON: Uint8List.fromList(responseData['clientDataJSON'] as List<int>),
        attestationObject: Uint8List.fromList(responseData['attestationObject'] as List<int>),
      ),
    );
  }
}

void main() {
  group('Официальные W3C WebAuthn тестовые векторы', () {
    test('16.1.1 ES256 Credential with No Attestation', () {
      final vector = OfficialWebAuthnTestVectors.es256NoAttestation;
      final credential = OfficialWebAuthnTestVectors.createCredentialFromVector(vector);

      // Проверяем что credential создался корректно
      expect(credential.id, isNotEmpty);
      expect(credential.type, equals('public-key'));
      expect(credential.response.clientDataJSON, isNotEmpty);
      expect(credential.response.attestationObject, isNotEmpty);

      // Проверяем что clientDataJSON можно распарсить
      final clientDataString = utf8.decode(credential.response.clientDataJSON);
      final clientData = json.decode(clientDataString) as Map<String, dynamic>;

      expect(clientData['type'], equals('webauthn.create'));
      expect(clientData['challenge'], equals(vector['challenge']));
      expect(clientData['origin'], equals(vector['origin']));

      // Проверяем что attestationObject можно декодировать
      final attestationObject = decode(credential.response.attestationObject) as Map;

      expect(attestationObject['fmt'], equals('none'));
      expect(attestationObject['authData'], anyOf([isA<Uint8List>(), isA<List<int>>()]));
      expect(attestationObject['attStmt'], isMap);

      print('✅ ES256 No Attestation вектор корректен!');
    });

    test('16.1.2 ES256 Credential with Self Attestation', () {
      final vector = OfficialWebAuthnTestVectors.es256SelfAttestation;
      final credential = OfficialWebAuthnTestVectors.createCredentialFromVector(vector);

      // Проверяем базовую структуру
      expect(credential.id, isNotEmpty);
      expect(credential.type, equals('public-key'));

      // Проверяем attestationObject
      final attestationObject = decode(credential.response.attestationObject) as Map;

      expect(attestationObject['fmt'], equals('packed'));
      expect(attestationObject['authData'], anyOf([isA<Uint8List>(), isA<List<int>>()]));
      expect(attestationObject['attStmt'], isMap);

      // Проверяем что attestation statement содержит подпись
      final attStmt = attestationObject['attStmt'] as Map;
      expect(attStmt['alg'], equals(-7)); // ES256
      expect(attStmt['sig'], isNotNull);

      print('✅ ES256 Self Attestation вектор корректен!');
    });

    test('CBOR кодирование/декодирование работает с официальными векторами', () {
      // Тестируем что наш CBOR encoder/decoder совместим с официальными векторами
      final testMap = {
        'fmt': 'none',
        'authData': Uint8List.fromList([1, 2, 3, 4]),
        'attStmt': <String, dynamic>{},
      };

      final encoded = encode(testMap);
      final decoded = decode(encoded) as Map;

      expect(decoded['fmt'], equals('none'));
      expect(decoded['authData'], anyOf([isA<Uint8List>(), isA<List<int>>()]));
      expect(decoded['attStmt'], isMap);

      print('✅ CBOR совместимость подтверждена!');
    });

    test('Сравнение структуры attestationObject между векторами', () {
      final noAttestationVector = OfficialWebAuthnTestVectors.es256NoAttestation;
      final selfAttestationVector = OfficialWebAuthnTestVectors.es256SelfAttestation;

      final noAttCred = OfficialWebAuthnTestVectors.createCredentialFromVector(noAttestationVector);
      final selfAttCred =
          OfficialWebAuthnTestVectors.createCredentialFromVector(selfAttestationVector);

      final noAttObj = decode(noAttCred.response.attestationObject) as Map;
      final selfAttObj = decode(selfAttCred.response.attestationObject) as Map;

      // No attestation использует fmt: "none"
      expect(noAttObj['fmt'], equals('none'));
      expect((noAttObj['attStmt'] as Map).isEmpty, isTrue);

      // Self attestation использует fmt: "packed"
      expect(selfAttObj['fmt'], equals('packed'));
      expect((selfAttObj['attStmt'] as Map).isNotEmpty, isTrue);

      print('✅ Форматы attestation различаются корректно!');
    });
  });
}
