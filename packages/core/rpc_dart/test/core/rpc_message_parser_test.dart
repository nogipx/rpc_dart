// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a gRPC frame: [flag(1)] [length(4 BE)] [payload].
Uint8List _frame(List<int> payload, {bool compressed = false}) {
  return RpcMessageFrame.encode(
    Uint8List.fromList(payload),
    compressed: compressed,
  );
}

/// Concatenates several byte lists into one Uint8List.
Uint8List _concat(List<Uint8List> parts) {
  final total = parts.fold(0, (s, p) => s + p.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final p in parts) {
    out.setRange(offset, offset + p.length, p);
    offset += p.length;
  }
  return out;
}

void main() {
  // -------------------------------------------------------------------------
  // Basic correctness
  // -------------------------------------------------------------------------
  group('RpcMessageParser - the basics', () {
    test('one message in one chunk', () {
      final parser = RpcMessageParser();
      final payload = [1, 2, 3, 4, 5];
      final chunk = _frame(payload);

      final result = parser(chunk);

      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('an empty message, length zero', () {
      final parser = RpcMessageParser();
      final chunk = _frame([]);

      final result = parser(chunk);

      expect(result, hasLength(1));
      expect(result[0], isEmpty);
    });

    test('an empty chunk yields an empty list', () {
      final parser = RpcMessageParser();

      final result = parser(Uint8List(0));

      expect(result, isEmpty);
    });

    test('a header with no body waits for the next chunk', () {
      final parser = RpcMessageParser();
      final full = _frame([10, 20, 30]);
      // Just the 5-byte header.
      final headerOnly = full.sublist(0, 5);
      final body = full.sublist(5);

      expect(parser(headerOnly), isEmpty);
      final result = parser(body);
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([10, 20, 30])));
    });

    test('a partial header, under 5 bytes, waits too', () {
      final parser = RpcMessageParser();
      final full = _frame([42]);

      // One byte at a time.
      for (var i = 0; i < 4; i++) {
        expect(parser(full.sublist(i, i + 1)), isEmpty);
      }
      // The last header byte plus the body.
      final result = parser(full.sublist(4));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([42])));
    });

    test('a partial body is held across calls', () {
      final parser = RpcMessageParser();
      final payload = List.generate(100, (i) => i);
      final full = _frame(payload); // 105 bytes

      // 10 bytes at a time; the last chunk is whatever is left.
      const chunkSize = 10;
      List<Uint8List>? lastResult;
      for (var i = 0; i < full.length; i += chunkSize) {
        final end = (i + chunkSize < full.length) ? i + chunkSize : full.length;
        final chunk = full.sublist(i, end);
        lastResult = parser(chunk);
        if (end < full.length) {
          expect(lastResult, isEmpty, reason: 'the body is not complete yet');
        }
      }
      expect(lastResult, hasLength(1));
      expect(lastResult![0], equals(Uint8List.fromList(payload)));
    });
  });

  // -------------------------------------------------------------------------
  // Fragmentation: one message split across multiple chunks
  // -------------------------------------------------------------------------
  group('RpcMessageParser - fragmentation', () {
    test('split into 2 chunks exactly at the header boundary', () {
      final parser = RpcMessageParser();
      final payload = [0xAA, 0xBB, 0xCC];
      final full = _frame(payload);
      // Split immediately after the 5-byte header.
      final part1 = full.sublist(0, 5);
      final part2 = full.sublist(5);

      expect(parser(part1), isEmpty);
      final result = parser(part2);
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('split in the middle of the body', () {
      final parser = RpcMessageParser();
      final payload = List.generate(20, (i) => i * 2);
      final full = _frame(payload);
      final mid = full.length ~/ 2;

      expect(parser(full.sublist(0, mid)), isEmpty);
      final result = parser(full.sublist(mid));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('split into N one-byte chunks', () {
      final parser = RpcMessageParser();
      final payload = [1, 2, 3];
      final full = _frame(payload);

      for (var i = 0; i < full.length - 1; i++) {
        expect(
          parser(full.sublist(i, i + 1)),
          isEmpty,
          reason: 'it must still be waiting after byte $i',
        );
      }
      final result = parser(full.sublist(full.length - 1));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('two messages, each fragmented', () {
      final parser = RpcMessageParser();
      final msg1 = _frame([1, 2, 3]);
      final msg2 = _frame([4, 5, 6]);
      // The stream: first half of msg1 | second half of msg1 + all of msg2.
      final part1 = msg1.sublist(0, 4);
      final part2 = _concat([msg1.sublist(4), msg2]);

      expect(parser(part1), isEmpty);
      final result = parser(part2);
      expect(result, hasLength(2));
      expect(result[0], equals(Uint8List.fromList([1, 2, 3])));
      expect(result[1], equals(Uint8List.fromList([4, 5, 6])));
    });
  });

  // -------------------------------------------------------------------------
  // Batching: multiple messages in a single chunk (O(N²) regression target)
  // -------------------------------------------------------------------------
  group('RpcMessageParser - several messages in one chunk', () {
    test('2 messages in one chunk', () {
      final parser = RpcMessageParser();
      final chunk = _concat([
        _frame([1, 2]),
        _frame([3, 4]),
      ]);

      final result = parser(chunk);

      expect(result, hasLength(2));
      expect(result[0], equals(Uint8List.fromList([1, 2])));
      expect(result[1], equals(Uint8List.fromList([3, 4])));
    });

    test('10 messages in one chunk', () {
      final parser = RpcMessageParser();
      final messages = List.generate(10, (i) => [i, i + 1, i + 2]);
      final chunk = _concat(messages.map(_frame).toList());

      final result = parser(chunk);

      expect(result, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(result[i], equals(Uint8List.fromList(messages[i])));
      }
    });

    test('1000 messages in one chunk, an O(N^2) regression guard', () {
      final parser = RpcMessageParser(maxMessagesPerChunk: 2000);
      final payload = [0xDE, 0xAD];
      final chunk = _concat(List.generate(1000, (_) => _frame(payload)));

      final result = parser(chunk);

      expect(result, hasLength(1000));
      for (final msg in result) {
        expect(msg, equals(Uint8List.fromList(payload)));
      }
    });

    test('the buffer is clear after a batch, so the next one parses', () {
      final parser = RpcMessageParser();
      final batch = _concat([
        _frame([1]),
        _frame([2]),
        _frame([3]),
      ]);
      final next = _frame([99]);

      final r1 = parser(batch);
      final r2 = parser(next);

      expect(r1, hasLength(3));
      expect(r2, hasLength(1));
      expect(r2[0], equals(Uint8List.fromList([99])));
    });

    test('a batch plus a trailing fragment of the next message', () {
      final parser = RpcMessageParser();
      final msg1 = _frame([1, 2]);
      final msg2 = _frame([3, 4]);
      final msg3 = _frame([5, 6]);
      // All of msg1 and msg2, then only msg3's header.
      final chunk1 = _concat([msg1, msg2, msg3.sublist(0, 5)]);
      final chunk2 = msg3.sublist(5);

      final r1 = parser(chunk1);
      final r2 = parser(chunk2);

      expect(r1, hasLength(2));
      expect(r2, hasLength(1));
      expect(r2[0], equals(Uint8List.fromList([5, 6])));
    });
  });

  // -------------------------------------------------------------------------
  // Limits & error handling
  // -------------------------------------------------------------------------
  group('RpcMessageParser - limits and errors', () {
    test('exceeding maxMessageLength throws RpcException', () {
      final parser = RpcMessageParser(maxMessageLength: 4);
      final chunk = _frame([1, 2, 3, 4, 5]); // 5 bytes > the limit of 4

      expect(() => parser(chunk), throwsA(isA<RpcException>()));
    });

    test('exceeding maxBufferedBytes throws RpcException', () {
      final parser = RpcMessageParser(
        maxMessageLength: 100,
        maxBufferedBytes: 10,
      );
      // An unfinished 20-byte frame.
      final partial = Uint8List(20);

      expect(() => parser(partial), throwsA(isA<RpcException>()));
    });

    test('exceeding maxMessagesPerChunk throws RpcException', () {
      final parser = RpcMessageParser(maxMessagesPerChunk: 2);
      // 3 messages: the third must throw.
      final chunk = _concat([
        _frame([1]),
        _frame([2]),
        _frame([3]),
      ]);

      expect(() => parser(chunk), throwsA(isA<RpcException>()));
    });

    test('the parser recovers after a maxMessageLength error', () {
      final parser = RpcMessageParser(maxMessageLength: 4);

      // The first call errors.
      expect(
        () => parser(_frame([1, 2, 3, 4, 5])),
        throwsA(isA<RpcException>()),
      );

      // The second parses a good message.
      final result = parser(_frame([7, 8]));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([7, 8])));
    });

    test('an invalid compression flag throws RpcException', () {
      final parser = RpcMessageParser();
      // Compression flag 2 is not allowed.
      final invalid = Uint8List.fromList([2, 0, 0, 0, 1, 0xFF]);

      expect(() => parser(invalid), throwsA(isA<RpcException>()));
    });

    test('the parser recovers after an invalid header', () {
      final parser = RpcMessageParser();
      final invalid = Uint8List.fromList([2, 0, 0, 0, 1, 0xFF]);

      expect(() => parser(invalid), throwsA(isA<RpcException>()));

      final result = parser(_frame([42]));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([42])));
    });
  });

  // -------------------------------------------------------------------------
  // Compression passthrough
  // -------------------------------------------------------------------------
  group('RpcMessageParser - compression', () {
    test(
      'with no decompressor a compressed frame passes through, header and all',
      () {
        final parser = RpcMessageParser(); // no decompressor
        final payload = [1, 2, 3];
        final compressedFrame = _frame(payload, compressed: true);

        final result = parser(compressedFrame);

        expect(result, hasLength(1));
        // The whole gRPC frame comes back, compression flag still set.
        expect(result[0][0], equals(1)); // compression flag = 1
      },
    );

    test('the decompressor runs on a compressed frame', () {
      var decompressorCalled = false;
      final parser = RpcMessageParser(
        decompressor: (data, {int? maxOutputBytes}) {
          decompressorCalled = true;
          return data; // identity
        },
      );
      final compressedFrame = _frame([1, 2, 3], compressed: true);

      parser(compressedFrame);

      expect(decompressorCalled, isTrue);
    });

    test('and not on an uncompressed one', () {
      var decompressorCalled = false;
      final parser = RpcMessageParser(
        decompressor: (data, {int? maxOutputBytes}) {
          decompressorCalled = true;
          return data;
        },
      );

      parser(_frame([1, 2, 3]));

      expect(decompressorCalled, isFalse);
    });

    test('a decompressed result over maxMessageLength throws', () {
      final parser = RpcMessageParser(
        maxMessageLength: 5,
        decompressor: (data, {int? maxOutputBytes}) =>
            Uint8List(10), // inflates to 10 bytes
      );
      final compressedFrame = _frame([1, 2, 3], compressed: true);

      expect(() => parser(compressedFrame), throwsA(isA<RpcException>()));
    });
  });

  // -------------------------------------------------------------------------
  // State isolation: multiple independent parser instances
  // -------------------------------------------------------------------------
  group('RpcMessageParser - state is per-parser', () {
    test('two parsers do not share state', () {
      final p1 = RpcMessageParser();
      final p2 = RpcMessageParser();

      final msg = _frame([1, 2, 3]);
      final half1 = msg.sublist(0, 4);
      final half2 = msg.sublist(4);

      // p1 gets the first half.
      expect(p1(half1), isEmpty);

      // p2 gets a whole message.
      final r2 = p2(msg);
      expect(r2, hasLength(1));

      // p1 gets the second half.
      final r1 = p1(half2);
      expect(r1, hasLength(1));
      expect(r1[0], equals(Uint8List.fromList([1, 2, 3])));
    });
  });
}
