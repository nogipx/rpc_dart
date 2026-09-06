// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// gRPC carries binary metadata as base64 under a `-bin` suffix, and the spec
// requires implementations to accept values both WITH and WITHOUT padding.
// grpc-go strips it.
//
// Observed directly rather than read: grpcurl was given
// `-H 'x-token-bin: aGVsbG8gd29ybGQ='` and the header that reached the handler
// was `aGVsbG8gd29ybGQ`, the `=` gone.
//
// `RpcMetadata.statusDetailsBin` decoded with a bare `base64Decode`, which is
// strict about padding, and its catch turned the throw into "absent". So the
// structured details of every error reported by a grpc-go server were dropped
// in silence -- the status and message survived, RpcBadRequest and RpcRetryInfo
// did not.
//
//     statusDetailsBin(padded)   -> hello world
//     statusDetailsBin(unpadded) -> NULL, dropped

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

RpcMetadata _withDetails(String value) => RpcMetadata([
  RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.invalidArgument}'),
  RpcHeader(RpcHeaders.grpcStatusDetails, value),
]);

void main() {
  final padded = base64.encode(utf8.encode('hello world'));
  final unpadded = padded.replaceAll('=', '');

  test('unpadded status details are decoded, as a real peer sends them', () {
    expect(
      padded,
      endsWith('='),
      reason: 'the fixture must actually be padded',
    );
    expect(unpadded, isNot(endsWith('=')));

    final decoded = _withDetails(unpadded).statusDetailsBin;
    expect(decoded, isNotNull);
    expect(utf8.decode(decoded!), 'hello world');
  });

  test('GUARD: padded details still decode', () {
    final decoded = _withDetails(padded).statusDetailsBin;
    expect(utf8.decode(decoded!), 'hello world');
  });

  test('GUARD: input that is not base64 is still treated as absent', () {
    // The catch is load-bearing: a malformed header must not fail the call,
    // because the status itself is still usable.
    expect(_withDetails('not base64 at all!!').statusDetailsBin, isNull);
  });

  test('GUARD: an absent header stays absent', () {
    final metadata = RpcMetadata([
      RpcHeader(RpcHeaders.grpcStatus, '${RpcStatus.ok}'),
    ]);
    expect(metadata.statusDetailsBin, isNull);
  });

  test('a real error payload survives the unpadded round trip', () {
    // The case that matters in practice: structured details, not a toy string.
    // base64 only pads when the byte length is not a multiple of three, so the
    // description is grown until the encoding actually HAS padding. Picked by
    // construction rather than by luck: the first fixture tried happened to
    // encode without padding, so the case passed under the canary and proved
    // nothing.
    Uint8List? details;
    String encoded = '';
    for (var extra = 0; extra < 3; extra++) {
      details = RpcStatusException(
        RpcStatus.invalidArgument,
        'bad field',
        details: [
          RpcBadRequest([
            RpcFieldViolation(
              field: 'name',
              description: 'must not be empty${'!' * extra}',
            ),
          ]),
        ],
      ).statusDetailsBin;
      encoded = base64.encode(details!);
      if (encoded.endsWith('=')) break;
    }
    // Load-bearing: base64 only pads when the input length is not a multiple of
    // three, so without this check the case can pass with nothing stripped --
    // which it did on the first attempt, staying green under the canary.
    expect(
      encoded,
      endsWith('='),
      reason: 'this fixture must actually be padded, or it tests nothing',
    );

    final wire = encoded.replaceAll('=', '');
    final decoded = _withDetails(wire).statusDetailsBin;

    expect(decoded, isNotNull);
    expect(decoded, details, reason: 'the bytes must survive intact');
  });
}
