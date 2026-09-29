// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `_decodeAt` checked the metadata size limit BELOW the completeness check, so an
// incomplete frame returned null and the caller kept buffering. The limit only
// fired once the payload had fully arrived — and both of its inputs (the metadata
// flag and the declared length) are header fields, so there was never anything to
// wait for.
//
// Declared payload 10 MiB, which sits between the two ceilings: over
// maxMetadataBytes (64 KiB) and under maxFramedMessageBytes (16 MiB). Fed in
// 64 KiB chunks, one microtask turn apart, counting bytes accepted before the
// refusal:
//
//                                  before        after
//   METADATA flag set              10485769      9        <- the header alone
//   data frame, same size          10485769      10485769 <- control, legal
//
// 9 bytes is the header. The server side is the one that matters:
// `closeOnOversizedFrame: true` is its default, and that is exactly the setting
// under which `_refusedFrameHeader`'s early check deliberately does nothing.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A channel whose inbound bytes the test writes by hand.
final class _Pipe implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }

  void feed(Uint8List chunk) {
    if (!_ctl.isClosed) _ctl.add(chunk);
  }
}

Uint8List _header({
  required int streamId,
  required bool metadata,
  required int payloadLen,
}) {
  final h = Uint8List(RpcChannelFrame.headerSize);
  final view = ByteData.sublistView(h);
  view.setUint32(0, streamId);
  view.setUint8(4, metadata ? RpcChannelFrame.flagMetadata : 0);
  view.setUint32(5, payloadLen);
  return h;
}

const int _declared = 10 * 1024 * 1024;
const int _chunk = 64 * 1024;

/// Dribbles a frame in and returns how many bytes were accepted before the
/// channel refused it, with the refusal message.
Future<({int accepted, String? refusal})> _dribble({
  required bool metadata,
}) async {
  final pipe = _Pipe();
  final channel = RpcFrameMultiplexedChannel(channel: pipe);
  addTearDown(() async {
    await pipe.close();
    await channel.close();
  });

  Object? failure;
  channel.incoming.listen((_) {}, onError: (Object e) => failure ??= e);

  var fed = 0;
  pipe.feed(_header(streamId: 1, metadata: metadata, payloadLen: _declared));
  fed += RpcChannelFrame.headerSize;
  await Future<void>.delayed(Duration.zero);

  final body = Uint8List(_chunk);
  while (failure == null && fed < _declared) {
    pipe.feed(body);
    fed += _chunk;
    // One turn per chunk so the refusal can land before the next write.
    // Without this the loop outruns the decoder and the count measures the
    // writer rather than the buffer.
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 50));

  return (
    accepted: fed,
    refusal: failure == null ? null : (failure! as RpcFrameException).message,
  );
}

void main() {
  test(
    'WITNESS: an oversized metadata frame is refused from its header',
    () async {
      final out = await _dribble(metadata: true);

      expect(
        out.accepted,
        RpcChannelFrame.headerSize,
        reason:
            'the flag and the declared length are both header fields, so nothing '
            'had to be buffered; checking the limit below the completeness check '
            'held all 10 MiB first — 160x the 64 KiB ceiling',
      );
      expect(out.refusal, contains('metadata frame too large'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a data frame of the same size is still accepted in full',
    () async {
      // The declared size is legal without the metadata flag — under
      // maxFramedMessageBytes. Without this arm a small "accepted" figure above
      // could mean the rig cannot feed 10 MiB at all, and the witness would pass
      // against a channel that refuses everything.
      final out = await _dribble(metadata: false);

      expect(out.refusal, isNull);
      expect(out.accepted, greaterThanOrEqualTo(_declared));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a metadata frame within the limit still decodes',
    () async {
      // Moving a limit check earlier is one edit from moving it to where it refuses
      // everything. This drives a real, legal metadata frame all the way through.
      final pipe = _Pipe();
      final channel = RpcFrameMultiplexedChannel(channel: pipe);
      addTearDown(() async {
        await pipe.close();
        await channel.close();
      });

      final received = <RpcTransportMessage>[];
      channel.incoming.listen(received.add);

      pipe.feed(
        RpcChannelFrame.encodeMetadata(
          streamId: 7,
          metadata: RpcMetadata.forClientRequest('Svc', 'method'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received.single.metadata?.methodPath, '/Svc/method');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
