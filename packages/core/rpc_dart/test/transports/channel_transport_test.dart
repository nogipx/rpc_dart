// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcChannelFrame', () {
    test('encodes and decodes a data frame', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = RpcChannelFrame.encodeData(
        streamId: 42,
        payload: payload,
      );

      final decoded = RpcChannelFrame.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.streamId, equals(42));
      expect(decoded.isMetadata, isFalse);
      expect(decoded.endOfStream, isFalse);
      expect(decoded.payload, equals(payload));
    });

    test('encodes and decodes a data frame with endOfStream', () {
      final payload = Uint8List.fromList([10, 20]);
      final encoded = RpcChannelFrame.encodeData(
        streamId: 7,
        payload: payload,
        endOfStream: true,
      );

      final decoded = RpcChannelFrame.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.streamId, equals(7));
      expect(decoded.endOfStream, isTrue);
      expect(decoded.isMetadata, isFalse);
      expect(decoded.payload, equals(payload));
    });

    test('encodes and decodes a metadata frame', () {
      final metadata = RpcMetadata.forClientRequest(
        'TestService',
        'TestMethod',
      );
      final encoded = RpcChannelFrame.encodeMetadata(
        streamId: 5,
        metadata: metadata,
      );

      final decoded = RpcChannelFrame.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.streamId, equals(5));
      expect(decoded.isMetadata, isTrue);
      expect(decoded.endOfStream, isFalse);
      expect(decoded.payload, isNull);
      expect(decoded.methodPath, equals('/TestService/TestMethod'));
    });

    test('encodes and decodes metadata with headers', () {
      final metadata = RpcMetadata(
        [
          RpcHeader('x-custom', 'value1'),
          RpcHeader('x-another', 'value2'),
        ],
        methodPath: '/Svc/Method',
      );
      final encoded = RpcChannelFrame.encodeMetadata(
        streamId: 3,
        metadata: metadata,
        endOfStream: true,
      );

      final decoded = RpcChannelFrame.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.isMetadata, isTrue);
      expect(decoded.endOfStream, isTrue);
      expect(decoded.methodPath, equals('/Svc/Method'));
      expect(decoded.metadata!.headers.length, equals(2));
      expect(decoded.metadata!.headers[0].name, equals('x-custom'));
      expect(decoded.metadata!.headers[0].value, equals('value1'));
      expect(decoded.metadata!.headers[1].name, equals('x-another'));
      expect(decoded.metadata!.headers[1].value, equals('value2'));
    });

    test('encodes and decodes endOfStream marker', () {
      final encoded = RpcChannelFrame.encodeEndOfStream(99);

      final decoded = RpcChannelFrame.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.streamId, equals(99));
      expect(decoded.endOfStream, isTrue);
      expect(decoded.isMetadata, isFalse);
      expect(decoded.payload, equals(Uint8List(0)));
    });

    test('returns null for truncated data', () {
      final result = RpcChannelFrame.decode(Uint8List.fromList([1, 2, 3]));
      expect(result, isNull);
    });

    test('returns null when payload is incomplete', () {
      // Header says 100 bytes payload, but we only have 9 + 5
      final frame = Uint8List(14);
      final view = ByteData.sublistView(frame);
      view.setUint32(0, 1); // streamId
      view.setUint8(4, 0); // flags
      view.setUint32(5, 100); // payloadLen = 100 but only 5 bytes follow

      final result = RpcChannelFrame.decode(frame);
      expect(result, isNull);
    });

    group('decodeAll', () {
      test('decodes multiple frames from a buffer', () {
        final frame1 = RpcChannelFrame.encodeData(
          streamId: 1,
          payload: Uint8List.fromList([10]),
        );
        final frame2 = RpcChannelFrame.encodeData(
          streamId: 3,
          payload: Uint8List.fromList([20]),
        );

        final combined = Uint8List(frame1.length + frame2.length);
        combined.setRange(0, frame1.length, frame1);
        combined.setRange(frame1.length, combined.length, frame2);

        final (frames, consumed) = RpcChannelFrame.decodeAll(combined);
        expect(frames.length, equals(2));
        expect(consumed, equals(combined.length));
        expect(frames[0].streamId, equals(1));
        expect(frames[1].streamId, equals(3));
      });

      test('handles partial frame at the end', () {
        final frame1 = RpcChannelFrame.encodeData(
          streamId: 1,
          payload: Uint8List.fromList([10]),
        );
        // Append incomplete data
        final combined = Uint8List(frame1.length + 5);
        combined.setRange(0, frame1.length, frame1);
        combined.setRange(frame1.length, combined.length, [0, 0, 0, 0, 0]);

        final (frames, consumed) = RpcChannelFrame.decodeAll(combined);
        expect(frames.length, equals(1));
        expect(consumed, equals(frame1.length));
      });

      test('returns empty list for empty buffer', () {
        final (frames, consumed) = RpcChannelFrame.decodeAll(Uint8List(0));
        expect(frames, isEmpty);
        expect(consumed, equals(0));
      });
    });
  });

  group('RpcChannelTransport', () {
    group('pair factory', () {
      test('creates two connected transports', () {
        final (client, server) = RpcChannelTransport.pair();

        expect(client.isClient, isTrue);
        expect(server.isClient, isFalse);
        expect(client.isClosed, isFalse);
        expect(server.isClosed, isFalse);

        // Cleanup
        client.close();
        server.close();
      });

      test('does not support zero copy', () {
        final (client, server) = RpcChannelTransport.pair();

        expect(client.supportsZeroCopy, isFalse);
        expect(server.supportsZeroCopy, isFalse);

        client.close();
        server.close();
      });
    });

    group('stream IDs', () {
      test('client generates odd IDs', () {
        final (client, server) = RpcChannelTransport.pair();

        final ids = List.generate(5, (_) => client.createStream());
        for (final id in ids) {
          expect(id % 2, equals(1));
        }

        client.close();
        server.close();
      });

      test('server generates even IDs', () {
        final (client, server) = RpcChannelTransport.pair();

        final ids = List.generate(5, (_) => server.createStream());
        for (final id in ids) {
          expect(id % 2, equals(0));
        }

        client.close();
        server.close();
      });

      test('createStream throws when maxActiveStreams exceeded', () {
        final (client, server) = RpcChannelTransport.pair(
          policy: RpcSecurityPolicy(maxActiveStreams: 2),
        );

        client.createStream();
        client.createStream();
        expect(() => client.createStream(), throwsStateError);

        client.close();
        server.close();
      });
    });

    group('sendMessage', () {
      test('sends data between transports', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        final payload = Uint8List.fromList('hello'.codeUnits);
        await client.sendMessage(streamId, payload);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.streamId, equals(streamId));
        expect(received.first.payload, equals(payload));
        expect(received.first.isEndOfStream, isFalse);

        await client.close();
        await server.close();
      });

      test('sends data with endStream flag', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        await client.sendMessage(
          streamId,
          Uint8List.fromList([1, 2, 3]),
          endStream: true,
        );

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.isEndOfStream, isTrue);

        await client.close();
        await server.close();
      });

      test('bidirectional messaging', () async {
        final (client, server) = RpcChannelTransport.pair();
        final clientReceived = <RpcTransportMessage>[];
        final serverReceived = <RpcTransportMessage>[];

        client.incomingMessages.listen(clientReceived.add);
        server.incomingMessages.listen(serverReceived.add);

        final clientStreamId = client.createStream();
        final serverStreamId = server.createStream();

        await client.sendMessage(
          clientStreamId,
          Uint8List.fromList('request'.codeUnits),
        );
        await server.sendMessage(
          serverStreamId,
          Uint8List.fromList('response'.codeUnits),
        );

        await Future.delayed(Duration(milliseconds: 10));

        expect(serverReceived.length, equals(1));
        expect(clientReceived.length, equals(1));
        expect(
          String.fromCharCodes(serverReceived.first.payload!),
          equals('request'),
        );
        expect(
          String.fromCharCodes(clientReceived.first.payload!),
          equals('response'),
        );

        await client.close();
        await server.close();
      });

      test('does not send after close', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        await client.close();

        await client.sendMessage(streamId, Uint8List.fromList([1]));
        await Future.delayed(Duration(milliseconds: 10));

        expect(received, isEmpty);

        await server.close();
      });
    });

    group('sendMetadata', () {
      test('sends metadata with method path', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );
        await client.sendMetadata(streamId, metadata);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.streamId, equals(streamId));
        expect(received.first.methodPath, equals('/TestService/TestMethod'));
        expect(received.first.metadata, isNotNull);

        await client.close();
        await server.close();
      });

      test('sends metadata with custom headers', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        final metadata = RpcMetadata(
          [
            RpcHeader('x-request-id', 'abc-123'),
            RpcHeader('x-trace-id', 'trace-456'),
          ],
          methodPath: '/Svc/Method',
        );
        await client.sendMetadata(streamId, metadata);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        final msg = received.first;
        expect(msg.metadata!.headers.length, equals(2));
        expect(msg.metadata!.headers[0].name, equals('x-request-id'));
        expect(msg.metadata!.headers[0].value, equals('abc-123'));
        expect(msg.metadata!.headers[1].name, equals('x-trace-id'));
        expect(msg.metadata!.headers[1].value, equals('trace-456'));

        await client.close();
        await server.close();
      });

      test('sends metadata with endStream', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        final metadata = RpcMetadata.forClientRequest('Svc', 'Method');
        await client.sendMetadata(streamId, metadata, endStream: true);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.isEndOfStream, isTrue);

        await client.close();
        await server.close();
      });
    });

    group('sendDirectObject', () {
      test('throws UnsupportedError', () async {
        final (client, server) = RpcChannelTransport.pair();

        final streamId = client.createStream();
        expect(
          () => client.sendDirectObject(streamId, 'test'),
          throwsUnsupportedError,
        );

        await client.close();
        await server.close();
      });
    });

    group('finishSending', () {
      test('sends end-of-stream marker', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        await client.finishSending(streamId);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.streamId, equals(streamId));
        expect(received.first.isEndOfStream, isTrue);

        await client.close();
        await server.close();
      });

      test('prevents duplicate sends for same stream', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final streamId = client.createStream();
        await client.finishSending(streamId);
        await client.finishSending(streamId);

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(received.first.isEndOfStream, isTrue);

        await client.close();
        await server.close();
      });
    });

    group('getMessagesForStream', () {
      test('filters messages by stream ID', () async {
        final (client, server) = RpcChannelTransport.pair();

        final stream1 = client.createStream();
        final stream3 = client.createStream();

        final msgs1 = <RpcTransportMessage>[];
        final msgs3 = <RpcTransportMessage>[];
        server.getMessagesForStream(stream1).listen(msgs1.add);
        server.getMessagesForStream(stream3).listen(msgs3.add);

        await client.sendMessage(
          stream1,
          Uint8List.fromList('a'.codeUnits),
        );
        await client.sendMessage(
          stream3,
          Uint8List.fromList('b'.codeUnits),
        );
        await client.sendMessage(
          stream1,
          Uint8List.fromList('c'.codeUnits),
        );

        await Future.delayed(Duration(milliseconds: 10));

        expect(msgs1.length, equals(2));
        expect(msgs3.length, equals(1));
        expect(String.fromCharCodes(msgs1[0].payload!), equals('a'));
        expect(String.fromCharCodes(msgs1[1].payload!), equals('c'));
        expect(String.fromCharCodes(msgs3[0].payload!), equals('b'));

        await client.close();
        await server.close();
      });
    });

    group('multiplexing', () {
      test('multiple streams interleaved', () async {
        final (client, server) = RpcChannelTransport.pair();
        final received = <RpcTransportMessage>[];
        server.incomingMessages.listen(received.add);

        final s1 = client.createStream();
        final s2 = client.createStream();
        final s3 = client.createStream();

        await client.sendMessage(s1, Uint8List.fromList([1]));
        await client.sendMessage(s2, Uint8List.fromList([2]));
        await client.sendMessage(s3, Uint8List.fromList([3]));
        await client.sendMessage(s1, Uint8List.fromList([4]));
        await client.sendMessage(s2, Uint8List.fromList([5]));

        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(5));
        expect(received[0].streamId, equals(s1));
        expect(received[1].streamId, equals(s2));
        expect(received[2].streamId, equals(s3));
        expect(received[3].streamId, equals(s1));
        expect(received[4].streamId, equals(s2));

        await client.close();
        await server.close();
      });
    });

    group('full RPC cycle', () {
      test('client request and server response', () async {
        final (client, server) = RpcChannelTransport.pair();
        final serverReceived = <RpcTransportMessage>[];
        final clientReceived = <RpcTransportMessage>[];

        server.incomingMessages.listen(serverReceived.add);
        client.incomingMessages.listen(clientReceived.add);

        // Client sends request
        final requestStream = client.createStream();
        await client.sendMetadata(
          requestStream,
          RpcMetadata.forClientRequest('TestService', 'TestMethod'),
        );
        await client.sendMessage(
          requestStream,
          Uint8List.fromList('request body'.codeUnits),
        );
        await client.finishSending(requestStream);

        // Server sends response
        final responseStream = server.createStream();
        await server.sendMetadata(
          responseStream,
          RpcMetadata.forServerInitialResponse(),
        );
        await server.sendMessage(
          responseStream,
          Uint8List.fromList('response body'.codeUnits),
        );
        await server.sendMetadata(
          responseStream,
          RpcMetadata.forTrailer(RpcStatus.ok),
          endStream: true,
        );

        await Future.delayed(Duration(milliseconds: 10));

        // Verify request
        expect(serverReceived.length, equals(3));
        expect(serverReceived[0].metadata?.serviceName, equals('TestService'));
        expect(
          String.fromCharCodes(serverReceived[1].payload!),
          equals('request body'),
        );
        expect(serverReceived[2].isEndOfStream, isTrue);

        // Verify response
        expect(clientReceived.length, equals(3));
        expect(
          String.fromCharCodes(clientReceived[1].payload!),
          equals('response body'),
        );
        expect(clientReceived[2].isEndOfStream, isTrue);

        await client.close();
        await server.close();
      });
    });

    group('close', () {
      test('closes cleanly', () async {
        final (client, server) = RpcChannelTransport.pair();

        await client.close();
        expect(client.isClosed, isTrue);

        await server.close();
        expect(server.isClosed, isTrue);
      });

      test('double close does not throw', () async {
        final (client, server) = RpcChannelTransport.pair();

        await client.close();
        await client.close();

        await server.close();
        await server.close();
      });

      test('closing one side closes the other', () async {
        final (client, server) = RpcChannelTransport.pair();

        await client.close();
        // Channel done triggers server close
        await Future.delayed(Duration(milliseconds: 10));

        expect(server.isClosed, isTrue);
      });
    });

    group('health', () {
      test('returns healthy when active', () async {
        final (client, server) = RpcChannelTransport.pair();

        final status = await client.health();
        expect(status.level, equals(RpcHealthLevel.healthy));
        expect(status.details['activeStreams'], equals(0));

        await client.close();
        await server.close();
      });

      test('returns closed after close', () async {
        final (client, server) = RpcChannelTransport.pair();
        await client.close();

        final status = await client.health();
        expect(status.level, equals(RpcHealthLevel.closed));

        await server.close();
      });

      test('auto-closes when underlying channel closes', () async {
        final c2s = StreamController<Uint8List>();
        final s2c = StreamController<Uint8List>();
        final channel = _TestChannel(output: c2s, input: s2c.stream);
        final transport = RpcChannelTransport.fromChannel(
          channel: channel,
          isClient: true,
        );

        // Close the channel directly (simulating network drop)
        await channel.close();
        await s2c.close();
        await Future.delayed(Duration(milliseconds: 10));

        // Transport auto-closes when channel done fires
        expect(transport.isClosed, isTrue);

        final status = await transport.health();
        expect(status.level, equals(RpcHealthLevel.closed));
      });

      test('reports active stream count', () async {
        final (client, server) = RpcChannelTransport.pair();

        client.createStream();
        client.createStream();

        final status = await client.health();
        expect(status.details['activeStreams'], equals(2));

        await client.close();
        await server.close();
      });
    });

    group('reconnect', () {
      test('returns degraded (not supported)', () async {
        final (client, server) = RpcChannelTransport.pair();

        final status = await client.reconnect();
        expect(status.level, equals(RpcHealthLevel.degraded));
        expect(status.details['supported'], isFalse);

        await client.close();
        await server.close();
      });
    });

    group('error propagation', () {
      test('channel errors are forwarded to incoming stream', () async {
        final c2s = StreamController<Uint8List>();
        final s2c = StreamController<Uint8List>();
        final channel = _TestChannel(output: c2s, input: s2c.stream);
        final transport = RpcChannelTransport.fromChannel(
          channel: channel,
          isClient: true,
        );

        final errors = <Object>[];
        final sub = transport.incomingMessages.listen(
          (_) {},
          onError: errors.add,
        );

        s2c.addError(StateError('network error'));
        await Future.delayed(Duration(milliseconds: 10));

        expect(errors.length, equals(1));
        expect(errors.first, isA<StateError>());

        await sub.cancel();
        await transport.close();
        await s2c.close();
      });
    });

    group('buffer reassembly', () {
      test('reassembles frames split across chunks', () async {
        final c2s = StreamController<Uint8List>();
        final s2c = StreamController<Uint8List>();
        final channel = _TestChannel(output: c2s, input: s2c.stream);
        final transport = RpcChannelTransport.fromChannel(
          channel: channel,
          isClient: true,
        );

        final received = <RpcTransportMessage>[];
        final sub = transport.incomingMessages.listen(received.add);

        // Encode a frame and split it in half
        final frame = RpcChannelFrame.encodeData(
          streamId: 1,
          payload: Uint8List.fromList([10, 20, 30]),
        );
        final mid = frame.length ~/ 2;
        s2c.add(Uint8List.sublistView(frame, 0, mid));
        await Future.delayed(Duration(milliseconds: 5));
        expect(received, isEmpty);

        s2c.add(Uint8List.sublistView(frame, mid));
        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(1));
        expect(
            received.first.payload, equals(Uint8List.fromList([10, 20, 30])));

        await sub.cancel();
        await transport.close();
        await s2c.close();
      });

      test('handles multiple frames in a single chunk', () async {
        final c2s = StreamController<Uint8List>();
        final s2c = StreamController<Uint8List>();
        final channel = _TestChannel(output: c2s, input: s2c.stream);
        final transport = RpcChannelTransport.fromChannel(
          channel: channel,
          isClient: true,
        );

        final received = <RpcTransportMessage>[];
        final sub = transport.incomingMessages.listen(received.add);

        final frame1 = RpcChannelFrame.encodeData(
          streamId: 1,
          payload: Uint8List.fromList([1]),
        );
        final frame2 = RpcChannelFrame.encodeData(
          streamId: 3,
          payload: Uint8List.fromList([2]),
        );
        final combined = Uint8List(frame1.length + frame2.length);
        combined.setRange(0, frame1.length, frame1);
        combined.setRange(frame1.length, combined.length, frame2);

        s2c.add(combined);
        await Future.delayed(Duration(milliseconds: 10));

        expect(received.length, equals(2));
        expect(received[0].streamId, equals(1));
        expect(received[1].streamId, equals(3));

        await sub.cancel();
        await transport.close();
        await s2c.close();
      });
    });
  });
}

/// Minimal channel for testing that lets us control input/output directly.
class _TestChannel implements IRpcChannel {
  final StreamController<Uint8List> _output;
  final StreamController<Uint8List> _inCtl = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;
  bool _closed = false;

  _TestChannel({
    required StreamController<Uint8List> output,
    required Stream<Uint8List> input,
  }) : _output = output {
    _sub = input.listen(
      (data) {
        if (!_inCtl.isClosed) _inCtl.add(data);
      },
      onError: (Object e) {
        if (!_inCtl.isClosed) _inCtl.addError(e);
      },
      onDone: () {
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _inCtl.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed || _output.isClosed) return;
    _output.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    // Fire-and-forget: _output may never have had a subscriber,
    // so its done future would never complete if awaited.
    if (!_output.isClosed) _output.close();
    if (!_inCtl.isClosed) _inCtl.close();
  }
}
