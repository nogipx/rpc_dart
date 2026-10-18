// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The policy counts metadata TEXT; a frame channel's receiver bounds the
// ENCODED frame by the same number, and a server closes the connection over
// it. Every header costs its two lengths on top of its text, so metadata the
// sender's own text check passes can still be over the receiver's bound, and
// sending it would close the connection and every other call on it. The
// sender refuses that frame itself.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// 120 headers, 65520 bytes of text against the 64 KiB default: under it as
/// text, over it once each header's lengths are added.
List<RpcHeader> _framingHeavy() => [
  for (var i = 0; i < 120; i++)
    RpcHeader('x-h${i.toString().padLeft(3, '0')}', 'v' * 540),
];

/// Five headers, about 34 KB of text and of frame: under the bound either way.
Map<String, String> _light() => {
  for (var i = 0; i < 5; i++) 'x-h$i': 'v' * 6800,
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

  test('the premise: the text is under the bound, the frame over it', () {
    final metadata = RpcMetadata(_framingHeavy(), methodPath: '/S/m');
    final limit = const RpcSecurityPolicy().maxMetadataBytes;
    expect(
      () => const RpcSecurityPolicy().validateMetadata(metadata),
      returnsNormally,
    );
    final frame = RpcChannelFrame.encodeMetadata(
      streamId: 1,
      metadata: metadata,
    );
    expect(frame.length - RpcChannelFrame.headerSize, greaterThan(limit));
  });

  test('WITNESS metadata over the bound once encoded fails the call, not the '
      'connection', () async {
    final other = call('300');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final sid = client.createStream();
    await expectLater(
      client.sendMetadata(
        sid,
        RpcMetadata(_framingHeavy(), methodPath: '/S/echo'),
      ),
      throwsA(isA<RpcMetadataViolation>()),
    );

    expect(
      await other,
      '300',
      reason: 'the call already open on the connection must survive',
    );
    expect(server.isClosed, isFalse);
  });

  test(
    'GUARD metadata under the bound once encoded reaches the handler',
    () async {
      expect(await call('x', RpcContext.withHeaders(_light())), 'x');
    },
  );

  test('WITNESS a server trailer over the bound once encoded is refused by '
      'the server', () async {
    final sid = client.createStream();
    await client.sendMetadata(sid, RpcMetadata(const [], methodPath: '/S/m'));

    final trailer = RpcMetadata([
      const RpcHeader('grpc-status', '5'),
      ..._framingHeavy(),
    ]);

    await expectLater(
      server.sendMetadata(sid, trailer, endStream: true),
      throwsA(isA<RpcMetadataViolation>()),
    );
    expect(client.isClosed, isFalse);
  });
}
