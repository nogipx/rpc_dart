// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Where a context's header caps live, and that no path quietly applies one of
// its own.
//
// `f876d602` made RpcContext's private caps -- 128 entries, 64 KiB -- effective
// across `withAdditionalHeaders`, the builder and `merge`, because each had
// been restarting the tally and walking past them. It chose truncating at build
// time over the send-time symptom, which it described as "a confusing
// ArgumentError".
//
// Round 446 reversed the CAP and kept the reach. The caps were numerically
// equal to `RpcSecurityPolicy`'s defaults and reachable from no policy, so
// raising `maxHeaders` to 512 still truncated at 128 and the extra headers went
// missing with no error on either side -- the caller believed it had sent them.
// And the reason for preferring build time was re-measured: the send-time error
// is now `RpcMetadataViolation: Too many metadata headers: 205 > 128`, which
// names the count, the limit and the field, and carries INVALID_ARGUMENT
// instead of being redacted.
//
// So size is the policy's alone. What these tests pin is that every path agrees
// and none of them silently shortens the list.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

int _totalBytes(RpcContext c) => c.headers.entries.fold<int>(
  0,
  (sum, e) => sum + e.key.length + e.value.length,
);

void main() {
  test('incremental adds are not truncated', () {
    var builder = RpcContextBuilder();
    for (var i = 0; i < 500; i++) {
      builder = builder.withHeader('h-$i', 'v');
    }

    expect(
      builder.build().headers,
      hasLength(500),
      reason:
          'the builder must not apply a ceiling the policy has not been '
          'asked about',
    );
  });

  test('large values are not truncated either', () {
    var builder = RpcContextBuilder();
    for (var i = 0; i < 100; i++) {
      builder = builder.withHeader('h-$i', 'x' * 8000);
    }

    // 100 * 8000 plus the key bytes: past the old 64 KiB cap on purpose.
    expect(_totalBytes(builder.build()), greaterThan(64 * 1024));
  });

  // f876d602's own third assertion, and the one that still carries its point:
  // the two construction paths must not disagree, whichever way they behave.
  test('incremental and one-shot agree', () {
    final oneShot = RpcContext.withHeaders({
      for (var i = 0; i < 500; i++) 'h-$i': 'v',
    });

    var builder = RpcContextBuilder();
    for (var i = 0; i < 500; i++) {
      builder = builder.withHeader('h-$i', 'v');
    }

    expect(builder.build().headers.length, oneShot.headers.length);
  });

  test('merging two contexts keeps the union', () {
    final left = RpcContext.withHeaders({
      for (var i = 0; i < 128; i++) 'l-$i': 'v',
    });
    final right = RpcContext.withHeaders({
      for (var i = 0; i < 128; i++) 'r-$i': 'v',
    });

    expect(RpcContextUtils.merge(left, right).headers, hasLength(256));
  });

  test('an addition does not displace existing headers', () {
    var context = RpcContext.withHeaders({'keep': 'me'});
    for (var i = 0; i < 500; i++) {
      context = context.withAdditionalHeaders({'h-$i': 'v'});
    }

    // The displacement half of f876d602 is unchanged and still worth pinning:
    // existing headers are merged first, so an add cannot evict one.
    expect(context.getHeader('keep'), 'me');
    expect(context.headers, hasLength(501));
  });

  test('adds still override and still normalise', () {
    final context = RpcContext.withHeaders({
      'a': '1',
    }).withAdditionalHeaders({'B': '2'}).withAdditionalHeaders({'a': '3'});

    expect(context.getHeader('a'), '3');
    expect(context.getHeader('b'), '2');
    expect(context.headers, hasLength(2));
  });
}
