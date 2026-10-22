// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary call whose context has already expired fails through the future it
// returns. A synchronous throw would bypass `.catchError` and every handler a
// caller attaches to the future.

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

void main() {
  test('an expired context fails the returned future', () async {
    final (client, server) = RpcChannelTransport.pair();
    addTearDown(client.close);
    addTearDown(server.close);
    final codec = RpcCodec(RpcString.fromJson);

    final caller = UnaryCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'S',
      methodName: 'M',
      requestCodec: codec,
      responseCodec: codec,
      context: RpcContext.empty().withDeadline(
        DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );

    late final Future<RpcString> result;
    expect(() => result = caller.call('x'.rpc), returnsNormally);
    await expectLater(result, throwsA(isA<RpcDeadlineExceededException>()));
  });
}
