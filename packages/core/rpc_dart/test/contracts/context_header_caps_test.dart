// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A context applies no header cap of its own: size is the transport's
// `RpcSecurityPolicy`'s alone, and `validateMetadata` throws on it when the
// call is sent, naming the count, the limit and the field. A cap here would
// drop headers the caller believes it sent, with no error on either side.
// These tests pin that every construction path agrees and none of them
// silently shortens the list.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

int _totalBytes(RpcContext c) => c.headers.entries.fold<int>(
  0,
  (sum, e) => sum + e.key.length + e.value.length,
);

RpcContext _oneByOne(int count, String value) {
  var context = RpcContext.empty();
  for (var i = 0; i < count; i++) {
    context = context.withAdditionalHeaders({'h-$i': value});
  }
  return context;
}

void main() {
  test('incremental adds are not truncated', () {
    expect(
      _oneByOne(500, 'v').headers,
      hasLength(500),
      reason:
          'the context must not apply a ceiling the policy has not been '
          'asked about',
    );
  });

  test('large values are not truncated either', () {
    // 100 * 8000 plus the key bytes: past 64 KiB on purpose.
    expect(_totalBytes(_oneByOne(100, 'x' * 8000)), greaterThan(64 * 1024));
  });

  test('incremental and one-shot agree', () {
    final oneShot = RpcContext.withHeaders({
      for (var i = 0; i < 500; i++) 'h-$i': 'v',
    });

    expect(_oneByOne(500, 'v').headers.length, oneShot.headers.length);
  });

  test('an addition does not displace existing headers', () {
    var context = RpcContext.withHeaders({'keep': 'me'});
    for (var i = 0; i < 500; i++) {
      context = context.withAdditionalHeaders({'h-$i': 'v'});
    }

    // Existing headers are merged first, so an add cannot evict one.
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
