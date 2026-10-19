// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

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

    test(
      'frame channel surfaces a typed error and does not buffer gigabytes',
      () async {
        // Default construction is the SERVER side, which still closes: the peak
        // is already resident when this class is handed the message, so refusing
        // to let the peer repeat it is the only lever. A CLIENT answers the same
        // frame with RESOURCE_EXHAUSTED and stays connected -- see
        // transports/oversized_frame_is_per_call_test.dart.
        final channel = RawPeerChannel();
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
        channel.feed(
          _frameHeader(streamId: 1, flags: 0, payloadLen: 100 * 1024 * 1024),
        );

        await done.future.timeout(const Duration(seconds: 2));
        expect(errors, isNotEmpty);
        expect(errors.first, isA<RpcFrameException>());
        expect(mux.isClosed, isTrue);
      },
    );

    test(
      'buffer overflow cap fires before a full huge frame is assembled',
      () async {
        final channel = RawPeerChannel();
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
      },
    );

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

      await client.send(
        RpcTransportMessage.withPayload(
          payload: Uint8List.fromList([1, 2, 3, 4]),
          streamId: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, hasLength(1));
      expect(received.single.payload, equals([1, 2, 3, 4]));
    });
  });

  group(
    'BUG 2: malformed metadata yields a typed error, not an uncaught throw',
    () {
      const flagMetadata = 1 << 1;

      Uint8List metaFrame(List<int> body) => _frameHeader(
        streamId: 1,
        flags: flagMetadata,
        payloadLen: body.length,
        body: Uint8List.fromList(body),
      );

      // One well-formed payload: path '/a', one header k: v.
      const wellFormed = [3, 0x2F, 0x61, 1, 1, 0x6B, 1, 0x76];

      final malformed = <String, List<int>>{
        'an empty payload': [],
        'a length cut off inside its varint': [0x80],
        'a varint longer than five bytes': [0x80, 0x80, 0x80, 0x80, 0x80, 0],
        'a varint of 2^32 or more': [0x80, 0x80, 0x80, 0x80, 0x10],
        'a path longer than the frame': [10, 0x2F],
        'a header count past the bytes left': [0, 100, 1, 0x6B],
        'a header value longer than the frame': [0, 1, 1, 0x6B, 9, 0x76],
        'bytes after the last header': [...wellFormed, 0],
        'invalid UTF-8 in a value': [0, 1, 1, 0x6B, 2, 0xFF, 0xFE],
      };
      for (final MapEntry(key: what, value: body) in malformed.entries) {
        test('$what is rejected', () {
          expect(
            () => RpcChannelFrame.decodeAll(metaFrame(body)),
            throwsA(isA<RpcFrameException>()),
          );
        });
      }

      test(
        'malformed metadata over the channel surfaces a clean typed error',
        () async {
          final channel = RawPeerChannel();
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

          channel.feed(metaFrame([10, 0x2F]));

          await done.future.timeout(const Duration(seconds: 2));
          expect(errors.single, isA<RpcFrameException>());
          expect(mux.isClosed, isTrue);
        },
      );

      test('well-formed metadata still decodes', () {
        final (frames, _) = RpcChannelFrame.decodeAll(metaFrame(wellFormed));
        expect(frames, hasLength(1));
        expect(frames.single.methodPath, equals('/a'));
        final headers = frames.single.metadata!.headers;
        expect(headers.single.name, 'k');
        expect(headers.single.value, 'v');
      });

      test('what the encoder writes decodes back unchanged', () {
        final metadata = RpcMetadata([
          const RpcHeader('x-plain', 'value'),
          RpcHeader('x-long', 'Ж' * 200),
          const RpcHeader('x-empty', ''),
        ], methodPath: '/Сервис/Метод');
        final (frames, consumed) = RpcChannelFrame.decodeAll(
          RpcChannelFrame.encodeMetadata(streamId: 7, metadata: metadata),
        );
        final decoded = frames.single;
        expect(consumed, greaterThan(RpcChannelFrame.headerSize));
        expect(decoded.streamId, 7);
        expect(decoded.methodPath, '/Сервис/Метод');
        expect(
          [for (final h in decoded.metadata!.headers) '${h.name}=${h.value}'],
          ['x-plain=value', 'x-long=${'Ж' * 200}', 'x-empty='],
        );
      });
    },
  );

  group('BUG 3: the buffer cap bounds what is ALLOCATED, not only retained', () {
    // _onData used to append the chunk and THEN consult the cap, so an
    // oversized chunk was allocated in full and copied before the limit that
    // exists to prevent exactly that fired. Measured with a 16 MiB policy limit
    // and one 256 MiB chunk: 256.2 MiB allocated, versus 0.1 MiB after the fix.
    //
    // The chunk size is peer-controlled on the transport this matters most for:
    // dart:io's WebSocket has no message-size limit and delivers one message as
    // ONE chunk -- measured at 96 MiB arriving whole -- so any unauthenticated
    // peer could make a server allocate an arbitrary multiple of its own
    // configured ceiling before being disconnected for it.

    // The resident-set witness lives in oversized_chunk_not_copied_test.dart:
    // it needs dart:io's ProcessInfo, and this file also runs on dart2js.

    test('GUARD: a chunk of exactly the cap is still accepted', () async {
      // Off-by-one guard for moving the check ahead of the append. The cap is
      // `maxBufferedBytes + headerSize`, and a chunk of exactly that size must
      // still buffer -- rejecting it would break reassembly of a legitimate
      // frame that happens to fill the budget.
      const bufferedBytes = 8 * 1024;
      final capBytes = bufferedBytes + RpcChannelFrame.headerSize;

      final channel = RawPeerChannel();
      final mux = RpcFrameMultiplexedChannel(
        channel: channel,
        policy: const RpcSecurityPolicy(
          maxMessageLengthBytes: 64 * 1024,
          maxBufferedBytes: bufferedBytes,
        ),
      );
      addTearDown(mux.close);

      final errors = <Object>[];
      mux.incoming.listen((_) {}, onError: errors.add);

      // A frame header declaring more than is present, so nothing is consumed
      // and the whole chunk stays buffered.
      channel.feed(
        _frameHeader(
          streamId: 1,
          flags: 0,
          payloadLen: 64 * 1024,
          body: Uint8List(capBytes - RpcChannelFrame.headerSize),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(errors, isEmpty, reason: 'exactly at the cap is within the cap');
      expect(mux.isClosed, isFalse);

      // One byte past it must fail.
      channel.feed(Uint8List(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(errors.single, isA<RpcFrameException>());
    });

    test('GUARD: the reported byte count is the same total as before', () async {
      // The old message printed `_bufLen` AFTER appending; the new one prints
      // `_bufLen + chunk.length` before. Same number -- pinned so a future
      // refactor cannot quietly start reporting only the chunk.
      final channel = RawPeerChannel();
      final mux = RpcFrameMultiplexedChannel(
        channel: channel,
        policy: const RpcSecurityPolicy(
          maxMessageLengthBytes: 64 * 1024,
          maxBufferedBytes: 100,
        ),
      );
      addTearDown(mux.close);

      final errors = <Object>[];
      final done = Completer<void>();
      mux.incoming.listen(
        (_) {},
        onError: (Object e) {
          errors.add(e);
          if (!done.isCompleted) done.complete();
        },
      );

      // 40 bytes buffered, then 200 more: the report must name 240, the total.
      channel.feed(
        _frameHeader(
          streamId: 1,
          flags: 0,
          payloadLen: 64 * 1024,
          body: Uint8List(40 - RpcChannelFrame.headerSize),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      channel.feed(Uint8List(200));

      await done.future.timeout(const Duration(seconds: 5));
      expect(errors.single.toString(), contains('240 bytes'));
    });
  });
}
