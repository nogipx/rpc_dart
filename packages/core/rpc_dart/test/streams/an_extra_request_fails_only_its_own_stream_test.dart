// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A second request on one unary stream fails THAT call INTERNAL (gRPC's rule
// for a single-message side). The refusal belongs to that stream alone: the
// next stream served by the same endpoint is answered OK.

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Service `S`, unary `M`: echoes its request after a short delay.
final class _Echo extends RpcResponderContract {
  _Echo() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'M',
      handler: (request, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('an extra request on one stream does not fail the next', () async {
    final (client, server) = RpcChannelTransport.pair();
    final endpoint = RpcResponderEndpoint(transport: server);
    endpoint.registerServiceContract(_Echo());
    endpoint.start();
    addTearDown(() async {
      await endpoint.close();
      await client.close();
      await server.close();
    });

    Uint8List frame(String s) =>
        RpcMessageFrame.encode(_codec.serialize(s.rpc));

    Future<String> call({required bool extra}) async {
      final id = client.createStream();
      final status = Completer<String>();
      final sub = client.getMessagesForStream(id).listen((m) {
        final s = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
        if (s != null && !status.isCompleted) status.complete(s);
      }, onError: (Object _) {});
      await client.sendMetadata(id, RpcMetadata.forClientRequest('S', 'M'));
      await client.sendMessage(id, frame('a'));
      if (extra) await client.sendMessage(id, frame('b'));
      await client.finishSending(id);
      final result = await status.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      return result;
    }

    expect(await call(extra: true), '${RpcStatus.internal.code}');
    expect(await call(extra: false), '${RpcStatus.ok.code}');
  });
}
