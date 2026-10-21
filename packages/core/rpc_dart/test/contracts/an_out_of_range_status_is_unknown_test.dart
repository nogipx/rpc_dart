// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer's grpc-status outside 0..16 reads as UNKNOWN, as a non-numeric one
// does: a caller branches on the status, and a peer's 99 or -1 matches nothing
// it knows.

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

RpcStatus? _status(String raw) => RpcCallerTrailer.statusOf(
  RpcMetadata([RpcHeader(RpcHeaders.grpcStatus, raw)]),
);

void main() {
  test('WITNESS a code outside 0..16 is UNKNOWN', () {
    expect(_status('99'), RpcStatus.unknown);
    expect(_status('-1'), RpcStatus.unknown);
    expect(_status('17'), RpcStatus.unknown);
  });

  test('GUARD every code in 0..16 is kept', () {
    for (final status in RpcStatus.values) {
      expect(_status('${status.code}'), status);
    }
    expect(_status('x'), RpcStatus.unknown);
  });

  test('GUARD the enum is the wire table, in order', () {
    expect(
      [for (final s in RpcStatus.values) s.code],
      [for (var c = 0; c <= 16; c++) c],
    );
  });
}
