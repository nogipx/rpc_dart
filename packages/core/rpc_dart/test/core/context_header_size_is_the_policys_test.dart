// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcContext` held four private header limits -- count 128, name 128, value
// 8 KiB, total 64 KiB -- numerically EQUAL to `RpcSecurityPolicy`'s defaults
// and reachable from no policy. So raising `maxHeaders` to 512 still truncated
// at 128, and `_sanitizeHeaders` did it with `continue` and `break`: no error,
// no log, nothing on either side. The caller believed it sent what it had not.
//
// The equality is what hid it: the two agreeing on the default is exactly why
// nobody noticed one of them could not be reached.
//
// Size now belongs to the policy alone, which THROWS on it. What the context
// still drops is structural -- a key that is empty, pseudo-header, off-pattern
// or carrying CR/LF/NUL is not a header at any size.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Counts the `x-h*` headers the handler was given.
final class _CountingContract extends RpcResponderContract {
  _CountingContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Count',
      handler: (request, {RpcContext? context}) async {
        final headers = context?.headers ?? const <String, String>{};
        return '${headers.keys.where((k) => k.startsWith('x-h')).length}'.rpc;
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

/// Drives one unary call under [policy] with [count] `x-h*` headers and
/// returns what the HANDLER saw. Throws whatever the call throws.
Future<int> _headersReaching(RpcSecurityPolicy policy, int count) async {
  final (clientTransport, serverTransport) = RpcChannelTransport.pair(
    policy: policy,
  );
  final caller = RpcCallerEndpoint(transport: clientTransport);
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(_CountingContract());
  responder.start();

  try {
    final result = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Count',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: 'x'.rpc,
      context: RpcContext.withHeaders({
        for (var i = 0; i < count; i++) 'x-h$i': 'v$i',
      }),
    );
    return int.parse(result.value);
  } finally {
    await caller.close();
    await responder.close();
  }
}

void main() {
  group('a context carries what the policy admits, not its own copy of 128', () {
    // WITNESS. With the limit raised on both sides all 200 must arrive. Before
    // the fix the handler saw 127: the context had truncated to its own 128
    // and the policy, which admits 512, never got to see the rest.
    test('raising maxHeaders past 128 actually raises it', () async {
      final seen = await _headersReaching(
        const RpcSecurityPolicy(maxHeaders: 512, maxMetadataBytes: 512 * 1024),
        200,
      );

      expect(
        seen,
        200,
        reason:
            'the policy admits 512 and the caller set 200, so all 200 must '
            'reach the handler; a smaller number means something below the '
            'policy is still applying a ceiling of its own',
      );
    });

    // CONTRACT GUARD, and deliberately not called a witness: it passes with
    // the old ceiling restored too, because 128 kept headers PLUS the system
    // ones still exceed 128, so it raises there for a different reason. What it
    // pins is that going over is loud, whichever layer says so.
    test('past the policy ceiling the caller is refused, not truncated', () {
      expect(
        () => _headersReaching(const RpcSecurityPolicy(), 200),
        throwsA(isA<RpcMetadataViolation>()),
        reason: '200 headers against the default 128 must raise, not truncate',
      );
    });

    // CONTROL. Under the ceiling the same path succeeds, so the refusal above
    // is about the COUNT and not "a default policy refuses contexts at all".
    test(
      'CONTROL: under the ceiling the same path carries every header',
      () async {
        expect(await _headersReaching(const RpcSecurityPolicy(), 10), 10);
      },
    );
  });

  group('structural sanitisation stays, and bounds nothing', () {
    test('what is not a header at any size is still dropped', () {
      // The control character is built in code: a literal or an escape is what
      // the analyzer and the formatter disagree about, and it hides the intent.
      final crlf = String.fromCharCode(0x0D) + String.fromCharCode(0x0A);

      final ctx = RpcContext.withHeaders({
        '': 'empty key',
        ':authority': 'pseudo-header',
        'Has Spaces': 'off-pattern',
        'x-inject': 'value$crlf-injected',
        'x-kept': 'plain',
      });

      expect(
        ctx.headers.keys,
        ['x-kept'],
        reason: 'only the structural drops should have happened: $ctx',
      );
    });

    // PAIRED with the above, per the rule that every "this input is rejected"
    // needs a "a valid input is not": a long name and a long value are SIZE,
    // so the context no longer touches them.
    test('a name and a value past the old private ceilings are kept', () {
      final ctx = RpcContext.withHeaders({
        'x-${'n' * 200}': 'v',
        'x-big': 'v' * (16 * 1024),
      });

      expect(ctx.headers.length, 2);
      expect(ctx.headers['x-big']!.length, 16 * 1024);
    });
  });
}
