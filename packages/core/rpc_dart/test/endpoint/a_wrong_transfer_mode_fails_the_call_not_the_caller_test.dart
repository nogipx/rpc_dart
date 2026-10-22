// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call with no codecs over a transport that cannot carry objects, or with
// only one codec, is refused by the call processor, for every shape. The
// refusal arrives through the call's future or stream: a synchronous throw
// would bypass `.catchError` and every handler attached to the result.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  late RpcCallerEndpoint caller;

  setUp(() {
    // pair(): real frame encoding, so it does not carry objects.
    final (client, server) = RpcChannelTransport.pair();
    caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await server.close();
    });
  });

  test('unary with no codecs fails through its future', () async {
    late final Future<RpcString> call;
    expect(
      () => call = caller.unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'm',
        request: 'x'.rpc,
      ),
      returnsNormally,
    );
    await expectLater(call, throwsArgumentError);
  });

  test('unary with one codec fails through its future', () async {
    late final Future<RpcString> call;
    expect(
      () => call = caller.unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'm',
        request: 'x'.rpc,
        requestCodec: _codec,
      ),
      returnsNormally,
    );
    await expectLater(call, throwsArgumentError);
  });

  test('a server stream with no codecs fails through its stream', () async {
    late final Stream<RpcString> call;
    expect(
      () => call = caller.serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'm',
        request: 'x'.rpc,
      ),
      returnsNormally,
    );
    await expectLater(call, emitsError(isArgumentError));
  });
}
