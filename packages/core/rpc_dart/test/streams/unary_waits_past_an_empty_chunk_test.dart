// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A zero-length DATA chunk ahead of a valid unary request failed the call
// INTERNAL ("Failed to extract message from payload") while server-stream and
// bidi served the same sequence. An empty chunk has nothing to refuse; the
// unary responder now waits past it as it waits on a partial frame.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo(this.handled) : super('Svc');

  final List<String> handled;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'u',
      handler: (r, {RpcContext? context}) async {
        handled.add(r.value);
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends [chunks] as DATA frames of one unary call, the last with
/// end-of-stream; returns the statuses the caller saw and what the handler got.
Future<(List<String>, List<String>)> _call(List<Uint8List> chunks) async {
  final handled = <String>[];
  final (client, server) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Echo(handled))
    ..start();
  addTearDown(() async {
    await responder.close();
    await client.close();
  });

  final id = client.createStream();
  final statuses = <String>[];
  client.getMessagesForStream(id).listen((m) {
    final s = m.metadata?.getHeaderValue(RpcHeaders.grpcStatus);
    if (s != null) statuses.add(s);
  }, onError: (Object _) {});
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'u'));
  for (var i = 0; i < chunks.length; i++) {
    await client.sendMessage(id, chunks[i], endStream: i == chunks.length - 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return (statuses, handled);
}

Uint8List _request(String s) => RpcMessageFrame.encode(_codec.serialize(s.rpc));

void main() {
  test('an empty chunk before the request', () async {
    final (statuses, handled) = await _call([Uint8List(0), _request('a')]);
    expect(statuses, ['${RpcStatus.ok}']);
    expect(handled, ['a']);
  });

  test('CONTROL: the request alone', () async {
    final (statuses, handled) = await _call([_request('a')]);
    expect(statuses, ['${RpcStatus.ok}']);
    expect(handled, ['a']);
  });

  test('GUARD: only an empty chunk is still refused, once', () async {
    final (statuses, handled) = await _call([Uint8List(0)]);
    expect(statuses, hasLength(1));
    expect(statuses.single, isNot('${RpcStatus.ok}'));
    expect(handled, isEmpty);
  });
}
