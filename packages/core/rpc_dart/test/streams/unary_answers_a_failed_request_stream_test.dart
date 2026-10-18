// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A unary call whose request stream FAILS must be answered, like every other
// shape answers.
//
// Driven with a request stream that errors before any request arrives, the
// serialized unary responder must put a status on the wire, and the same one
// the server-stream responder puts there. Unanswered, the caller waits for a
// response that never comes and eventually reports UNAVAILABLE "Stream closed
// without receiving response", which says nothing about the cause.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Records the gRPC statuses a responder sends, and nothing else.
class _RecordingTransport extends IRpcTransport {
  final List<String> statuses = [];
  final _incoming = StreamController<RpcTransportMessage>.broadcast();

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
  int get lastIssuedStreamId => 0;

  @override
  void resumeStreamIdsAfter(int streamId) {}
}

void main() {
  test('a failed request stream is reported to the peer', () async {
    // WITNESS: a status reaches the peer, and it is the one the streaming
    // shape sends for the same failure.
    final unaryTransport = _RecordingTransport();
    final unary = UnaryResponder<RpcString, RpcString>(
      id: 1,
      transport: unaryTransport,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r) async => r,
    );
    final unaryMessages = StreamController<RpcTransportMessage>();
    unary.bindToMessageStream(unaryMessages.stream);

    final streamTransport = _RecordingTransport();
    final stream = ServerStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: streamTransport,
      serviceName: 'Svc',
      methodName: 'watch',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r) => Stream<RpcString>.value('x'.rpc),
    );
    final streamMessages = StreamController<RpcTransportMessage>();
    stream.bindToMessageStream(streamMessages.stream);

    unaryMessages.addError(StateError('request stream failed'));
    streamMessages.addError(StateError('request stream failed'));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      unaryTransport.statuses,
      isNotEmpty,
      reason:
          'the caller is left waiting for a response that never comes, and '
          'reports UNAVAILABLE instead of the real cause',
    );
    expect(unaryTransport.statuses, streamTransport.statuses);

    await unaryMessages.close();
    await streamMessages.close();
    await unary.close();
    await stream.close();
    await unaryTransport.close();
    await streamTransport.close();
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
