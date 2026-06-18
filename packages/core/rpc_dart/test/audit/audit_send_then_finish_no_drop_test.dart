// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit regression: send(r) immediately followed by finishSending()/sendError()
// with NO await between must not drop the last message nor emit the trailer
// before it.
//
// The old StreamProcessor design relied on an async stream-controller listener
// to queue the real transport write: send() only did _responseController.add(r),
// while a listener appended the write onto _sendSequence on a later microtask.
// finishSending()/sendError() awaited _sendSequence and then closed the
// controller — but the queued write had not been appended yet, so the await
// observed an empty sequence and the trailer/error went out first (and, for
// sendError, the message was dropped entirely).
//
// The transport here makes sendMessage asynchronous (a real network round-trip
// is never synchronous), which exposes the race: we assert the recorded order
// right after the public call returns, with no extra draining.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A recording transport whose [sendMessage] is asynchronous, mirroring a real
/// network write and exposing send/trailer ordering races.
class _RecordingTransport implements IRpcTransport {
  final List<String> events = <String>[];
  final StreamController<RpcTransportMessage> _incoming =
      StreamController<RpcTransportMessage>.broadcast();

  @override
  bool get isClient => false;

  @override
  bool get isClosed => false;

  @override
  bool get supportsZeroCopy => false;

  @override
  int createStream() => 2;

  @override
  bool releaseStreamId(int streamId) => true;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final status = metadata.getHeaderValue(RpcHeaders.grpcStatus);
    events.add(status != null ? 'trailer:$status' : 'metadata');
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    // Asynchronous, like a real network write.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    events.add('message');
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('zero-copy not supported by recording transport');
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  Future<void> finishSending(int streamId) async {
    events.add('finishSending');
  }

  @override
  Future<void> close() async {
    await _incoming.close();
  }

  @override
  Future<RpcHealthStatus> health() async =>
      RpcHealthStatus.healthy(component: 'recording');

  @override
  Future<RpcHealthStatus> reconnect() async =>
      RpcHealthStatus.healthy(component: 'recording');
}

IRpcCodec<int> _intCodec() => RpcBinaryCodec<int>(
  toBytes: (v) => Uint8List.fromList([v & 0xFF]),
  fromBytes: (b) => b.isEmpty ? 0 : b[0],
);

StreamProcessor<int, int> _processor(_RecordingTransport transport) =>
    StreamProcessor<int, int>(
      transport: transport,
      streamId: 2,
      serviceName: 'Svc',
      methodName: 'M',
      requestCodec: _intCodec(),
      responseCodec: _intCodec(),
    );

void main() {
  group('StreamProcessor: send-then-finish must not drop the last message', () {
    test(
      'send(a) then finishSending() with no await: message before trailer',
      () async {
        final transport = _RecordingTransport();
        final processor = _processor(transport);

        // No await between send and finishSending: the old design dropped/raced.
        // ignore: unawaited_futures
        processor.send(7);
        await processor.finishSending();

        // Assert immediately: no extra draining that would mask the race.
        expect(
          transport.events,
          contains('message'),
          reason: 'last message must not be dropped',
        );
        final msgIdx = transport.events.indexOf('message');
        final trailerIdx = transport.events.indexWhere(
          (e) => e.startsWith('trailer:'),
        );
        expect(
          trailerIdx,
          greaterThanOrEqualTo(0),
          reason: 'OK trailer must be sent',
        );
        expect(
          msgIdx,
          lessThan(trailerIdx),
          reason: 'message must be sent before the OK trailer',
        );

        await processor.close();
        await transport.close();
      },
    );

    test(
      'send(a) then sendError() with no await: message before error trailer',
      () async {
        final transport = _RecordingTransport();
        final processor = _processor(transport);

        // No await between send and sendError.
        // ignore: unawaited_futures
        processor.send(9);
        await processor.sendError(RpcStatus.internal, 'boom');

        expect(
          transport.events,
          contains('message'),
          reason: 'last message must not be dropped before the error trailer',
        );
        final msgIdx = transport.events.indexOf('message');
        final errIdx = transport.events.indexWhere(
          (e) => e.startsWith('trailer:'),
        );
        expect(
          errIdx,
          greaterThanOrEqualTo(0),
          reason: 'error trailer must be sent',
        );
        expect(
          msgIdx,
          lessThan(errIdx),
          reason: 'message must be sent before the error trailer',
        );
        expect(transport.events.last, 'trailer:${RpcStatus.internal}');

        await processor.close();
        await transport.close();
      },
    );

    test('ordering preserved for multiple sends then finishSending', () async {
      final transport = _RecordingTransport();
      final processor = _processor(transport);

      // ignore: unawaited_futures
      processor.send(1);
      // ignore: unawaited_futures
      processor.send(2);
      // ignore: unawaited_futures
      processor.send(3);
      await processor.finishSending();

      final messages = transport.events.where((e) => e == 'message').toList();
      expect(
        messages.length,
        3,
        reason: 'all three queued messages must be sent before finishing',
      );
      final lastMsgIdx = transport.events.lastIndexOf('message');
      final trailerIdx = transport.events.indexWhere(
        (e) => e.startsWith('trailer:'),
      );
      expect(
        lastMsgIdx,
        lessThan(trailerIdx),
        reason: 'all messages must precede the trailer',
      );

      await processor.close();
      await transport.close();
    });
  });
}
