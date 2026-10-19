// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// [text] a peer sent, made safe to put in a log or an error message:
/// characters outside printable ASCII escaped as `\u{...}`, and, with
/// [maxRunes], at most that many of them followed by `...`.
///
/// A CR or LF in peer text would otherwise forge a line in the receiver's
/// log, an ESC act on its terminal, and its length is the peer's to choose.
String rpcPeerText(String text, {int? maxRunes}) {
  final out = StringBuffer();
  var count = 0;
  for (final rune in text.runes) {
    if (maxRunes != null && count == maxRunes) {
      out.write('...');
      break;
    }
    if (rune >= 0x20 && rune <= 0x7e) {
      out.writeCharCode(rune);
    } else {
      out.write('\\u{${rune.toRadixString(16)}}');
    }
    count++;
  }
  return out.toString();
}
