import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';
import 'package:test/test.dart';

void main() {
  group('LicensifyPasswordDerivation', () {
    test('derives PBKDF2 key material matching reference vector', () {
      final password = 'secret-password';
      final salt = Uint8List.fromList(utf8.encode('salty-salt'));

      final derived = LicensifyPasswordDerivation.deriveKeyFromPassword(
        password: password,
        salt: salt,
        iterations: 5,
        length: 32,
      );

      final hex =
          derived.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

      expect(
        hex,
        equals(
            'a9cd518f00829f8f96cf504362af47e782fd1b2d3ed9fba8b0809a394c4d857b'),
      );
    });

    test('generates salted key bundle that can be re-derived', () async {
      final randomSeed = 42;
      final random = Random(randomSeed);
      final bundle =
          LicensifyPasswordDerivation.deriveSymmetricKeyWithGeneratedSalt(
        password: 'top-secret',
        saltLength: 8,
        iterations: 1000,
        length: 16,
        random: random,
      );

      final expectedSaltGenerator = Random(randomSeed);
      final expectedSalt = Uint8List.fromList(List<int>.generate(
        8,
        (_) => expectedSaltGenerator.nextInt(256),
      ));

      expect(bundle.salt, expectedSalt);
      expect(bundle.iterations, 1000);
      expect(bundle.keyLength, 16);

      final token = await Licensify.encryptData(
        data: const {'value': 'payload'},
        encryptionKey: bundle.symmetricKey,
        implicitAssertion: 'test-assertion',
      );

      final salt = bundle.salt;
      final rederived =
          LicensifyPasswordDerivation.deriveSymmetricKeyFromPassword(
        password: 'top-secret',
        salt: salt,
        iterations: bundle.iterations,
        length: bundle.keyLength,
      );

      try {
        final decrypted = await Licensify.decryptData(
          encryptedToken: token,
          encryptionKey: rederived,
          implicitAssertion: 'test-assertion',
        );

        expect(decrypted['value'], 'payload');
      } finally {
        rederived.dispose();
        bundle.dispose();
      }
    });
  });
}
