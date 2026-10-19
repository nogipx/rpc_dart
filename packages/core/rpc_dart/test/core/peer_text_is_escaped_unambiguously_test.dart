// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// rpcPeerText makes text a peer sent safe to print. The lenient form, which a
// log line uses, escapes only the code points that change how text reads and
// keeps the rest -- Cyrillic, emoji. Both forms double a backslash, so no
// peer text reads as an escape it is not.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

String _lenient(String text) => rpcPeerText(text, asciiOnly: false);

void main() {
  group('the lenient form', () {
    test('keeps non-ASCII text as it is', () {
      expect(_lenient('привет, мир 👋'), 'привет, мир 👋');
    });

    test('escapes line breaks, ESC and DEL', () {
      expect(_lenient('a\r\nb\x1b[2Jc\x7fd'), r'a\r\nb\u{1b}[2Jc\u{7f}d');
    });

    test('keeps a tab', () {
      expect(_lenient('a\tb'), 'a\tb');
    });

    test('escapes C1 controls', () {
      expect(_lenient('a\u0085b\u009bc'), r'a\u{85}b\u{9b}c');
    });

    test('escapes the bidirectional controls', () {
      for (final rune in [
        0x061c,
        0x200e,
        0x200f,
        0x202a,
        0x202e,
        0x2066,
        0x2069,
      ]) {
        final escaped = _lenient('a${String.fromCharCode(rune)}b');
        expect(escaped, 'a\\u{${rune.toRadixString(16)}}b');
      }
    });

    test('escapes the line and paragraph separators', () {
      expect(_lenient('a\u2028b\u2029c'), r'a\u{2028}b\u{2029}c');
    });

    test('doubles a backslash, so an escape cannot be forged', () {
      // A peer writing a literal `\n` must not read like an escaped LF.
      expect(_lenient(r'a\nb'), r'a\\nb');
      expect(_lenient('a\nb'), r'a\nb');
    });

    test('ConsoleOutput.escapeLine is this form', () {
      const text = 'строка\r\nforged \u202Ereversed\u202C \\ end';
      expect(ConsoleOutput.escapeLine(text), _lenient(text));
    });
  });

  group('the ASCII form', () {
    test('escapes everything outside printable ASCII', () {
      expect(rpcPeerText('мир\tok'), r'\u{43c}\u{438}\u{440}\tok');
    });

    test('doubles a backslash too', () {
      expect(rpcPeerText(r'\u{a}'), r'\\u{a}');
    });

    test('keeps at most maxRunes code points', () {
      expect(rpcPeerText('abcdef', maxRunes: 3), 'abc...');
      expect(rpcPeerText('abc', maxRunes: 3), 'abc');
    });
  });

  test('a string with nothing to escape is returned as it is', () {
    const text = 'plain ascii, nothing to escape';
    expect(identical(rpcPeerText(text), text), isTrue);
  });
}
