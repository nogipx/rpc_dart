// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request whose metadata the server's policy refuses ends that call and no
// other. The responder answers every active call on a broadcast error, so the
// violation has to arrive on the broadcast marked as advisory.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a refused request fails no other call on the connection', () async {
    const loose = RpcSecurityPolicy();
    const tight = RpcSecurityPolicy(maxHeaders: 8);
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair(policy: loose);
    final client = RpcChannelTransport(
      channel: clientCh,
      isClient: true,
      policy: loose,
    );
    final server = RpcChannelTransport(
      channel: serverCh,
      isClient: false,
      policy: tight,
    );
    addTearDown(() async {
      await client.close();
      await server.close();
    });
    RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Svc())
      ..start();
    final caller = RpcCallerEndpoint(transport: client);

    final innocent = [
      for (var i = 0; i < 3; i++)
        caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'Slow',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .then(
              (_) => 'ok',
              onError: (Object e) =>
                  e is RpcStatusException ? 'status ${e.statusCode}' : '$e',
            ),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final bad = client.createStream();
    final badStatus = Completer<String?>();
    client.getMessagesForStream(bad).listen((m) {
      final status = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
      if (status != null && !badStatus.isCompleted) badStatus.complete(status);
    }, onError: (Object _) {});
    await client.sendMetadata(
      bad,
      RpcMetadata([
        for (var i = 0; i < 20; i++) RpcHeader('x-h$i', 'v'),
      ], methodPath: '/Svc/Slow'),
    );

    expect(
      await badStatus.future.timeout(const Duration(seconds: 5)),
      RpcStatus.invalidArgument.toString(),
      reason: 'the refused request itself is still answered',
    );
    expect(await Future.wait(innocent), ['ok', 'ok', 'ok']);
  });
}
