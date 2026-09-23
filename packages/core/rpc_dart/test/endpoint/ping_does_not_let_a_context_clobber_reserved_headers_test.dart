// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Three sites in core merge a caller RpcContext's headers into outbound request
// metadata. Two filter RpcHeaders.reserved; ping did not, so a context carrying
// `content-type` -- what a gateway forwarding an inbound header map produces --
// made the keepalive fail INVALID_ARGUMENT while every other call shape on that
// same context succeeded.

// The ping protocol is off the public barrel; tests reach it here.
import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async =>
          (context?.headers['x-tenant'] ?? 'absent').rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Records every metadata frame the endpoint puts on the wire.
final class _RecordingTransport implements IRpcTransport {
  final IRpcTransport _inner;
  final List<RpcMetadata> sent = [];

  _RecordingTransport(this._inner);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) {
    sent.add(metadata);
    return _inner.sendMetadata(streamId, metadata, endStream: endStream);
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
  Stream<RpcTransportMessage> get incomingMessages => _inner.incomingMessages;
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

void main() {
  late RpcChannelTransport clientTransport;
  late RpcChannelTransport serverTransport;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
    clientTransport = RpcChannelTransport(channel: clientCh, isClient: true);
    serverTransport = RpcChannelTransport(channel: serverCh, isClient: false);
    caller = RpcCallerEndpoint(transport: clientTransport);
    responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(_Contract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await clientTransport.close();
    await serverTransport.close();
  });

  // WITNESS. Fails without the filter with
  // `RpcStatusException: [3] Invalid content-type for gRPC`.
  test('ping survives a context that carries content-type', () async {
    final forwarded = RpcContext.withHeaders({
      RpcHeaders.contentType: 'application/json',
      'x-tenant': 'acme',
    });

    final result = await caller.ping(context: forwarded);

    expect(
      result.responseHeaders[RpcHeaders.grpcStatus],
      equals(RpcStatus.ok.toString()),
    );
  });

  // GUARD. The filter is key-selective, not a blanket drop: the same context
  // reaches the sibling shape whole, so a green witness cannot come from the
  // context being emptied.
  test(
    'the same context still delivers its own header on a unary call',
    () async {
      final forwarded = RpcContext.withHeaders({
        RpcHeaders.contentType: 'application/json',
        'x-tenant': 'acme',
      });

      final response = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: forwarded,
        transferMode: RpcDataTransferMode.codec,
      );

      expect(response, equals('acme'.rpc));
    },
  );

  // WITNESS over the whole reserved set, not only the member with a consumer
  // that refuses. Reads the frame rather than the outcome, because te and
  // user-agent have no in-process consequence to observe.
  test('no reserved key from the context reaches the ping frame', () async {
    final recording = _RecordingTransport(clientTransport);
    final probe = RpcCallerEndpoint(transport: recording);
    addTearDown(probe.close);

    final forged = RpcContext.withHeaders({
      for (final key in RpcHeaders.reserved) key: 'forged',
      'x-tenant': 'acme',
    });

    // The frame is recorded as it is sent, so the assertions below hold
    // whatever the peer answers. Without that the content-type refusal alone
    // ends the test and the other seven keys are never checked.
    try {
      await probe.ping(context: forged);
    } on RpcStatusException {
      // Checked by the first test.
    }

    final ping = recording.sent.singleWhere(
      (m) => m.methodPath == RpcEndpointPingProtocol.methodPath,
    );
    final headers = {for (final h in ping.headers) h.name: h.value};

    expect(headers['x-tenant'], equals('acme'), reason: 'the guard half');
    for (final key in RpcHeaders.reserved) {
      expect(
        headers[key],
        isNot(equals('forged')),
        reason: '$key was settable as ordinary user metadata',
      );
    }
  });
}
