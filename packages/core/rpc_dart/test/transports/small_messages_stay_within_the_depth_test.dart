// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The receiver bounds a stream's queue by depth (`maxBufferedMessagesPerStream`)
// as well as by bytes, and a sender paced by the byte window alone could not see
// the depth. 4 MiB of ten-byte messages is far deeper than any depth, so a sender
// obeying its window failed the stream with RESOURCE_EXHAUSTED -- on websocket,
// every server stream of small items to a consumer slower than the producer.
//
// The depth is now granted as message credit beside the bytes. The witness is a
// channel that hands bytes over the way a socket read does: up to 64 KiB per
// event-loop task, every frame in it parsed before the consumer runs.
//
// The unit half pins the two rules that make the credit safe to ship: the
// peer's first grant replaces the seed rather than adding to it, and a peer
// that grants bytes alone is not stalled by message credit it never returns.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/rpc/transports/flow_controller.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Echo');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Count',
      handler: (r, {RpcContext? context}) async* {
        final n = int.parse(r.value);
        for (var i = 0; i < n; i++) {
          yield 'i$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One end of a byte pipe that flushes what has been sent once per event-loop
/// task, as one chunk of up to [_chunkBytes].
final class _ChunkedChannel implements IRpcChannel {
  static const _chunkBytes = 64 * 1024;

  late _ChunkedChannel peer;
  final _in = StreamController<Uint8List>();
  final _pending = BytesBuilder(copy: true);
  bool _scheduled = false;

  @override
  bool get isClosed => false;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    _pending.add(data);
    if (!_scheduled) {
      _scheduled = true;
      Timer.run(_flush);
    }
  }

  void _flush() {
    _scheduled = false;
    final all = _pending.takeBytes();
    if (all.isEmpty) return;
    final n = all.length < _chunkBytes ? all.length : _chunkBytes;
    if (n < all.length) {
      _pending.add(Uint8List.sublistView(all, n));
      _scheduled = true;
      Timer.run(_flush);
    }
    peer._in.add(Uint8List.fromList(Uint8List.sublistView(all, 0, n)));
  }

  @override
  Future<void> close() async {}
}

/// Streams [count] small items to a consumer that spends [perItem] on each,
/// and reports how many arrived and what ended the stream.
Future<({int received, Object? error})> _stream(
  int count, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
  Duration? perItem,
}) async {
  final a = _ChunkedChannel();
  final b = _ChunkedChannel();
  a.peer = b;
  b.peer = a;
  final responder = RpcResponderEndpoint(
    transport: RpcChannelTransport.fromChannel(
      channel: b,
      isClient: false,
      policy: policy,
    ),
  )..registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport.fromChannel(
      channel: a,
      isClient: true,
      policy: policy,
    ),
  );
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  var received = 0;
  Object? error;
  try {
    await for (final _ in caller.serverStream<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'Count',
      request: '$count'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )) {
      received++;
      if (perItem != null) await Future<void>.delayed(perItem);
    }
  } catch (e) {
    error = e;
  }
  return (received: received, error: error);
}

/// An inbound per-stream grant carrying [bytes] and, when given, [messages].
RpcTransportMessage _grant(int streamId, int bytes, [int? messages]) =>
    RpcTransportMessage.withMetadata(
      streamId: streamId,
      metadata: RpcMetadata([
        RpcHeader(RpcHeaders.xWindowUpdate, '$bytes'),
        if (messages != null)
          RpcHeader(RpcHeaders.xWindowUpdateMessages, '$messages'),
      ]),
    );

/// A depth the 64 KiB chunks below exceed in one burst, so what is measured
/// does not depend on the default.
const _depth = RpcSecurityPolicy(maxBufferedMessagesPerStream: 1024);

void main() {
  group('over a channel that delivers 64 KiB per task', () {
    test('WITNESS 10000 small items reach a fast consumer', () async {
      final r = await _stream(10000, policy: _depth);

      expect(r.error, isNull);
      expect(r.received, 10000);
    });

    test('WITNESS a slow consumer gets every item', () async {
      final r = await _stream(
        1500,
        policy: _depth,
        perItem: const Duration(microseconds: 300),
      );

      expect(r.error, isNull);
      expect(r.received, 1500);
    });

    test('GUARD the depth still binds a sender without flow control', () async {
      // Both ends without a window: nothing grants and nothing parks, so the
      // depth is the only bound left, and it must still fire.
      final r = await _stream(
        10000,
        policy: const RpcSecurityPolicy(
          maxBufferedMessagesPerStream: 1024,
          flowControlWindowBytes: null,
          flowControlConnectionWindowBytes: null,
        ),
      );

      expect(
        r.error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.resourceExhausted,
        ),
      );
    });
  });

  group('message credit', () {
    final frames = <RpcMetadata>[];
    RpcFlowController build({int depth = 8}) => RpcFlowController(
      policy: RpcSecurityPolicy(maxBufferedMessagesPerStream: depth),
      send: (_, metadata) async => frames.add(metadata),
      isStreamLive: (_) => true,
    );

    setUp(frames.clear);

    test('the seed is this side\'s depth', () {
      final fc = build();

      for (var i = 0; i < 8; i++) {
        expect(fc.tryConsume(1, 1), isTrue);
      }
      expect(fc.tryConsume(1, 1), isFalse);
    });

    test('the first grant replaces the seed, less what was sent', () {
      final fc = build();
      for (var i = 0; i < 6; i++) {
        fc.tryConsume(1, 1);
      }

      fc.handleInbound(_grant(1, 1000, 8));

      // Added to the seed this would be 8 (clamped from 10), and the peer,
      // already holding 6, would be sent 14.
      expect(fc.messageCreditFor(1), 2);
    });

    test('later grants add', () {
      final fc = build();
      fc.handleInbound(_grant(1, 1000, 8));
      for (var i = 0; i < 6; i++) {
        fc.tryConsume(1, 1);
      }

      fc.handleInbound(_grant(1, 1000, 4));

      expect(fc.messageCreditFor(1), 6);
    });

    test('a grant of bytes alone releases a sender parked on messages', () {
      // A peer that paces bytes and predates message credit never returns it,
      // so the seed would run out for good.
      final fc = build();
      for (var i = 0; i < 8; i++) {
        fc.tryConsume(1, 1);
      }
      expect(fc.tryConsume(1, 1), isFalse);

      fc.handleInbound(_grant(1, 1000));

      expect(fc.messageCreditFor(1), isNull);
      expect(fc.tryConsume(1, 1), isTrue);
      expect(fc.tryConsume(2, 1), isTrue, reason: 'nor seeded for new streams');
      expect(fc.messageCreditFor(2), isNull);
    });

    test('a direct object takes message credit and no bytes', () {
      final fc = build(depth: 2);
      fc.handleInbound(_grant(1, 10, 2));

      expect(fc.tryConsume(1, 0, direct: true), isTrue);
      expect(fc.tryConsume(1, 0, direct: true), isTrue);
      expect(fc.tryConsume(1, 0, direct: true), isFalse);
      expect(fc.creditFor(1), 10);
    });

    test('every grant frame carries both dimensions', () {
      final fc = build(depth: 4);
      fc.advertiseStream(1);
      fc.credit(1, 0, messages: 2);

      expect(frames, hasLength(2));
      for (final f in frames) {
        expect(f.getHeaderValue(RpcHeaders.xWindowUpdate), isNotNull);
        expect(f.getHeaderValue(RpcHeaders.xWindowUpdateMessages), isNotNull);
      }
      expect(frames.last.getHeaderValue(RpcHeaders.xWindowUpdateMessages), '2');
      expect(frames.last.getHeaderValue(RpcHeaders.xWindowUpdate), '0');
    });
  });
}
