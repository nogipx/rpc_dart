// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The header-block guard bounds what reaches HPACK at maxMetadataBytes (64 KiB).
// HPACK then DECOMPRESSES, and its output is a List<Header> of REFERENCES: an
// indexed-header flood is thousands of pointers to one shared dynamic-table
// entry, so package:http2 itself pays almost nothing for it.
//
// rpc_dart's converter did. `String.fromCharCodes` per header turned every
// shared reference into its own String, and it ran one line BEFORE
// `_policy.validateMetadata`, so maxHeaders (128) could only refuse a copy that
// had already been made. Measured with a real HPACK block, one request:
//
//   63 KiB on the wire -> 60001 headers
//     HPACK decode      RSS +7 MiB     (distinct objects: 1)
//     the conversion    RSS +258 MiB   <- ~4100x, before any limit ran
//   after               RSS +0 MiB, refused
//
// The flood below is built the way the decoder hands it over -- N references to
// ONE Header -- which is what makes the copy, not the decode, the cost.

import 'dart:collection';

import 'package:http2/transport.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';
import 'package:test/test.dart';

/// A byte list that counts how many times it is READ, so the test can measure
/// materialisation directly instead of inferring it from memory.
final class _CountingBytes extends ListBase<int> {
  _CountingBytes(this._length, this._onRead);

  final int _length;
  final void Function() _onRead;

  @override
  int get length => _length;

  @override
  int operator [](int index) {
    // Counted at index 0, i.e. once per VALUE copied — the question is how many
    // values were materialised, not how many bytes each one cost.
    if (index == 0) _onRead();
    return 0x62;
  }

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('read-only');

  @override
  set length(int value) => throw UnsupportedError('fixed');
}

/// One shared entry, referenced [n] times — an HPACK indexed-header flood as
/// the decoder returns it.
List<http2.Header> _flood(int n, {int valueBytes = 4000}) {
  final shared = http2.Header(
    List<int>.filled(8, 0x61),
    List<int>.filled(valueBytes, 0x62),
  );
  return List<http2.Header>.filled(n, shared);
}

void main() {
  group('WITNESS: an indexed-header flood is refused before it is copied', () {
    test('60001 shared references do not become 60001 Strings', () {
      final headers = _flood(60001);

      expect(
        () => http2HeadersToRpcMetadata(
          headers,
          methodPath: '/S/M',
          policy: const RpcSecurityPolicy(),
        ),
        throwsArgumentError,
        reason:
            'the conversion copied every reference into its own String and only '
            'then let validateMetadata refuse the result',
      );
    });

    test('it stops reading values at the limit instead of at the end', () {
      // COUNTS THE COPIES rather than watching RSS. Two earlier versions used
      // ProcessInfo.currentRss and both PASSED with the fix removed -- first
      // because the 240 MiB was garbage before the sample, then because the
      // runner's RSS simply did not move for it. C-29 records the same trap:
      // expose a counter, do not infer allocation from memory.
      //
      // String.fromCharCodes iterates the value, so a list that counts its own
      // reads measures exactly what the fix is about: how many values were
      // materialised before the refusal.
      var reads = 0;
      final shared = http2.Header(
        List<int>.filled(8, 0x61),
        _CountingBytes(4000, () => reads++),
      );
      final headers = List<http2.Header>.filled(60001, shared);

      // Deliberately NOT wrapped in expectLater/throwsA: the count below has to
      // be the assertion that fires, not a line that never runs because an
      // earlier expectation already failed.
      try {
        http2HeadersToRpcMetadata(headers, policy: const RpcSecurityPolicy());
      } catch (_) {
        // The refusal is asserted by the test above; here only its COST is.
      }

      expect(
        reads,
        lessThanOrEqualTo(const RpcSecurityPolicy().maxHeaders),
        reason:
            '$reads header values were copied out of 60001 before the policy '
            'refused the request it was always going to refuse',
      );
    });
  });

  group('GUARD: the accepted set is unchanged', () {
    test('exactly maxHeaders is still accepted, one more is not', () {
      const policy = RpcSecurityPolicy();

      final atLimit = _flood(policy.maxHeaders, valueBytes: 4);
      expect(
        http2HeadersToRpcMetadata(atLimit, policy: policy).headers,
        hasLength(policy.maxHeaders),
        reason: 'the boundary must be where validateMetadata always had it',
      );

      final overLimit = _flood(policy.maxHeaders + 1, valueBytes: 4);
      expect(
        () => http2HeadersToRpcMetadata(overLimit, policy: policy),
        throwsArgumentError,
      );
    });

    test('pseudo-headers do not count against the limit', () {
      // They are filtered out, so a request with the full complement of real
      // headers plus :method/:path/:scheme/:authority must still pass.
      const policy = RpcSecurityPolicy();
      final headers = <http2.Header>[
        http2.Header.ascii(':method', 'POST'),
        http2.Header.ascii(':path', '/S/M'),
        http2.Header.ascii(':scheme', 'http'),
        http2.Header.ascii(':authority', 'localhost'),
        ..._flood(policy.maxHeaders, valueBytes: 4),
      ];

      expect(
        http2HeadersToRpcMetadata(headers, policy: policy).headers,
        hasLength(policy.maxHeaders),
      );
    });

    test('with no policy the conversion is unchanged', () {
      // Every other caller of this function passes none, and must keep the
      // previous behaviour rather than inheriting a limit by surprise.
      final headers = _flood(500, valueBytes: 4);
      expect(http2HeadersToRpcMetadata(headers).headers, hasLength(500));
    });

    test('an ordinary request still converts', () {
      final headers = <http2.Header>[
        http2.Header.ascii(':path', '/Svc/Method'),
        http2.Header.ascii('content-type', 'application/grpc'),
        http2.Header.ascii('x-trace', 'abc'),
      ];
      final md = http2HeadersToRpcMetadata(
        headers,
        methodPath: '/Svc/Method',
        policy: const RpcSecurityPolicy(),
      );
      expect(md.headers, hasLength(2));
      expect(md.methodPath, '/Svc/Method');
    });
  });
}
