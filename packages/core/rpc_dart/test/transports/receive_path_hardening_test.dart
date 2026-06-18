// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A raw byte channel whose incoming bytes are driven manually from a test.
class _ManualChannel implements IRpcChannel {
  final StreamController<Uint8List> _inCtl = StreamController<Uint8List>();
  bool _closed = false;

  void feed(Uint8List data) {
    if (!_inCtl.isClosed) _inCtl.add(data);
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _inCtl.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_inCtl.isClosed) await _inCtl.close();
  }
}

/// Builds a raw frame header declaring [payloadLen] but carrying only [body].
Uint8List _frameHeader({
  required int streamId,
  required int flags,
  required int payloadLen,
  Uint8List? body,
}) {
  final b = body ?? Uint8List(0);
  final frame = Uint8List(RpcChannelFrame.headerSize + b.length);
  final view = ByteData.sublistView(frame);
  view.setUint32(0, streamId);
  view.setUint8(4, flags);
  view.setUint32(5, payloadLen);
  frame.setRange(RpcChannelFrame.headerSize, frame.length, b);
  return frame;
}

void main() {
  group('BUG 1: oversized declared frame is rejected without buffering', () {
    test('decodeAll throws on a payloadLen above the limit', () {
      // Header declares ~4 GiB; only the 9-byte header is present.
      final header = _frameHeader(
        streamId: 1,
        flags: 0,
        payloadLen: 0xFFFFFFFF,
      );
      expect(
        () => RpcChannelFrame.decodeAll(header, maxPayloadLen: 1024),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('frame channel surfaces a typed error and does not buffer gigabytes',
        () async {
      final channel = _ManualChannel();
      final mux = RpcFrameMultiplexedChannel(
        channel: channel,
        policy: const RpcSecurityPolicy(
          maxMessageLengthBytes: 1024,
          maxBufferedBytes: 4096,
        ),
      );

      final errors = <Object>[];
      final done = Completer<void>();
      mux.incoming.listen(
        (_) {},
        onError: (Object e) {
          errors.add(e);
          if (!done.isCompleted) done.complete();
        },
      );

      // Feed only a header that claims a 100 MB payload. No payload bytes.
      // Must be rejected from the header alone, without allocating 100 MB.
      channel.feed(_frameHeader(
        streamId: 1,
        flags: 0,
        payloadLen: 100 * 1024 * 1024,
      ));

      await done.future.timeout(const Duration(seconds: 2));
      expect(errors, isNotEmpty);
      expect(errors.first, isA<RpcFrameException>());
      expect(mux.isClosed, isTrue);
    });

    test('buffer overflow cap fires before a full huge frame is assembled',
        () async {
      final channel = _ManualChannel();
      final mux = RpcFrameMultiplexedChannel(
        channel: channel,
        // Small message limit but a larger buffer cap so we exercise the
        // buffer-cap path with legitimately-shaped (but oversized) dribbles.
        policy: const RpcSecurityPolicy(
          maxMessageLengthBytes: 16 * 1024,
          maxBufferedBytes: 8 * 1024,
        ),
      );

      final errors = <Object>[];
      final done = Completer<void>();
      mux.incoming.listen(
        (_) {},
        onError: (Object e) {
          errors.add(e);
          if (!done.isCompleted) done.complete();
        },
      );

      // No complete frame yet (header claims more than is present), so the
      // bytes accumulate. Once accumulation passes the buffer cap we must
      // fail rather than keep buffering.
      final partial = _frameHeader(
        streamId: 1,
        flags: 0,
        payloadLen: 16 * 1024,
        body: Uint8List(10 * 1024),
      );
      channel.feed(partial);

      await done.future.timeout(const Duration(seconds: 2));
      expect(errors.single, isA<RpcFrameException>());
      expect(mux.isClosed, isTrue);
    });

    test('legitimate frame within limits still decodes', () async {
      final (client, server) = RpcFrameMultiplexedChannel.pair(
        policy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
      );
      addTearDown(() async {
        await client.close();
        await server.close();
      });

      final received = <RpcTransportMessage>[];
      server.incoming.listen(received.add);

      await client.send(RpcTransportMessage.withPayload(
        payload: Uint8List.fromList([1, 2, 3, 4]),
        streamId: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, hasLength(1));
      expect(received.single.payload, equals([1, 2, 3, 4]));
    });
  });

  group('BUG 2: malformed metadata yields a typed error, not an uncaught throw',
      () {
    const flagMetadata = 1 << 1;

    Uint8List metaFrame(List<int> jsonBytes) => _frameHeader(
          streamId: 1,
          flags: flagMetadata,
          payloadLen: jsonBytes.length,
          body: Uint8List.fromList(jsonBytes),
        );

    test('top-level JSON array is rejected', () {
      final body = utf8.encode('[1,2,3]');
      expect(
        () => RpcChannelFrame.decodeAll(metaFrame(body)),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('malformed JSON is rejected', () {
      final body = utf8.encode('{not valid json');
      expect(
        () => RpcChannelFrame.decodeAll(metaFrame(body)),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('invalid UTF-8 is rejected', () {
      final body = <int>[0xFF, 0xFE, 0xFD];
      expect(
        () => RpcChannelFrame.decodeAll(metaFrame(body)),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('non-string header value is rejected', () {
      final body = utf8.encode(json.encode({
        'h': [
          ['x', 1],
        ],
      }));
      expect(
        () => RpcChannelFrame.decodeAll(metaFrame(body)),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('header entry with wrong arity is rejected', () {
      final body = utf8.encode(json.encode({
        'h': [
          ['only-one'],
        ],
      }));
      expect(
        () => RpcChannelFrame.decodeAll(metaFrame(body)),
        throwsA(isA<RpcFrameException>()),
      );
    });

    test('malformed metadata over the channel surfaces a clean typed error',
        () async {
      final channel = _ManualChannel();
      final mux = RpcFrameMultiplexedChannel(channel: channel);

      final errors = <Object>[];
      final done = Completer<void>();
      mux.incoming.listen(
        (_) {},
        onError: (Object e) {
          errors.add(e);
          if (!done.isCompleted) done.complete();
        },
      );

      channel.feed(metaFrame(utf8.encode('[1,2,3]')));

      await done.future.timeout(const Duration(seconds: 2));
      expect(errors.single, isA<RpcFrameException>());
      expect(mux.isClosed, isTrue);
    });

    test('well-formed metadata still decodes', () {
      final body = utf8.encode(json.encode({
        'p': '/svc/Method',
        'h': [
          ['k', 'v'],
        ],
      }));
      final (frames, _) = RpcChannelFrame.decodeAll(metaFrame(body));
      expect(frames, hasLength(1));
      expect(frames.single.metadata, isNotNull);
      expect(frames.single.methodPath, equals('/svc/Method'));
    });
  });

}
