// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Content codings are case-insensitive (RFC 9110). The response encoding is
// picked from the peer's list with the same rule `isSupported` applies, and
// comes back in the form the codec is registered under.
//
// VM only: gzip is built in there and nowhere else.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('WITNESS: an identity spelled in capitals is still identity', () {
    expect(RpcGrpcCompression.selectResponseEncoding('Identity, gzip'), 'gzip');
  });

  test('WITNESS: the chosen encoding is the registered name', () {
    expect(RpcGrpcCompression.selectResponseEncoding('GZIP'), 'gzip');
  });

  test('CONTROL: lower-case lists are unchanged', () {
    expect(RpcGrpcCompression.selectResponseEncoding('identity, gzip'), 'gzip');
    expect(RpcGrpcCompression.selectResponseEncoding('identity'), isNull);
    expect(RpcGrpcCompression.selectResponseEncoding(null), isNull);
    expect(RpcGrpcCompression.selectResponseEncoding('br'), isNull);
  });
}
