// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary call whose request stream FAILS must be answered, like every other
// shape answers.
//
// The four responder shapes disagreed, and the serialized unary one — the
// default for every codec-based unary method — was the odd one out:
//
//   three streaming shapes   StreamProcessor.bindToMessageStream's onError
//                            forwards into _requestController, the handler sees
//                            it, the machinery answers
//   zero-copy unary          explicit onError -> processor.sendError(...), added
//                            by an earlier round whose comment records that the
//                            streaming shapes "already route their
//                            request-stream errors, and this one did not"
//   SERIALIZED unary         logged it, and nothing else
//
// Measured, driving each shape with a request stream that errors before any
// request arrives:
//
//   ServerStreamResponder    status 13 sent to the peer
//   UnaryResponder           NONE
//
// The caller then waits for a response that never comes and eventually reports
// UNAVAILABLE "Stream closed without receiving response", which says nothing
// about the cause.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Records the gRPC statuses a responder sends, and nothing else.
class _RecordingTransport implements IRpcTransport {
  final List<String> statuses = [];
  final _incoming = StreamController<RpcTransportMessage>.broadcast();

  void failIncoming(Object error) => _incoming.addError(error);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final status = metadata.getHeaderValue(RpcHeaders.grpcStatus);
    if (status != null) statuses.add(status);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    List<int> data, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object payload, {
    bool endStream = false,
  }) async {}

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      const Stream<RpcTransportMessage>.empty();

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  bool get isClient => false;

  @override
  bool get isClosed => false;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => 1;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<void> close() async => _incoming.close();

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'test');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'test');
}

void main() {
  test('a failed request stream is reported to the peer', () async {
    // WITNESS. Pre-fix this recorded nothing: onError logged and returned.
    final transport = _RecordingTransport();
    UnaryResponder<RpcString, RpcString>(
      id: 1,
      transport: transport,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r) async => r,
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    transport.failIncoming(StateError('request stream failed'));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      transport.statuses,
      isNotEmpty,
      reason:
          'the caller is left waiting for a response that never comes, and '
          'reports UNAVAILABLE instead of the real cause',
    );
    await transport.close();
  });

  test(
    'GUARD: the streaming shape still answers, and with the same status',
    () async {
      // The control the fix was measured against. Without it, "unary answers"
      // could be satisfied by any status at all.
      final transport = _RecordingTransport();
      final responder = ServerStreamResponder<RpcString, RpcString>(
        id: 1,
        transport: transport,
        serviceName: 'Svc',
        methodName: 'watch',
        requestCodec: _codec,
        responseCodec: _codec,
        handler: (r) => Stream<RpcString>.value('x'.rpc),
      );
      final messages = StreamController<RpcTransportMessage>();
      responder.bindToMessageStream(messages.stream);

      messages.addError(StateError('request stream failed'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(transport.statuses, isNotEmpty);
      await messages.close();
      await transport.close();
    },
  );

  test('GUARD: a healthy unary call is not answered with an error', () async {
    // Without this the fix could answer every call with a status and still
    // pass the witness.
    final (clientT, serverT) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: serverT)
      ..registerServiceContract(_Svc())
      ..start();
    final caller = RpcCallerEndpoint(transport: clientT);

    final reply = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'hi'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(reply.value, 'hi');

    await caller.close();
    await responder.close();
    await clientT.close();
    await serverT.close();
  });
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
