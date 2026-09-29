// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The channel decodes straight out of the inbound chunk when nothing is buffered,
// rather than copying it into `_buf` first — the ordinary case on a
// message-aligned transport, where the chunk already holds whole frames.
//
// The risk in that is FRAMING, not speed: the buffered path is still needed the
// moment a chunk does not end on a frame boundary, and the two paths have to
// agree. These tests drive the boundary cases with payloads whose bytes identify
// their frame, so an off-by-one in the tail handling shows up as wrong CONTENT and
// not merely as a wrong count.
//
// The measurement behind the change is in `.claude/loop/rounds/507`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Pipe implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }

  void feed(Uint8List chunk) {
    if (!_ctl.isClosed) _ctl.add(chunk);
  }
}

/// A payload whose every byte is [tag], so a decoded frame says which frame it
/// came from and a misaligned view is visible as content.
Uint8List _payload(int tag, int size) =>
    Uint8List.fromList(List<int>.filled(size, tag));

Uint8List _frame(int tag, int size, {int streamId = 1}) =>
    RpcChannelFrame.encodeData(
      streamId: streamId,
      payload: _payload(tag, size),
    );

Uint8List _join(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (a, p) => a + p.length);
  final out = Uint8List(total);
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

/// Feeds [chunks] and returns one `(tag, length)` per decoded frame.
Future<List<(int, int)>> _decode(List<Uint8List> chunks) async {
  final pipe = _Pipe();
  final channel = RpcFrameMultiplexedChannel(channel: pipe);
  addTearDown(() async {
    await pipe.close();
    await channel.close();
  });

  final out = <(int, int)>[];
  channel.incoming.listen((m) {
    final p = m.payload!;
    // Read the whole payload, not just its first byte: a view built with the
    // wrong offset OR the wrong length has to be caught, and only scanning it
    // catches the second.
    final tag = p.isEmpty ? -1 : p.first;
    final uniform = p.every((b) => b == tag);
    out.add((uniform ? tag : -2, p.length));
  });

  for (final c in chunks) {
    pipe.feed(c);
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return out;
}

void main() {
  // EVERY test in this file is a GUARD, and that is not an accident: the defect
  // is a COST, so no test can witness it — all nine pass with the fast path
  // ablated. The witness is the bench, and these exist so the speed-up cannot be
  // bought with a framing bug.
  group('GUARD: a chunk holding whole frames decodes correctly in place', () {
    test('one whole frame per chunk', () async {
      expect(await _decode([_frame(7, 100), _frame(9, 200)]), [
        (7, 100),
        (9, 200),
      ]);
    });

    test('several whole frames in ONE chunk', () async {
      expect(
        await _decode([
          _join([_frame(1, 10), _frame(2, 20), _frame(3, 30)]),
        ]),
        [(1, 10), (2, 20), (3, 30)],
      );
    });
  });

  group('GUARD: the buffered path still handles every split', () {
    test('a frame split across two chunks', () async {
      final f = _frame(5, 500);
      expect(
        await _decode([
          Uint8List.sublistView(f, 0, 200),
          Uint8List.sublistView(f, 200),
        ]),
        [(5, 500)],
      );
    });

    test('a split INSIDE the 9-byte header', () async {
      // The header is what the decoder reads first, so a split here is the case
      // that breaks a decoder which assumes it can always read 9 bytes.
      final f = _frame(6, 64);
      expect(
        await _decode([
          Uint8List.sublistView(f, 0, 4),
          Uint8List.sublistView(f, 4),
        ]),
        [(6, 64)],
      );
    });

    test('a whole frame plus a PARTIAL one, then the rest', () async {
      // The tail case, and the one the fast path has to get right: the chunk is
      // decoded in place, part of it is consumed, and what is left must be
      // buffered from the correct offset. An off-by-one shows up as a wrong tag
      // or a wrong length rather than as a missing frame.
      final a = _frame(11, 48);
      final b = _frame(22, 96);
      expect(
        await _decode([
          _join([a, Uint8List.sublistView(b, 0, 30)]),
          Uint8List.sublistView(b, 30),
        ]),
        [(11, 48), (22, 96)],
      );
    });

    test(
      'a partial tail followed by MORE whole frames in the next chunk',
      () async {
        // Exercises the transition back: the buffer is non-empty on entry (slow
        // path), is fully consumed, and the chunk after that takes the fast path
        // again.
        final a = _frame(31, 40);
        final b = _frame(32, 40);
        final c = _frame(33, 40);
        expect(
          await _decode([
            Uint8List.sublistView(a, 0, 20),
            _join([Uint8List.sublistView(a, 20), b]),
            c,
          ]),
          [(31, 40), (32, 40), (33, 40)],
        );
      },
    );

    test('byte-at-a-time delivery still reassembles', () async {
      // The worst case for a decoder that assumes chunk boundaries mean
      // anything: every chunk is one byte, so the fast path is taken only for
      // the very first byte of each frame and never completes a frame.
      final f = _frame(44, 24);
      expect(
        await _decode([
          for (var i = 0; i < f.length; i++) Uint8List.sublistView(f, i, i + 1),
        ]),
        [(44, 24)],
      );
    });

    test('a zero-length payload decodes on both paths', () async {
      expect(
        await _decode([
          _join([_frame(0, 0), _frame(8, 8)]),
        ]),
        [(-1, 0), (8, 8)],
      );
    });
  });

  test('GUARD: the payload is never a misaligned view', () async {
    // Every arm above already checks uniformity, and this states the reason
    // separately: a payload that is uniform in the WRONG byte would read as a
    // different frame's content, and `-2` is what a mixed payload reports.
    final decoded = await _decode([
      _join([_frame(101, 17), _frame(102, 33), _frame(103, 65)]),
    ]);
    expect(decoded, [(101, 17), (102, 33), (103, 65)]);
    expect(decoded.map((e) => e.$1), isNot(contains(-2)));
  });
}
