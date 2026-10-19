// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Whether printing [rune] changes how the text around it reads:
///
/// - the C0 controls but tab, and DEL: CR and LF start a forged line, ESC
///   drives the terminal;
/// - the C1 controls, U+0080 to U+009F, some of which terminals obey too;
/// - the bidirectional formatting characters (U+061C, U+200E, U+200F,
///   U+202A to U+202E, U+2066 to U+2069), which reorder what is shown;
/// - U+2028 and U+2029, which some viewers break lines on.
///
/// Every other code point, non-ASCII text included, prints as itself.
bool rpcIsUnsafeCodePoint(int rune) =>
    (rune < 0x20 && rune != 0x09) ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x061c ||
    rune == 0x200e ||
    rune == 0x200f ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2066 && rune <= 0x2069) ||
    rune == 0x2028 ||
    rune == 0x2029;

/// [text] a peer sent, made safe to put in a log or an error message.
///
/// With [asciiOnly], the default, every code point outside printable ASCII is
/// escaped: the form for a protocol message, whose reader may not render
/// anything else. Without it only [rpcIsUnsafeCodePoint]s are, so Cyrillic or
/// an emoji stays readable: the form for a log line.
///
/// Escapes are `\n`, `\r`, `\t` and `\u{hex}`, and a backslash is doubled, so
/// a peer cannot write text that reads as an escape. With [maxRunes], at most
/// that many code points are kept, followed by `...`: the length of peer text
/// is the peer's to choose.
String rpcPeerText(String text, {bool asciiOnly = true, int? maxRunes}) {
  bool escaped(int rune) =>
      rune == 0x5c ||
      rpcIsUnsafeCodePoint(rune) ||
      (asciiOnly && (rune < 0x20 || rune > 0x7e));

  // Most text needs nothing, and a console escapes every line it prints.
  if (maxRunes == null && !text.runes.any(escaped)) return text;

  final out = StringBuffer();
  var count = 0;
  for (final rune in text.runes) {
    if (maxRunes != null && count == maxRunes) {
      out.write('...');
      break;
    }
    count++;
    if (!escaped(rune)) {
      out.writeCharCode(rune);
      continue;
    }
    switch (rune) {
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        out.write('\\u{${rune.toRadixString(16)}}');
    }
  }
  return out.toString();
}
