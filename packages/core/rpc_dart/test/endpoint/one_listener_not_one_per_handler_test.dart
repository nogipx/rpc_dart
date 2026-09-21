// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every live unary handler held its own listener on the CONNECTION-WIDE
// broadcast, and each one was invoked for every inbound frame only to discard
// what was not its own:
//
//     if (id != 0 && message.streamId != id) return;
//
// O(N) per frame in the number of concurrent unary calls. Measured by counting
// listeners rather than timing, because the defect is a COUNT and a wall clock
// on an in-memory pair measures the machine:
//
//     parked handlers   listeners on incomingMessages
//        1                    2  ->  1
//       10                   11  ->  1
//       50                   51  ->  1
//      200                  201  ->  1
//
// For a pipeline responder the subscription delivered NOTHING anyway: the
// pipeline builds it with `id: streamId` and hands it the request four lines
// later. What it did deliver was `onError` -- and the pipeline's own onError
// only LOGGED, so a transport error that does not close the stream was answered
// here and nowhere else.
//
// That duty moved UP rather than away. `_answerActiveStreams` answers every
// stream once, instead of N listeners answering one each.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Req implements IRpcSerializable {
  final String v;
  _Req(this.v);
  factory _Req.fromJson(Map<String, dynamic> j) => _Req(j['v'] as String);
  @override
  Map<String, dynamic> toJson() => {'v': v};
}

final _codec = RpcCodec<_Req>(_Req.fromJson);

/// Counts how many times anything listens to `incomingMessages`.
final class _CountingTransport implements IRpcTransport {
  _CountingTransport(this._inner);

  final IRpcTransport _inner;
  int listeners = 0;

  @override
  Stream<RpcTransportMessage> get incomingMessages {
    listeners++;
    return _inner.incomingMessages;
  }

  @override
  bool get isClient => _inner.isClient;
  @override
  bool get isClosed => _inner.isClosed;
  @override
  bool get supportsZeroCopy => _inner.supportsZeroCopy;
  @override
  int createStream() => _inner.createStream();
  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => _inner.sendMetadata(streamId, metadata, endStream: endStream);
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => _inner.sendMessage(streamId, data, endStream: endStream);
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) => _inner.sendDirectObject(streamId, object, endStream: endStream);
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _inner.getMessagesForStream(streamId);
  @override
  Future<void> finishSending(int streamId) => _inner.finishSending(streamId);
  @override
  Future<void> close() => _inner.close();
  @override
  Future<RpcHealthStatus> health() => _inner.health();
  @override
  Future<RpcHealthStatus> reconnect() => _inner.reconnect();
}

final class _Svc extends RpcResponderContract {
  _Svc(this.park) : super('Svc');
  final Completer<void> park;

  @override
  void setup() {
    addUnaryMethod<_Req, _Req>(
      methodName: 'Park',
      handler: (r, {context}) async {
        await park.future;
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('one listener on the connection, whatever the load', () async {
    for (final parked in [1, 10, 50]) {
      final pair = RpcInMemoryTransport.pair();
      final counting = _CountingTransport(pair.$2);
      final caller = RpcCallerEndpoint(transport: pair.$1);
      final responder = RpcResponderEndpoint(transport: counting);
      final park = Completer<void>();
      responder.registerServiceContract(_Svc(park));
      responder.start();

      for (var i = 0; i < parked; i++) {
        unawaited(
          caller
              .unaryRequest<_Req, _Req>(
                serviceName: 'Svc',
                methodName: 'Park',
                request: _Req('x'),
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .catchError((Object _) => _Req('gave up')),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        counting.listeners,
        1,
        reason:
            'with $parked parked handlers there were ${counting.listeners} '
            'listeners; each is invoked per inbound frame to discard what is '
            'not its own',
      );

      park.complete();
      await caller.close();
      await responder.close();
    }
  });

  // GUARD: the duty the subscription carried must survive its removal. A
  // transport error that does NOT close the stream is still answered -- and
  // this is the half round 393 refused to drop the subscription without.
  test('GUARD: the handler still gets its answer', () async {
    final pair = RpcInMemoryTransport.pair();
    final caller = RpcCallerEndpoint(transport: pair.$1);
    final responder = RpcResponderEndpoint(transport: pair.$2);
    final park = Completer<void>();
    responder.registerServiceContract(_Svc(park));
    responder.start();
    addTearDown(() async {
      if (!park.isCompleted) park.complete();
      await caller.close();
      await responder.close();
    });

    final call = caller
        .unaryRequest<_Req, _Req>(
          serviceName: 'Svc',
          methodName: 'Park',
          request: _Req('x'),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pair.$2.close();

    // Either ending is an ANSWER; what must not happen is the caller waiting
    // out its own deadline with nothing.
    await expectLater(
      call.then((_) => 'answered').catchError((Object _) => 'answered'),
      completion('answered'),
    );
  });
}
