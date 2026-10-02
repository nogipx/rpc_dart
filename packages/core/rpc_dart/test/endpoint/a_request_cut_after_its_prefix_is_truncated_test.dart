// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request stream that ends right after a 5-byte gRPC prefix promising a body
// is truncated, the same as one that ends partway into the body: the handler
// must not see a clean end and the caller must not be told OK.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract(this.seen) : super('Svc');

  final List<String> seen;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Up',
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {
          seen.add('msg');
        }
        seen.add('clean end');
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Bi',
      handler: (requests, {RpcContext? context}) async* {
        await for (final _ in requests) {
          seen.add('msg');
        }
        seen.add('clean end');
        yield 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends one whole request, then [tail], then the half-close; returns the
/// grpc-status the caller receives.
Future<String?> _call(String method, int tailBytes, List<String> seen) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract(seen))
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
  final whole = RpcMessageFrame.encode(_codec.serialize('hello'.rpc));
  await client.sendMessage(id, whole);
  await client.sendMessage(id, Uint8List.sublistView(whole, 0, tailBytes));
  await client.finishSending(id);
  return status;
}

void main() {
  for (final method in ['Up', 'Bi']) {
    group(method == 'Up' ? 'client-stream' : 'bidi', () {
      test('a tail of only the prefix is truncated', () async {
        final seen = <String>[];
        expect(await _call(method, 5, seen), '${RpcStatus.invalidArgument}');
        expect(seen, isNot(contains('clean end')));
      });

      test('CONTROL a tail cut inside the body is truncated', () async {
        final seen = <String>[];
        expect(await _call(method, 7, seen), '${RpcStatus.invalidArgument}');
        expect(seen, isNot(contains('clean end')));
      });
    });
  }
}
