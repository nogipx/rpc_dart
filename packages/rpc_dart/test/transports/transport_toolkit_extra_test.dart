import 'dart:async';
import 'dart:collection';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _RecordingBaseTransport extends RpcBaseTransport {
  final List<RpcTransportMessage> sent = <RpcTransportMessage>[];
  final List<int> finished = <int>[];
  bool _supportsZeroCopy;

  _RecordingBaseTransport({
    required super.isClient,
    bool supportsZeroCopy = false,
  }) : _supportsZeroCopy = supportsZeroCopy;

  @override
  int createStream() => generateStreamId();

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  bool get supportsZeroCopy => _supportsZeroCopy;

  set supportsZeroCopyEnabled(bool value) => _supportsZeroCopy = value;

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    sent.add(
      RpcTransportMessage.withPayload(
        payload: data,
        streamId: streamId,
        isEndOfStream: endStream,
      ),
    );
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    sent.add(
      RpcTransportMessage.withMetadata(
        metadata: metadata,
        streamId: streamId,
        isEndOfStream: endStream,
        methodPath: metadata.methodPath,
      ),
    );
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    sent.add(
      RpcTransportMessage.withDirectObject(
        directPayload: object,
        streamId: streamId,
        isEndOfStream: endStream,
      ),
    );
  }

  @override
  Future<void> finishSending(int streamId) async {
    finished.add(streamId);
  }
}

final class _AutoReconnectTransport extends _RecordingBaseTransport
    with RpcAutoReconnect {
  int _attempts = 0;

  _AutoReconnectTransport() : super(isClient: true);

  @override
  int get initialReconnectDelay => 1;

  @override
  double get reconnectBackoffMultiplier => 1.0;

  @override
  int get maxReconnectAttempts => 2;

  @override
  Future<void> performReconnect() async {
    _attempts++;
    if (_attempts == 1) {
      throw StateError('fail');
    }
  }
}

final class _AlwaysFailReconnectTransport extends _RecordingBaseTransport
    with RpcAutoReconnect {
  _AlwaysFailReconnectTransport() : super(isClient: true);

  @override
  int get initialReconnectDelay => 1;

  @override
  double get reconnectBackoffMultiplier => 1.0;

  @override
  int get maxReconnectAttempts => 2;

  @override
  Future<void> performReconnect() async {
    throw StateError('fail');
  }
}

final class _BufferedTransport extends RpcBaseTransport
    with RpcMessageBuffering {
  final Queue<RpcTransportMessage> delivered = Queue<RpcTransportMessage>();
  bool connectionAvailable = false;

  _BufferedTransport() : super(isClient: true);

  @override
  int createStream() => generateStreamId();

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('no');
  }

  @override
  bool get isConnectionAvailable => connectionAvailable;

  @override
  int get maxBufferSize => 2;

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    // Not used by these tests.
  }

  @override
  Future<void> finishSending(int streamId) async {
    // Not used by these tests.
  }

  @override
  Future<void> sendTransportMessage(RpcTransportMessage message) async {
    delivered.add(message);
  }
}

void main() {
  group('Transport toolkit: additional coverage', () {
    test('RpcTransportUtils length-prefixed frame roundtrip', () {
      final frame = RpcTransportUtils.createLengthPrefixedFrame([1, 2, 3]);
      expect(frame.length, 7);
      expect(RpcTransportUtils.parseLengthPrefixedFrame(frame), [1, 2, 3]);
      expect(RpcTransportUtils.parseLengthPrefixedFrame([0, 1, 2]), isNull);
    });

    test('RpcTransportUtils WebSocket frame parse/format', () {
      final frame = RpcTransportUtils.createWebSocketFrame(
        0x01020304,
        [9, 8],
        flags: 7,
      );
      final parsed = RpcTransportUtils.parseWebSocketFrame(frame)!;
      expect(parsed['streamId'], 0x01020304);
      expect(parsed['flags'], 7);
      expect(parsed['data'], [9, 8]);
      expect(RpcTransportUtils.parseWebSocketFrame([1, 2, 3, 4]), isNull);
    });

    test('RpcBaseTransport.sendTransportMessage dispatches correctly',
        () async {
      final t = _RecordingBaseTransport(isClient: true);

      await t.sendTransportMessage(
        RpcTransportMessage.withMetadata(
          metadata: RpcMetadata([RpcHeader('a', 'b')]),
          streamId: 1,
        ),
      );
      expect(t.sent.length, 1);
      expect(t.sent.single.isMetadataOnly, isTrue);

      await t.sendTransportMessage(
        RpcTransportMessage.withPayload(
          payload: Uint8List.fromList([1, 2]),
          streamId: 1,
        ),
      );
      expect(t.sent.length, 2);
      expect(t.sent.last.payload, isNotNull);

      t.supportsZeroCopyEnabled = true;
      await t.sendTransportMessage(
        RpcTransportMessage.withDirectObject(
          directPayload: 'x',
          streamId: 1,
          isEndOfStream: true,
        ),
      );
      expect(t.sent.length, 3);
      expect(t.sent.last.directPayload, 'x');
      expect(t.finished, [1]);
    });

    test('RpcBaseTransport health/reconnect reflect close', () async {
      final t = _RecordingBaseTransport(isClient: true);
      final before = await t.health();
      expect(before.level, RpcHealthLevel.healthy);

      await t.close();
      final after = await t.health();
      expect(after.level, RpcHealthLevel.closed);

      final reconnect = await t.reconnect();
      expect(reconnect.level, RpcHealthLevel.closed);
      expect(reconnect.details['supported'], isFalse);
    });

    test('RpcAutoReconnect attempts and success reset', () async {
      final t = _AutoReconnectTransport();

      final first = await t.attemptReconnect();
      expect(first, isFalse);

      final second = await t.attemptReconnect();
      expect(second, isTrue);

      final third = await t.attemptReconnect();
      expect(third, isTrue, reason: 'success resets attempt counter');
    });

    test('RpcAutoReconnect returns false after max attempts', () async {
      final t = _AlwaysFailReconnectTransport();

      final first = await t.attemptReconnect();
      expect(first, isFalse);

      final second = await t.attemptReconnect();
      expect(second, isFalse);

      final third = await t.attemptReconnect();
      expect(third, isFalse, reason: 'maxReconnectAttempts reached');
    });

    test('RpcMessageBuffering buffers while unavailable and flushes', () async {
      final t = _BufferedTransport();

      await t.sendMessage(1, Uint8List.fromList([1]));
      await t.sendMessage(1, Uint8List.fromList([2]));
      await t.sendMessage(1, Uint8List.fromList([3]));

      expect(t.bufferSize, 2, reason: 'maxBufferSize=2, drop oldest');
      expect(t.delivered, isEmpty);

      t.connectionAvailable = true;
      await t.sendMessage(1, Uint8List.fromList([4]));

      expect(t.bufferSize, 0);
      expect(t.delivered.length, 3);
    });
  });
}
