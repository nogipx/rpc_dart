// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A receiver advertises a stream's window at the end of the turn it first sees
// the stream, and not at all when the peer has finished sending by then. A
// unary request (headers, then a half-closing payload) and its answer (a
// payload, then the trailer) each arrive within one turn, so neither side has
// a window to send: a grant there is a frame nobody uses, on every call.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

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

/// One end of a byte pipe that records the per-stream window frames it sends.
final class _Pipe implements IRpcChannel {
  _Pipe(this.grants);

  final List<int> grants;
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late _Pipe peer;
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    final (frames, _) = RpcChannelFrame.decodeAll(data);
    for (final f in frames) {
      final window = f.metadata?.getHeaderValue(RpcHeaders.xWindowUpdate);
      if (f.streamId != 0 && window != null) grants.add(f.streamId);
    }
    peer._in.add(data);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _in.close();
  }
}

void main() {
  late List<int> grants;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    grants = [];
    final a = _Pipe(grants);
    final b = _Pipe(grants);
    a.peer = b;
    b.peer = a;
    final client = RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(channel: a),
      isClient: true,
    );
    final server = RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(channel: b),
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
      expect(grants, isEmpty);
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
        grants,
        isNotEmpty,
        reason: 'the caller receives a response stream over several turns',
      );
    },
  );
}
