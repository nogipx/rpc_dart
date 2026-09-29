// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `validateMetadata` bounded each header and never the sum, so many individually
// legal headers passed: at the defaults, 64 headers of 8 KiB is 8x
// `maxMetadataBytes`. The only thing that stopped a peer was `maxHeaders`, making
// the effective ceiling `maxHeaders * maxHeaderValueBytes` — about 1 MiB, 16x the
// value an operator set to bound exactly this.
//
// Every header below is individually LEGAL. That is the point: one oversized header
// would make a refusal say nothing about totals.
//
// The measurements are in `.claude/loop/rounds/523`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _policy = RpcSecurityPolicy();

RpcMetadata _pad(int count, int valueLen) => RpcMetadata([
  for (var i = 0; i < count; i++) RpcHeader('x-pad-$i', 'a' * valueLen),
]);

void main() {
  test('WITNESS: legal headers are bounded in TOTAL', () {
    // 8 x 8192 B just crosses the 64 KiB metadata limit.
    expect(
      () => _policy.validateMetadata(_pad(8, _policy.maxHeaderValueBytes)),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Metadata too large'),
        ),
      ),
      reason:
          'each header is legal, and nothing summed them — so the real ceiling '
          'was maxHeaders x maxHeaderValueBytes, 16x the configured limit',
    );

    expect(
      () => _policy.validateMetadata(_pad(64, _policy.maxHeaderValueBytes)),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('GUARD: what must still be accepted or refused for its own reason', () {
    test('metadata within the limit still passes', () {
      // Without this, a check that refused everything would pass the witness.
      expect(
        () => _policy.validateMetadata(_pad(1, _policy.maxHeaderValueBytes)),
        returnsNormally,
      );
      expect(
        () => _policy.validateMetadata(
          RpcMetadata.forClientRequest('Svc', 'method'),
        ),
        returnsNormally,
      );
    });

    test('an oversized single header is still refused per-header', () {
      expect(
        () => _policy.validateMetadata(
          RpcMetadata([
            RpcHeader('x-big', 'a' * (_policy.maxHeaderValueBytes + 1)),
          ]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Invalid metadata header value'),
          ),
        ),
      );
    });

    test('too many headers is still refused by COUNT, before size', () {
      // The count check runs first and must keep its own message: a peer sending
      // many tiny headers is a different fault from one sending too many bytes.
      expect(
        () => _policy.validateMetadata(_pad(_policy.maxHeaders + 1, 1)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Too many metadata headers'),
          ),
        ),
      );
    });

    test('a larger configured limit admits correspondingly more', () {
      // The bound must follow the FIELD, not a constant.
      const roomy = RpcSecurityPolicy(maxMetadataBytes: 1024 * 1024);
      expect(
        () => roomy.validateMetadata(_pad(64, roomy.maxHeaderValueBytes)),
        returnsNormally,
      );
    });
  });
}
