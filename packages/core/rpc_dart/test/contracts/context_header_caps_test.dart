// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcContext caps headers at 128 entries and 64KB total. _sanitizeHeaders
// enforced both, but withAdditionalHeaders applied it to the ADDITIONS only,
// restarting the count and the byte tally at zero on every call. The caps
// therefore bounded a single call rather than the context, and RpcContextBuilder
// adds headers one at a time -- so the ordinary builder path walked straight
// past them:
//
//   one-shot withHeaders(500) -> 128 headers      (cap enforced)
//   500x withHeader()         -> 500 headers      (cap absent)
//   100x 8KB values           -> 800390 bytes     (cap 65536)
//
// The over-cap context did not reach the wire silently -- RpcChannelTransport
// re-validates against RpcSecurityPolicy and throws -- so the symptom was a
// confusing ArgumentError at send time instead of a bounded context at build
// time.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

int _totalBytes(RpcContext c) => c.headers.entries.fold<int>(
  0,
  (sum, e) => sum + e.key.length + e.value.length,
);

void main() {
  test('the count cap survives incremental adds', () {
    var builder = RpcContextBuilder();
    for (var i = 0; i < 500; i++) {
      builder = builder.withHeader('h-$i', 'v');
    }

    expect(builder.build().headers, hasLength(128));
  });

  test('the byte cap survives incremental adds', () {
    var builder = RpcContextBuilder();
    for (var i = 0; i < 100; i++) {
      builder = builder.withHeader('h-$i', 'x' * 8000);
    }

    expect(_totalBytes(builder.build()), lessThanOrEqualTo(64 * 1024));
  });

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

  test('merging two capped contexts stays capped', () {
    final left = RpcContext.withHeaders({
      for (var i = 0; i < 128; i++) 'l-$i': 'v',
    });
    final right = RpcContext.withHeaders({
      for (var i = 0; i < 128; i++) 'r-$i': 'v',
    });

    // Each side is individually within budget; their union is not.
    expect(RpcContextUtils.merge(left, right).headers, hasLength(128));
  });

  test('an over-cap addition does not displace existing headers', () {
    var context = RpcContext.withHeaders({'keep': 'me'});
    for (var i = 0; i < 500; i++) {
      context = context.withAdditionalHeaders({'h-$i': 'v'});
    }

    expect(context.getHeader('keep'), 'me');
    expect(context.headers, hasLength(128));
  });

  test('adds still override and still normalise', () {
    // The cap change must not disturb ordinary merge semantics.
    final context = RpcContext.withHeaders({
      'a': '1',
    }).withAdditionalHeaders({'B': '2'}).withAdditionalHeaders({'a': '3'});

    expect(context.getHeader('a'), '3');
    expect(context.getHeader('b'), '2');
    expect(context.headers, hasLength(2));
  });
}
