// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What the peer on the far side of a connection does. Produced by a channel
// wrapper (channel), a TCP proxy or fake server (http, http2, websocket), or
// the worker itself (isolate).

import 'dart:math';
import 'dart:typed_data';

/// The far side's behaviour.
enum PeerBehaviour {
  /// A working server.
  normal,

  /// Accepts the connection, reads everything, never answers.
  silent,

  /// A working server behind a link that delays every chunk.
  slow,

  /// Answers, then the connection is destroyed in the middle of a response.
  closesMidMessage,

  /// Answers, then stops sending (FIN) in the middle of a response while it
  /// keeps reading.
  halfClose,
}

/// Delay a slow link adds to every chunk, each direction.
const slowChunkDelay = Duration(milliseconds: 30);

/// Server-to-client bytes a cutting peer lets through before it cuts. Above
/// every handshake here, far below the [cutResponseSize] response it cuts.
const cutAfterBytes = 2048;

/// Response size the I-1 rows ask for, so a cut lands inside a message.
const cutResponseSize = 64 * 1024;

/// Deterministic bytes: the same [seed] gives the same garbage on every run.
Uint8List garbage(int length, {int seed = 1}) {
  final rng = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rng.nextInt(256)),
  );
}

/// [bytes] with every 16th byte after the first quarter flipped: the framing
/// starts out valid and goes wrong part-way, at a place that varies with the
/// recording rather than with the test.
Uint8List corrupted(List<int> bytes) {
  final out = Uint8List.fromList(bytes);
  for (var i = out.length ~/ 4; i < out.length; i += 16) {
    out[i] ^= 0xA5;
  }
  return out;
}
