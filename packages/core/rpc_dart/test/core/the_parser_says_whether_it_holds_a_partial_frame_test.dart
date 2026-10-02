// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `call` returning no messages means two different things, and anything that waits
// for the rest of a frame has to tell them apart: the parser is holding part of one,
// or it REFUSED what it was given. Every limit here clears the buffer and throws, so
// a refusal leaves nothing held — which is what makes the distinction answerable at
// all, and why it is the parser's to answer rather than an inference from emptiness.
//
// Reading it the other way turns a `maxMessageLengthBytes` refusal into "the request
// was truncated": a security control reporting the wrong thing, and no longer naming
// the limit it enforced.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A complete gRPC frame of [n] body bytes.
Uint8List _frame(int n) =>
    RpcMessageFrame.encode(Uint8List.fromList(List.filled(n, 7)));

void main() {
  test('nothing buffered, nothing held', () {
    final parser = RpcMessageParser();

    expect(parser.holdsPartialFrame, isFalse);
    expect(parser(Uint8List(0)), isEmpty);
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('a whole frame leaves nothing held', () {
    final parser = RpcMessageParser();

    expect(parser(_frame(16)), hasLength(1));
    expect(
      parser.holdsPartialFrame,
      isFalse,
      reason: 'everything was consumed, so no later input is needed',
    );
  });

  test('WITNESS half a frame IS held', () {
    final parser = RpcMessageParser();
    final whole = _frame(16);
    final half = Uint8List.sublistView(whole, 0, whole.length ~/ 2);

    expect(parser(half), isEmpty);
    expect(parser.holdsPartialFrame, isTrue);

    // And the rest completes it, which is what "held" has to mean.
    expect(
      parser(Uint8List.sublistView(whole, whole.length ~/ 2)),
      hasLength(1),
    );
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('WITNESS fewer bytes than a header is also held', () {
    // The other `break` in the parse loop: a header needs five bytes and three
    // arrived. Nothing can be known about the frame yet, and more input is still
    // what resolves it.
    final parser = RpcMessageParser();

    expect(parser(Uint8List.fromList([0, 0, 0])), isEmpty);
    expect(parser.holdsPartialFrame, isTrue);
  });

  test('WITNESS a header whose body has not started is held', () {
    // The header is consumed and nothing is buffered, so a byte count reads
    // zero; the frame is still unfinished, and a stream ending here is cut.
    final parser = RpcMessageParser();
    final whole = _frame(16);

    expect(parser(Uint8List.sublistView(whole, 0, 5)), isEmpty);
    expect(parser.holdsPartialFrame, isTrue);
    expect(parser(Uint8List.sublistView(whole, 5)), hasLength(1));
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('GUARD a header for an empty body is a whole frame', () {
    final parser = RpcMessageParser();

    expect(parser(_frame(0)), hasLength(1));
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('WITNESS a REFUSED frame holds nothing', () {
    // The arm that matters: this also returns no messages, and treating it as
    // incomplete is what round 547 did.
    final parser = RpcMessageParser(maxMessageLength: 16);

    expect(
      () => parser(_frame(64)),
      throwsA(isA<RpcStatusException>()),
      reason: 'the body is past the configured maximum',
    );
    expect(
      parser.holdsPartialFrame,
      isFalse,
      reason:
          'the refusal cleared the buffer, so waiting for more would wait for a '
          'frame the policy has already rejected',
    );
  });

  test('WITNESS a frame refused for OVERFLOW holds nothing either', () {
    // The second refusal path, which fires before the header is even read: the
    // buffer bound is checked against what is about to be appended.
    final parser = RpcMessageParser(maxMessageLength: 64, maxBufferedBytes: 32);

    expect(() => parser(_frame(128)), throwsA(isA<RpcStatusException>()));
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('GUARD a refusal does not poison the parser', () {
    // Clearing is what makes the above true, so the same parser must still work.
    final parser = RpcMessageParser(maxMessageLength: 16);

    expect(() => parser(_frame(64)), throwsA(isA<RpcStatusException>()));
    expect(parser(_frame(8)), hasLength(1));
    expect(parser.holdsPartialFrame, isFalse);
  });

  test('GUARD a trailing partial frame after a whole one is held', () {
    // One chunk, two frames, the second cut short: the first must be emitted AND
    // the remainder held.
    final parser = RpcMessageParser();
    final first = _frame(8);
    final second = _frame(8);
    final chunk = Uint8List(first.length + second.length ~/ 2)
      ..setRange(0, first.length, first)
      ..setRange(
        first.length,
        first.length + second.length ~/ 2,
        Uint8List.sublistView(second, 0, second.length ~/ 2),
      );

    expect(parser(chunk), hasLength(1));
    expect(parser.holdsPartialFrame, isTrue);
  });
}
