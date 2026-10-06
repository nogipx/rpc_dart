// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The policy counts metadata TEXT; a frame channel's receiver bounds the
// JSON-ENCODED frame by the same number, and a server closes the connection
// over it. A value full of quotes doubles when encoded, so metadata the
// sender's own check passed used to close the server connection and take every
// other call on it along. The sender now refuses that frame itself.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Five headers of [fill], about 34 KB of text against the 64 KiB default --
/// twice that once JSON escapes a quote.
Map<String, String> _headers(String fill) => {
  for (var i = 0; i < 5; i++) 'x-h$i': fill * 6800,
};

final class _Svc extends RpcResponderContract {
  _Svc() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async {
        final ms = int.tryParse(r.value);
        if (ms != null) await Future<void>.delayed(Duration(milliseconds: ms));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    (client, server) = RpcChannelTransport.pair();
    responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Svc())
      ..start();
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
  });

  Future<String> call(String value, [RpcContext? context]) => caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'echo',
        request: value.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: context,
      )
      .then((r) => r.value, onError: (Object e) => e.runtimeType.toString());

  test('WITNESS metadata that expands when encoded fails the call, not the '
      'connection', () async {
    final other = call('300');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final big = await call('x', RpcContext.withHeaders(_headers('"')));

    expect(
      await other,
      '300',
      reason: 'the call already open on the connection must survive',
    );
    expect(server.isClosed, isFalse);
    expect(big, 'RpcMetadataViolation');
  });

  test('GUARD the same text without escapes reaches the handler', () async {
    expect(await call('x', RpcContext.withHeaders(_headers('v'))), 'x');
  });

  test('WITNESS a server trailer over the bound once encoded is refused by '
      'the server', () async {
    final sid = client.createStream();
    await client.sendMetadata(sid, RpcMetadata(const [], methodPath: '/S/m'));

    final trailer = RpcMetadata([
      const RpcHeader('grpc-status', '5'),
      for (final e in _headers('"').entries) RpcHeader(e.key, e.value),
    ]);

    await expectLater(
      server.sendMetadata(sid, trailer, endStream: true),
      throwsA(isA<RpcMetadataViolation>()),
    );
    expect(client.isClosed, isFalse);
  });
}
