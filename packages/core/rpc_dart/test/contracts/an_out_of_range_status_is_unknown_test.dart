// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer's grpc-status outside 0..16 reached the caller as that number:
// RpcStatusException(99), RpcStatusException(-1), while a non-numeric status
// already read as UNKNOWN. A caller branching on the code matched nothing.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

int? _status(String raw) => RpcCallerTrailer.statusOf(
  RpcMetadata([RpcHeader(RpcHeaders.grpcStatus, raw)]),
);

void main() {
  test('WITNESS a code outside 0..16 is UNKNOWN', () {
    expect(_status('99'), RpcStatus.unknown);
    expect(_status('-1'), RpcStatus.unknown);
    expect(_status('17'), RpcStatus.unknown);
  });

  test('GUARD every code in 0..16 is kept', () {
    for (var c = RpcStatus.ok; c <= RpcStatus.unauthenticated; c++) {
      expect(_status('$c'), c);
    }
    expect(_status('x'), RpcStatus.unknown);
  });
}
