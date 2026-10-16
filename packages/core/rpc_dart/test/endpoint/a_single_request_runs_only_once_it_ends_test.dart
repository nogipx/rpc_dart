// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Unary and server stream carry one request, and their handler runs only once
// the peer has ended the request stream, as grpc-go's does. Run on the first
// message, a handler served a request that was then refused for a second
// message or a cut tail: its side effects happened, and a server stream
// answered OK.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract(this.ran) : super('Svc');

  final List<String> ran;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        ran.add('echo');
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'items',
      handler: (r, {RpcContext? context}) async* {
        ran.add('items');
        yield r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Peer = ({
  IRpcTransport client,
  int id,
  Future<String?> status,
  List<String> ran,
});

/// Opens a call to [method] and sends one whole request, without ending it.
Future<_Peer> _open(String method) async {
  final ran = <String>[];
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract(ran))
    ..start();
  addTearDown(() async {
    await responder.close();
    await client.close();
    await server.close();
  });

  final id = client.createStream();
  final status = client
      .getMessagesForStream(id)
      .map((m) => m.metadata?.getHeaderValue('grpc-status'))
      .firstWhere((s) => s != null, orElse: () => null)
      .timeout(const Duration(seconds: 3), onTimeout: () => null);
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', method));
  await client.sendMessage(id, _whole);
  return (client: client, id: id, status: status, ran: ran);
}

final _whole = RpcMessageFrame.encode(_codec.serialize('hello'.rpc));

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  for (final method in ['echo', 'items']) {
    group(method, () {
      test('WITNESS the start of a second message is refused before the '
          'handler runs', () async {
        final p = await _open(method);
        await _settle();
        await p.client.sendMessage(p.id, Uint8List.sublistView(_whole, 0, 3));
        await p.client.finishSending(p.id);
        expect(await p.status, '${RpcStatus.internal}');
        expect(p.ran, isEmpty);
      });

      test('WITNESS a whole second message is refused before the handler '
          'runs', () async {
        final p = await _open(method);
        await _settle();
        await p.client.sendMessage(p.id, _whole);
        await p.client.finishSending(p.id);
        expect(await p.status, '${RpcStatus.internal}');
        expect(p.ran, isEmpty);
      });

      test('the handler waits for the half-close, then runs', () async {
        final p = await _open(method);
        await _settle();
        expect(p.ran, isEmpty, reason: 'the request has not ended yet');
        await p.client.finishSending(p.id);
        expect(await p.status, '0');
        expect(p.ran, [method]);
      });
    });
  }
}
