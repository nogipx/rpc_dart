// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The properties of RpcContext's request/trace tokens, pinned because they were
// touched for SPEED and speed work must not quietly cost a guarantee.
//
// Drawing the random half changed from twelve 8-bit calls to three 32-bit ones
// on the same generator: same 96 bits, same source, fewer syscalls. It was 83%
// of the cost of an RPC --
//
//     endpoint layer round trip : 505 us -> 201 us
//     12 x secure.nextInt(256)  : 130.18 us per token
//      3 x secure.nextInt(2^32) :  33.88 us per token
//
// -- and a unary call spends three tokens.
//
// What must remain true: tokens are unique (a monotonic counter guarantees it
// even where the RNG is weak), url-safe, and fixed-length.

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('tokens are unique across a large batch', () async {
    // The counter occupies the last 4 bytes, so uniqueness does not depend on
    // the RNG at all -- which is the point of having it.
    const count = 50000;
    final seen = <String>{};
    for (var i = 0; i < count; i++) {
      seen.add(RpcContextUtils.generateTraceId());
    }
    expect(seen, hasLength(count));
  });

  test('request ids are unique too, and distinct from trace ids', () async {
    final traces = <String>{};
    final requests = <String>{};
    for (var i = 0; i < 5000; i++) {
      traces.add(RpcContextUtils.generateTraceId());
      requests.add(RpcContext.withHeaders(const {}).requestId);
    }
    expect(traces, hasLength(5000));
    expect(requests, hasLength(5000));
    expect(traces.intersection(requests), isEmpty);
  });

  test('a token is url-safe and fixed length', () async {
    // 16 bytes base64url with padding stripped is always 22 characters. A
    // shorter one would mean fewer bytes were written -- exactly what a wrong
    // rewrite of the draw loop would produce.
    final urlSafe = RegExp(r'^trace_[A-Za-z0-9_-]{22}$');
    for (var i = 0; i < 500; i++) {
      expect(RpcContextUtils.generateTraceId(), matches(urlSafe));
    }
  });

  test('every random byte position actually varies', () async {
    // GUARD against a draw that writes only part of the buffer: collect the
    // decoded bytes and require each of the first 12 positions to take more
    // than one value. A loop that filled 4 bytes and left 8 zeroed would still
    // produce unique, well-formed tokens thanks to the counter.
    final samples = <List<int>>[];
    for (var i = 0; i < 200; i++) {
      final token = RpcContextUtils.generateTraceId().substring(6);
      samples.add(base64Url.decode('$token=='));
    }
    for (var position = 0; position < 12; position++) {
      final values = samples.map((s) => s[position]).toSet();
      expect(
        values.length,
        greaterThan(1),
        reason: 'byte $position never changes, so it is not being written',
      );
    }
  });
}
