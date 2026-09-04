// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A stream the responder pipeline has REFUSED and torn down must stay torn
// down. _processResponderMessage ignored a frame for a closed stream only
// `if (message.methodPath == null)`, so any frame carrying a method path
// cleared the closed-stream guard and re-opened the id -- and several
// transports tag their DATA frames with the method path, not just the frame
// that opens the call.
//
// The consequence, measured end to end over real sockets on HTTP/1.1 (see
// rpc_dart_http/test/refused_request_never_reaches_handler_test.dart): a
// request refused with UNIMPLEMENTED for an unsupported grpc-encoding still
// reached the application handler. Traced at the transport:
//
//   sendMetadata(stream=4, endStream=true, grpc-status=12)  <- refused
//   releaseStreamId(4)                                       <- cleaned up
//   sendMetadata(stream=4, endStream=false)                  <- resurrected
//   >>> HANDLER RAN
//   sendMetadata(stream=4, endStream=true, grpc-status=0)    <- discarded
//
// The peer is told the call was never implemented while the server performs it.
// The http2 sibling was correct throughout, because it tags only its HEADERS
// frame; that asymmetry is what identified the defect.
//
// This test drives the pipeline directly so the guard itself is pinned,
// independently of which transport happens to reproduce it today.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _handlerRuns = 0;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async {
        _handlerRuns++;
        return 'echo-ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A responder-side transport driven frame by frame, recording what the
/// pipeline sends back. Models the HTTP/1.1 shape: metadata and payload arrive
/// as two separate frames, and BOTH carry the method path.
final class _ScriptedTransport implements IRpcTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  final sent = <String>[];

  void deliver(RpcTransportMessage message) => _incoming.add(message);

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      _incoming.stream.where((m) => m.streamId == streamId);

  @override
  bool get isClient => false;

  @override
  bool get isClosed => _incoming.isClosed;

  @override
  int createStream() => 0;

  @override
  bool releaseStreamId(int streamId) {
    sent.add('release($streamId)');
    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final status = metadata.getHeaderValue('grpc-status');
    sent.add(
      'metadata($streamId'
      '${status == null ? '' : ', grpc-status=$status'}'
      '${endStream ? ', end' : ''})',
    );
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    sent.add('message($streamId)');
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object payload, {
    bool endStream = false,
  }) async {
    sent.add('direct($streamId)');
  }

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  bool get supportsZeroCopy => false;

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus(level: RpcHealthLevel.healthy, component: 'scripted');

  @override
  Future<RpcHealthStatus> reconnect() async => health();

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Metadata a foreign peer would open a call with.
RpcMetadata _openingHeaders({String? encoding}) => RpcMetadata([
  const RpcHeader(RpcHeaders.contentType, 'application/grpc'),
  if (encoding != null) RpcHeader(RpcHeaders.grpcEncoding, encoding),
]);

Uint8List _frame() =>
    RpcMessageFrame.encode(_codec.serialize('hello'.rpc), compressed: false);

void main() {
  late _ScriptedTransport transport;
  late RpcResponderEndpoint responder;

  setUp(() {
    _handlerRuns = 0;
    transport = _ScriptedTransport();
    responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Contract());
    responder.start();
  });

  tearDown(() async {
    await responder.close();
    await transport.close();
  });

  /// Sends a call the way HTTP/1.1 does: headers, then a body frame that ALSO
  /// carries the method path.
  Future<void> call(int streamId, {String? encoding}) async {
    transport.deliver(
      RpcTransportMessage(
        streamId: streamId,
        metadata: _openingHeaders(encoding: encoding),
        isEndOfStream: false,
        methodPath: '/Svc/Echo',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    transport.deliver(
      RpcTransportMessage(
        streamId: streamId,
        payload: _frame(),
        isEndOfStream: true,
        methodPath: '/Svc/Echo',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  test('a refused stream is not resurrected by its own body frame', () async {
    await call(4, encoding: 'snappy');

    expect(
      _handlerRuns,
      0,
      reason:
          'the pipeline refused this call with UNIMPLEMENTED and released the '
          'stream; the body frame that followed carried the method path, which '
          'cleared the closed-stream guard and re-opened the very stream that '
          'had just been refused, so the handler ran for a call the peer was '
          'told was never implemented',
    );
    expect(
      transport.sent,
      contains('metadata(4, grpc-status=12, end)'),
      reason: 'the refusal itself was always correct',
    );
    expect(
      transport.sent.where((s) => s.contains('grpc-status=0')),
      isEmpty,
      reason: 'no success trailer may follow a refusal on the same stream',
    );
  });

  test('CONTROL: a supported encoding still reaches the handler', () async {
    await call(6, encoding: 'identity');
    expect(_handlerRuns, 1);
    expect(transport.sent, contains('metadata(6, grpc-status=0, end)'));
  });

  test('GUARD: a new call REUSES a released stream id', () async {
    // The guard clears for a genuine new call precisely so ids can be reused.
    // Tightening it must not swallow the reuse -- that would hang every call
    // once a transport's id manager wrapped around.
    await call(8);
    expect(_handlerRuns, 1);

    await call(8);
    expect(
      _handlerRuns,
      2,
      reason:
          'stream 8 was released after the first call and is in the '
          'closed-stream set; a new call opening on it with METADATA must '
          'still be accepted',
    );
  });

  // A WITNESS, not the guard it was first written as -- the canary showed it
  // failing pre-fix at 2 handler runs instead of 1. So the defect was never
  // limited to refused calls: a late or duplicated body frame re-opened an
  // already-COMPLETED stream and ran the handler a second time, for a call the
  // peer had already been given its answer to. On a mutating method that is a
  // silent double-execution.
  test(
    'a completed stream is not re-opened by a duplicate body frame',
    () async {
      await call(10);
      expect(_handlerRuns, 1);
      final afterCall = transport.sent.length;

      // A late body frame with no metadata: the case the guard exists for.
      transport.deliver(
        RpcTransportMessage(
          streamId: 10,
          payload: _frame(),
          isEndOfStream: true,
          methodPath: '/Svc/Echo',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(_handlerRuns, 1, reason: 'a trailing frame must not open a call');
      expect(
        transport.sent.length,
        afterCall,
        reason: 'and must not be answered',
      );
    },
  );
}
