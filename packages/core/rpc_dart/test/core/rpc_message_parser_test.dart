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
  group('RpcMessageParser — базовая корректность', () {
    test('одно сообщение в одном чанке', () {
      final parser = RpcMessageParser();
      final payload = [1, 2, 3, 4, 5];
      final chunk = _frame(payload);

      final result = parser(chunk);

      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('пустое сообщение (нулевая длина)', () {
      final parser = RpcMessageParser();
      final chunk = _frame([]);

      final result = parser(chunk);

      expect(result, hasLength(1));
      expect(result[0], isEmpty);
    });

    test('пустой чанк возвращает пустой список', () {
      final parser = RpcMessageParser();

      final result = parser(Uint8List(0));

      expect(result, isEmpty);
    });

    test('чанк только из заголовка без тела — ждёт следующий чанк', () {
      final parser = RpcMessageParser();
      final full = _frame([10, 20, 30]);
      // Отправляем только 5-байтовый заголовок
      final headerOnly = full.sublist(0, 5);
      final body = full.sublist(5);

      expect(parser(headerOnly), isEmpty);
      final result = parser(body);
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([10, 20, 30])));
    });

    test('неполный заголовок (< 5 байт) — ждёт следующий чанк', () {
      final parser = RpcMessageParser();
      final full = _frame([42]);

      // Отправляем по 1 байту
      for (var i = 0; i < 4; i++) {
        expect(parser(full.sublist(i, i + 1)), isEmpty);
      }
      // Последний байт заголовка + тело
      final result = parser(full.sublist(4));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([42])));
    });

    test('данные сохраняются между вызовами (частичное тело)', () {
      final parser = RpcMessageParser();
      final payload = List.generate(100, (i) => i);
      final full = _frame(payload); // 105 bytes

      // Отправляем по 10 байт за раз, последний чанк — остаток
      const chunkSize = 10;
      List<Uint8List>? lastResult;
      for (var i = 0; i < full.length; i += chunkSize) {
        final end = (i + chunkSize < full.length) ? i + chunkSize : full.length;
        final chunk = full.sublist(i, end);
        lastResult = parser(chunk);
        if (end < full.length) {
          expect(lastResult, isEmpty, reason: 'ещё не все данные получены');
        }
      }
      expect(lastResult, hasLength(1));
      expect(lastResult![0], equals(Uint8List.fromList(payload)));
    });
  });

  // -------------------------------------------------------------------------
  // Fragmentation: one message split across multiple chunks
  // -------------------------------------------------------------------------
  group('RpcMessageParser — фрагментация', () {
    test('сообщение разбито ровно на 2 чанка по границе заголовка', () {
      final parser = RpcMessageParser();
      final payload = [0xAA, 0xBB, 0xCC];
      final full = _frame(payload);
      // Разбиваем ровно после 5-байтового заголовка
      final part1 = full.sublist(0, 5);
      final part2 = full.sublist(5);

      expect(parser(part1), isEmpty);
      final result = parser(part2);
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('сообщение разбито по середине тела', () {
      final parser = RpcMessageParser();
      final payload = List.generate(20, (i) => i * 2);
      final full = _frame(payload);
      final mid = full.length ~/ 2;

      expect(parser(full.sublist(0, mid)), isEmpty);
      final result = parser(full.sublist(mid));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('сообщение разбито на N однобайтовых чанков', () {
      final parser = RpcMessageParser();
      final payload = [1, 2, 3];
      final full = _frame(payload);

      for (var i = 0; i < full.length - 1; i++) {
        expect(parser(full.sublist(i, i + 1)), isEmpty,
            reason: 'должен ждать после байта $i');
      }
      final result = parser(full.sublist(full.length - 1));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList(payload)));
    });

    test('два сообщения, каждое фрагментировано', () {
      final parser = RpcMessageParser();
      final msg1 = _frame([1, 2, 3]);
      final msg2 = _frame([4, 5, 6]);
      // Общий поток: первая половина msg1 | вторая половина msg1 + вся msg2
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
  group('RpcMessageParser — батчинг нескольких сообщений в одном чанке', () {
    test('2 сообщения в одном чанке', () {
      final parser = RpcMessageParser();
      final chunk = _concat([
        _frame([1, 2]),
        _frame([3, 4])
      ]);

      final result = parser(chunk);

      expect(result, hasLength(2));
      expect(result[0], equals(Uint8List.fromList([1, 2])));
      expect(result[1], equals(Uint8List.fromList([3, 4])));
    });

    test('10 сообщений в одном чанке', () {
      final parser = RpcMessageParser();
      final messages = List.generate(10, (i) => [i, i + 1, i + 2]);
      final chunk = _concat(messages.map((m) => _frame(m)).toList());

      final result = parser(chunk);

      expect(result, hasLength(10));
      for (var i = 0; i < 10; i++) {
        expect(result[i], equals(Uint8List.fromList(messages[i])));
      }
    });

    test('1000 сообщений в одном чанке (регрессия O(N²))', () {
      final parser = RpcMessageParser(maxMessagesPerChunk: 2000);
      final payload = [0xDE, 0xAD];
      final chunk = _concat(List.generate(1000, (_) => _frame(payload)));

      final result = parser(chunk);

      expect(result, hasLength(1000));
      for (final msg in result) {
        expect(msg, equals(Uint8List.fromList(payload)));
      }
    });

    test('после батча буфер очищен — следующее сообщение парсится верно', () {
      final parser = RpcMessageParser();
      final batch = _concat([
        _frame([1]),
        _frame([2]),
        _frame([3])
      ]);
      final next = _frame([99]);

      final r1 = parser(batch);
      final r2 = parser(next);

      expect(r1, hasLength(3));
      expect(r2, hasLength(1));
      expect(r2[0], equals(Uint8List.fromList([99])));
    });

    test('батч + хвостовой фрагмент следующего сообщения', () {
      final parser = RpcMessageParser();
      final msg1 = _frame([1, 2]);
      final msg2 = _frame([3, 4]);
      final msg3 = _frame([5, 6]);
      // Отправляем msg1 + msg2 целиком, и только заголовок msg3
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
  group('RpcMessageParser — лимиты и обработка ошибок', () {
    test('превышение maxMessageLength бросает RpcException', () {
      final parser = RpcMessageParser(maxMessageLength: 4);
      final chunk = _frame([1, 2, 3, 4, 5]); // 5 байт > 4

      expect(() => parser(chunk), throwsA(isA<RpcException>()));
    });

    test('превышение maxBufferedBytes бросает RpcException', () {
      final parser = RpcMessageParser(
        maxMessageLength: 100,
        maxBufferedBytes: 10,
      );
      // Отправляем незаконченный фрейм размером 20 байт
      final partial = Uint8List(20);

      expect(() => parser(partial), throwsA(isA<RpcException>()));
    });

    test('превышение maxMessagesPerChunk бросает RpcException', () {
      final parser = RpcMessageParser(maxMessagesPerChunk: 2);
      // 3 сообщения — на третьем должно бросить
      final chunk = _concat([
        _frame([1]),
        _frame([2]),
        _frame([3])
      ]);

      expect(() => parser(chunk), throwsA(isA<RpcException>()));
    });

    test('после ошибки maxMessageLength парсер снова работает', () {
      final parser = RpcMessageParser(maxMessageLength: 4);

      // Первый вызов — ошибка
      expect(
        () => parser(_frame([1, 2, 3, 4, 5])),
        throwsA(isA<RpcException>()),
      );

      // Второй вызов — корректное сообщение
      final result = parser(_frame([7, 8]));
      expect(result, hasLength(1));
      expect(result[0], equals(Uint8List.fromList([7, 8])));
    });

    test('невалидный compression flag бросает RpcException', () {
      final parser = RpcMessageParser();
      // Compression flag = 2 — недопустимо
      final invalid = Uint8List.fromList([2, 0, 0, 0, 1, 0xFF]);

      expect(() => parser(invalid), throwsA(isA<RpcException>()));
    });

    test('после невалидного заголовка парсер снова работает', () {
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
  group('RpcMessageParser — сжатие', () {
    test('сжатый фрейм без декомпрессора передаётся как есть (с заголовком)',
        () {
      final parser = RpcMessageParser(); // без decompressor
      final payload = [1, 2, 3];
      final compressedFrame = _frame(payload, compressed: true);

      final result = parser(compressedFrame);

      expect(result, hasLength(1));
      // Должен вернуть полный gRPC-фрейм с выставленным флагом сжатия
      expect(result[0][0], equals(1)); // compression flag = 1
    });

    test('декомпрессор вызывается для сжатого фрейма', () {
      var decompressorCalled = false;
      final parser = RpcMessageParser(
        decompressor: (data) {
          decompressorCalled = true;
          return data; // identity
        },
      );
      final compressedFrame = _frame([1, 2, 3], compressed: true);

      parser(compressedFrame);

      expect(decompressorCalled, isTrue);
    });

    test('декомпрессор не вызывается для несжатого фрейма', () {
      var decompressorCalled = false;
      final parser = RpcMessageParser(
        decompressor: (data) {
          decompressorCalled = true;
          return data;
        },
      );

      parser(_frame([1, 2, 3]));

      expect(decompressorCalled, isFalse);
    });

    test('результат декомпрессии превышает maxMessageLength — бросает', () {
      final parser = RpcMessageParser(
        maxMessageLength: 5,
        decompressor: (data) => Uint8List(10), // раздувает до 10 байт
      );
      final compressedFrame = _frame([1, 2, 3], compressed: true);

      expect(() => parser(compressedFrame), throwsA(isA<RpcException>()));
    });
  });

  // -------------------------------------------------------------------------
  // State isolation: multiple independent parser instances
  // -------------------------------------------------------------------------
  group('RpcMessageParser — изоляция состояния', () {
    test('два парсера независимы', () {
      final p1 = RpcMessageParser();
      final p2 = RpcMessageParser();

      final msg = _frame([1, 2, 3]);
      final half1 = msg.sublist(0, 4);
      final half2 = msg.sublist(4);

      // p1 получает первую половину
      expect(p1(half1), isEmpty);

      // p2 получает полное сообщение
      final r2 = p2(msg);
      expect(r2, hasLength(1));

      // p1 получает вторую половину
      final r1 = p1(half2);
      expect(r1, hasLength(1));
      expect(r1[0], equals(Uint8List.fromList([1, 2, 3])));
    });
  });
}
