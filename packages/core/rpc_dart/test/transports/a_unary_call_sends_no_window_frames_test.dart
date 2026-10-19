// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A receiver advertises a stream's window at the end of the turn it first sees
// the stream, and not at all when the peer has finished sending by then. A
// unary request (headers, then a half-closing payload) and its answer (a
// payload, then the trailer) each arrive within one turn, so neither side has
// a window to send: a grant there is a frame nobody uses, on every call.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
    // Answers turns after the request ended, so the stream is still open when
    // the turn that received the request ends.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return r;
      },
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'many',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 3; i++) {
          yield r;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
    );
  }
}

/// The streams [pipe] sent a per-stream window frame for.
List<int> _grants(TapPipe pipe) => [
  for (final f in pipe.sentFrames)
    if (f.streamId != 0 &&
        f.metadata?.getHeaderValue(RpcHeaders.xWindowUpdate) != null)
      f.streamId,
];

void main() {
  late TapPipe a;
  late TapPipe b;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;
  List<int> grants() => [..._grants(a), ..._grants(b)];

  setUp(() {
    (a, b) = TapPipe.pair();
    final client = RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(channel: a, isClient: true),
      isClient: true,
    );
    final server = RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(channel: b, isClient: false),
      isClient: false,
    );
    responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Svc())
      ..start();
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
  });

  for (final method in ['echo', 'slow']) {
    test('a unary call sends no per-stream window ($method handler)', () async {
      for (var i = 0; i < 3; i++) {
        final reply = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          request: 'hi'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        );
        expect(reply.value, 'hi');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(grants(), isEmpty);
    });
  }

  test(
    'GUARD a stream still open at the end of the turn gets its window',
    () async {
      final replies = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'many',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .toList();
      expect(replies, hasLength(3));
      expect(
        grants(),
        isNotEmpty,
        reason: 'the caller receives a response stream over several turns',
      );
    },
  );
}
