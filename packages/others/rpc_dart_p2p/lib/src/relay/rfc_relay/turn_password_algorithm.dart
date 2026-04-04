// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Password algorithms defined by RFC 8656 section 14.7.
enum TurnPasswordAlgorithm {
  /// Legacy HMAC-SHA1 integrity check with MD5 long-term key derivation.
  hmacSha1Md5(0x0001, 20),

  /// HMAC-SHA256 integrity check with SHA-256 long-term key derivation.
  hmacSha256(0x0002, 32);

  const TurnPasswordAlgorithm(this.wireValue, this.integrityLength);

  /// Numeric identifier advertised in PASSWORD-ALGORITHM(S) attributes.
  final int wireValue;

  /// Expected length of the MESSAGE-INTEGRITY digest in bytes.
  final int integrityLength;

  /// Returns the enum instance matching [value] if supported.
  static TurnPasswordAlgorithm? fromWireValue(int value) {
    for (final algorithm in TurnPasswordAlgorithm.values) {
      if (algorithm.wireValue == value) {
        return algorithm;
      }
    }
    return null;
  }
}

/// Encodes a PASSWORD-ALGORITHMS attribute payload.
Uint8List encodePasswordAlgorithms(Iterable<TurnPasswordAlgorithm> algorithms) {
  final builder = BytesBuilder();
  for (final algorithm in algorithms) {
    builder.add(encodePasswordAlgorithm(algorithm));
  }
  return builder.toBytes();
}

/// Encodes a single PASSWORD-ALGORITHM attribute payload.
Uint8List encodePasswordAlgorithm(TurnPasswordAlgorithm algorithm) {
  final data = ByteData(4);
  data.setUint16(0, algorithm.wireValue);
  data.setUint16(2, 0); // Parameters length - none supported.
  return data.buffer.asUint8List();
}

/// Parses a PASSWORD-ALGORITHM attribute value.
TurnPasswordAlgorithm? decodePasswordAlgorithm(Uint8List value) {
  if (value.length < 4) {
    return null;
  }
  final data = ByteData.sublistView(value);
  final algorithm = data.getUint16(0);
  final paramsLength = data.getUint16(2);
  if (paramsLength != value.length - 4 || paramsLength != 0) {
    return null;
  }
  return TurnPasswordAlgorithm.fromWireValue(algorithm);
}
