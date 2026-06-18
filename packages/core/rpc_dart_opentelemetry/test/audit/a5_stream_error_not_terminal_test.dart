@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart' show StatusCode;
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test('a non-terminal stream error does not prematurely end the span; '
      'span ends once on completion with full message count', () async {
    final t = buildTracer();
    final interceptor = OtelRpcInterceptor(tracer: t.tracer);
    final call = buildCall();

    // Source emits an item, then a NON-FATAL error, then more items, then done.
    Stream<String> source() async* {
      yield 'a';
      yield* Stream<String>.error(StateError('non-fatal'));
      yield 'b';
      yield 'c';
    }

    final wrapped = await interceptor.interceptServerStream<String, String>(
      call,
      'req',
      (ctx, req) async => source(),
    );

    final received = <String>[];
    Object? sawError;
    final done = Completer<void>();
    wrapped.listen(
      received.add,
      onError: (Object e, StackTrace _) => sawError = e,
      onDone: done.complete,
      cancelOnError: false,
    );
    await done.future;

    // The error propagated downstream but the stream still delivered b and c.
    expect(sawError, isA<StateError>());
    expect(received, equals(['a', 'b', 'c']));

    // Exactly one span exported (ended once on termination, not on first error).
    final spans = t.exporter.spans
        .where((s) => s.name == 'TestService/testMethod')
        .toList();
    expect(
      spans,
      hasLength(1),
      reason: 'Span must end exactly once on termination.',
    );

    final span = spans.single;

    // All three messages counted (the old code stopped counting at the error).
    final msgAttr = span.attributes.get('rpc.stream.messages');
    expect(
      msgAttr,
      equals(3),
      reason:
          'Span must reflect every message, including those after the '
          'non-fatal error.',
    );

    // The non-fatal error was recorded as an exception event on the span.
    expect(
      span.events.any((e) => e.name == 'exception'),
      isTrue,
      reason: 'The non-terminal error must be recorded on the span.',
    );

    // Final status reflects the last seen error (the stream carried an error).
    expect(span.status.code, equals(StatusCode.error));
  });
}
