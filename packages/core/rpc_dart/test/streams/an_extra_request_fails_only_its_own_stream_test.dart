// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A UnaryResponder built directly with the default `id == 0` serves every
// stream on its transport. A second request on one stream fails THAT call
// INTERNAL (gRPC's rule for a single-message side), and the flag recording it
// lived on the responder: every later stream's answer was then failed too,
// for a request it never received.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void main() {
  test('an extra request on one stream does not fail the next', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = UnaryResponder<RpcString, RpcString>(
      transport: server,
      serviceName: 'S',
      methodName: 'M',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return request;
      },
    );
    addTearDown(() async {
      await responder.close();
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

    expect(await call(extra: true), '${RpcStatus.internal}');
    expect(await call(extra: false), '${RpcStatus.ok}');
  });
}
