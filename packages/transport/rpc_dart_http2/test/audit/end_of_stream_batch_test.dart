// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Regression test for the END_STREAM-by-value bug.
//
// `_handleIncomingData` (responder) and `_handleDataMessage` (caller) used to
// detect the last message of a parsed batch via `msgData == messages.last`.
// `messages` is a `List<Uint8List>` and `==` on Uint8List is identity-based, so
// the END_STREAM flag landed on the wrong (earlier) element whenever an earlier
// element shared the SAME object reference as the last one — and the comparison
// is brittle even for distinct-but-byte-identical messages. The correct rule is
// purely positional: only `i == messages.length - 1` is end-of-stream.
//
// Part 1 pins the corrected loop predicate directly, using a batch whose first
// element is the SAME Uint8List instance as the last one — the exact shape that
// made the old `== messages.last` predicate fire on the earlier element.
//
// Part 2 is an end-to-end check through the real RpcHttp2ResponderTransport with
// a fake HTTP/2 connection, ensuring exactly one (the last) payload message of a
// multi-message DATA frame is marked end-of-stream.

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_responder_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'END_STREAM selection is positional, not value-based '
    '(repeated object reference does not flag an earlier message)',
    () {
      // A batch where messages[0] and messages.last are the SAME instance.
      // Under the old `msgData == messages.last` predicate this flagged index 0
      // as end-of-stream too. The positional predicate must flag only index 2.
      final shared = Uint8List.fromList([1, 2, 3]);
      final messages = <Uint8List>[
        shared,
        Uint8List.fromList([4, 5, 6]),
        shared,
      ];
      const endStream = true;

      final flags = [
        for (var i = 0; i < messages.length; i++)
          endStream && i == messages.length - 1,
      ];

      expect(flags, equals([false, false, true]),
          reason: 'Only the genuinely last element is end-of-stream');

      // Guard: demonstrate the OLD predicate was wrong for this input.
      final buggy = [
        for (final m in messages) endStream && m == messages.last,
      ];
      expect(buggy, equals([true, false, true]),
          reason:
              'Sanity: the old value-based predicate mis-flagged index 0');
    },
  );

  test(
    'responder transport marks only the last message of a multi-message '
    'DATA frame as end-of-stream',
    () async {
      final connection = _FakeServerConnection();
      final transport = RpcHttp2ResponderTransport(connection: connection);

      // Two distinct gRPC frames in one chunk, endStream on the frame.
      final f0 = RpcMessageFrame.encode(
          Uint8List.fromList([10, 11]), compressed: false);
      final f1 = RpcMessageFrame.encode(
          Uint8List.fromList([20, 21]), compressed: false);
      final chunk = Uint8List(f0.length + f1.length)
        ..setRange(0, f0.length, f0)
        ..setRange(f0.length, f0.length + f1.length, f1);

      final received = <RpcTransportMessage>[];
      final done = Completer<void>();
      final sub = transport.incomingMessages.listen((m) {
        if (m.payload != null) {
          received.add(m);
          if (received.length == 2 && !done.isCompleted) done.complete();
        }
      });

      final stream = _FakeServerStream(7);
      connection.emitStream(stream);
      stream.emitData(http2.DataStreamMessage(chunk, endStream: true));

      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
      await transport.close();

      expect(received.length, equals(2));
      expect(received[0].isEndOfStream, isFalse);
      expect(received[1].isEndOfStream, isTrue);
    },
  );
}

/// Minimal fake [http2.ServerTransportConnection] that lets the test push
/// incoming streams.
class _FakeServerConnection implements http2.ServerTransportConnection {
  final StreamController<http2.ServerTransportStream> _incoming =
      StreamController<http2.ServerTransportStream>();

  void emitStream(http2.ServerTransportStream stream) => _incoming.add(stream);

  @override
  Stream<http2.ServerTransportStream> get incomingStreams => _incoming.stream;

  @override
  Future finish() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future terminate([int? errorCode]) async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future ping() async {}

  @override
  set onActiveStateChanged(http2.ActiveStateHandler callback) {}

  @override
  Future<void> get onInitialPeerSettingsReceived async {}

  @override
  Stream<int> get onPingReceived => const Stream.empty();

  @override
  Stream<void> get onFrameReceived => const Stream.empty();
}

/// Minimal fake [http2.ServerTransportStream] that lets the test push incoming
/// messages and swallows outgoing ones.
class _FakeServerStream implements http2.ServerTransportStream {
  _FakeServerStream(this.id);

  @override
  final int id;

  final StreamController<http2.StreamMessage> _incoming =
      StreamController<http2.StreamMessage>();

  void emitData(http2.StreamMessage message) => _incoming.add(message);

  @override
  Stream<http2.StreamMessage> get incomingMessages => _incoming.stream;

  @override
  StreamSink<http2.StreamMessage> get outgoingMessages => _NullSink();

  @override
  set onTerminated(void Function(int?) value) {}

  @override
  void terminate() {
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  void sendHeaders(List<http2.Header> headers, {bool endStream = false}) {}

  @override
  void sendData(List<int> bytes, {bool endStream = false}) {}

  @override
  bool get canPush => false;

  @override
  http2.ServerTransportStream push(List<http2.Header> requestHeaders) =>
      throw UnsupportedError('push');
}

class _NullSink implements StreamSink<http2.StreamMessage> {
  @override
  void add(http2.StreamMessage event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<http2.StreamMessage> stream) async {}

  @override
  Future close() async {}

  @override
  Future get done async {}
}
