@TestOn('vm || chrome')
library;

// SPDX-License-Identifier: MIT
//
// Runs on vm and chrome (the real web target) but not node: the audit suite
// builds a real opentelemetry SDK tracer whose IdGenerator calls
// Random.secure(), which is unavailable under the node test platform.
//
// AUDIT A5: _wrapWithSpan ended the span on the FIRST onError event even though
// the source is listened with cancelOnError:false (so an onError is NOT
// terminal). otel_rpc_interceptor.dart / otel_rpc_client_interceptor.dart.
//
// A server/bidi stream can emit a non-fatal item error and then keep going /
// complete normally. With the bug the span was force-ended + marked errored on
// the first error, and the later real completion was dropped (finished==true).
//
// CORRECT: the span ends on TERMINATION (onDone), exactly once. A non-terminal
// error is recorded but does not close the span; if the stream then completes
// without a trailing error the span carries the full message count.

import 'dart:async';

import 'package:opentelemetry/api.dart' show StatusCode;
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

void main() {
  test(
      'a non-terminal stream error does not prematurely end the span; '
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
    ) as Stream<String>;

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
    expect(spans, hasLength(1),
        reason: 'Span must end exactly once on termination.');

    final span = spans.single;

    // All three messages counted (the old code stopped counting at the error).
    final msgAttr = span.attributes.get('rpc.stream.messages');
    expect(msgAttr, equals(3),
        reason: 'Span must reflect every message, including those after the '
            'non-fatal error.');

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
