import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:licensify/licensify.dart';

/// Extension helpers for deriving Licensify symmetric keys from user passwords.
extension LicensifyPasswordDerivation on Licensify {
  /// Derives raw key material from a [password] and [salt] using PBKDF2-HMAC-SHA256.
  ///
  /// The [iterations] and [length] parameters default to the values used by
  /// `rpc_dart_data`, but callers may override them to align with the snapshot
  /// payload they are processing.
  static Uint8List deriveKeyFromPassword({
    required String password,
    required Uint8List salt,
    int iterations = 150000,
    int length = 32,
  }) {
    if (iterations <= 0) {
      throw ArgumentError.value(iterations, 'iterations', 'Must be positive');
    }
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'Must be positive');
    }

    final passwordBytes = utf8.encode(password);
    final hmac = Hmac(sha256, passwordBytes);
    final hLen = sha256.convert(const <int>[]).bytes.length;
    final blockCount = (length + hLen - 1) ~/ hLen;
    final result = Uint8List(length);
    final saltWithBlock = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt);

    var offset = 0;
    for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
      final blockIndexBytes = ByteData(4)..setUint32(0, blockIndex);
      saltWithBlock.setRange(
        salt.length,
        salt.length + 4,
        blockIndexBytes.buffer.asUint8List(),
      );

      var u = hmac.convert(saltWithBlock).bytes;
      final block = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < block.length; j++) {
          block[j] ^= u[j];
        }
      }

      final take = min(block.length, length - offset);
      result.setRange(offset, offset + take, block.sublist(0, take));
      offset += take;
    }

    return result;
  }

  /// Convenience helper that returns a [LicensifySymmetricKey] derived from the
  /// provided [password] and [salt]. The caller is responsible for disposing the
  /// returned key once it is no longer needed.
  static LicensifySymmetricKey deriveSymmetricKeyFromPassword({
    required String password,
    required Uint8List salt,
    int iterations = 150000,
    int length = 32,
  }) {
    final keyBytes = deriveKeyFromPassword(
      password: password,
      salt: salt,
      iterations: iterations,
      length: length,
    );
    return Licensify.encryptionKeyFromBytes(keyBytes);
  }

  /// Generates a new random salt, derives a symmetric key using PBKDF2 and
  /// returns the bundle. The caller is responsible for persisting the returned
  /// salt alongside the encrypted payload so the key can be re-derived later.
  static LicensifyDerivedPasswordKey deriveSymmetricKeyWithGeneratedSalt({
    required String password,
    int saltLength = 16,
    int iterations = 150000,
    int length = 32,
    Random? random,
  }) {
    if (saltLength <= 0) {
      throw ArgumentError.value(saltLength, 'saltLength', 'Must be positive');
    }

    final salt = _randomBytes(saltLength, random);
    final key = deriveSymmetricKeyFromPassword(
      password: password,
      salt: salt,
      iterations: iterations,
      length: length,
    );

    return LicensifyDerivedPasswordKey._(
      salt: salt,
      iterations: iterations,
      keyLength: length,
      symmetricKey: key,
    );
  }
}

/// Container for a PBKDF2-derived symmetric key along with the parameters that
/// must be preserved to re-derive it in the future.
class LicensifyDerivedPasswordKey {
  LicensifyDerivedPasswordKey._({
    required Uint8List salt,
    required this.iterations,
    required this.keyLength,
    required this.symmetricKey,
  }) : _salt = Uint8List.fromList(salt);

  final Uint8List _salt;
  final int iterations;
  final int keyLength;
  final LicensifySymmetricKey symmetricKey;

  /// Returns a copy of the PBKDF2 salt used during derivation.
  Uint8List get salt => Uint8List.fromList(_salt);

  /// Releases the underlying symmetric key material.
  void dispose() {
    symmetricKey.dispose();
  }
}

Uint8List _randomBytes(int length, Random? random) {
  final generator = random ?? _defaultRandom();
  final buffer = Uint8List(length);
  for (var i = 0; i < length; i++) {
    buffer[i] = generator.nextInt(256);
  }
  return buffer;
}

Random _defaultRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}
