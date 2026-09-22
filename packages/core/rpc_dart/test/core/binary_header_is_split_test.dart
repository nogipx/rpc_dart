// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-09 item 1, the half that is a spec MUST.
//
// PROTOCOL-HTTP2: "Implementations must split Binary-Headers on ',' before
// decoding the Base64-encoded values."
//
// A comma is in neither base64 alphabet, so an unsplit value cannot decode:
// `base64.normalize('AAA,BBB')` throws, the catch in `statusDetailsBin` returns
// null, and the structured details of an error vanish. Silently — the status
// and message still arrive, so nothing looks wrong.
//
// Reachable through any intermediary that combines duplicate header lines with
// a bare comma, which RFC 9110 s5.3 permits and gRPC's own text describes.
// `unpadded_status_details_test.dart` is the sibling case: the same silent
// disappearance, arriving through padding instead of through a comma.

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Metadata carrying [raw] as the binary status-details header, verbatim.
RpcMetadata _withDetails(String raw) => RpcMetadata([
  RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.notFound}'),
  RpcHeader(RpcHeaders.grpcStatusDetails, raw),
]);

void main() {
  final details = Uint8List.fromList(const [8, 5, 18, 3, 97, 98, 99]);
  final encoded = base64Encode(details);

  test('WITNESS: a comma-joined binary header still decodes', () {
    // What a combining intermediary produces from two `grpc-status-details-bin`
    // lines. The first value is the one this call's status refers to.
    final joined = '$encoded,${base64Encode(const [1, 2, 3])}';

    expect(
      _withDetails(joined).statusDetailsBin,
      details,
      reason:
          'unsplit, base64 cannot decode a value containing a comma, so the '
          'details are dropped and the error arrives with its structure gone',
    );
  });

  test('WITNESS: the spec delimiter is a bare comma, not comma-space', () {
    // RFC 9110 only RECOMMENDS comma-SP; gRPC names ','. Both must work.
    expect(_withDetails('$encoded, $encoded').statusDetailsBin, details);
    expect(_withDetails('$encoded,$encoded').statusDetailsBin, details);
  });

  // GUARD: splitting must not disturb the ordinary single value, padded or not.
  test('GUARD: a single value still decodes, padded and unpadded', () {
    expect(_withDetails(encoded).statusDetailsBin, details);
    expect(
      _withDetails(encoded.replaceAll('=', '')).statusDetailsBin,
      details,
      reason:
          'grpc-go strips padding; round 285 made that work and it must '
          'keep working',
    );
  });

  // GUARD: input that is not base64 at all is still "absent", not a throw.
  // The status itself is usable, and failing the call over the details would
  // be worse than losing them.
  test('GUARD: genuinely malformed details are still treated as absent', () {
    expect(_withDetails('not base64 at all!!').statusDetailsBin, isNull);
    expect(_withDetails(',,,').statusDetailsBin, isNull);
  });
}
