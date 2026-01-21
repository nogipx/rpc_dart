// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:typed_data';

/// Generates cryptographically secure NanoIDs compatible with the original
/// JavaScript reference implementation.
final class NanoId {
  NanoId._();

  /// Default size used by the standard NanoID implementation.
  static const int defaultSize = 21;

  /// URL-safe alphabet identical to the JavaScript implementation.
  static const String defaultAlphabet =
      '_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

  static final math.Random _random = math.Random.secure();

  /// Generates a NanoID using [defaultAlphabet] and [defaultSize] by default.
  ///
  /// A cryptographically secure PRNG is used under the hood. The [alphabet]
  /// must not be empty and cannot contain more than 255 unique symbols, which
  /// mirrors the constraint in the original NanoID specification and prevents
  /// modulo bias when mapping random bytes to the alphabet.
  static String generate({
    int size = defaultSize,
    String alphabet = defaultAlphabet,
  }) {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be positive');
    }
    if (alphabet.isEmpty) {
      throw ArgumentError.value(alphabet, 'alphabet', 'must not be empty');
    }
    if (alphabet.length > 255) {
      throw ArgumentError.value(
        alphabet,
        'alphabet',
        'must not contain more than 255 symbols',
      );
    }

    if (alphabet.length == 1) {
      final builder = StringBuffer();
      for (var i = 0; i < size; i++) {
        builder.write(alphabet);
      }
      return builder.toString();
    }

    final length = alphabet.length;
    final mask = (2 << ((math.log(length - 1) / math.ln2).floor())) - 1;
    final step = ((1.6 * mask * size) / length).ceil();

    final builder = StringBuffer();

    while (true) {
      final bytes = Uint8List(step);
      for (var i = 0; i < step; i++) {
        bytes[i] = _random.nextInt(256);
      }

      for (var i = 0; i < step; i++) {
        final index = bytes[i] & mask;
        if (index < length) {
          builder.write(alphabet[index]);
          if (builder.length == size) {
            return builder.toString();
          }
        }
      }
    }
  }
}
