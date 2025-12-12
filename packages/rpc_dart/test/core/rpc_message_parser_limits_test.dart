// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('RpcMessageParser throws when frame length exceeds max', () {
    final parser = RpcMessageParser(maxMessageLength: 4);

    // Header: compression=0, length=10
    final header = Uint8List.fromList([0, 0, 0, 0, 10]);

    expect(
      () => parser(header),
      throwsA(isA<RpcException>()),
    );
  });
}
