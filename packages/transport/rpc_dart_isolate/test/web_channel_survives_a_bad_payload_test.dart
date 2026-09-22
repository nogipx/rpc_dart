// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-31. Round 310 fixed a real defect in the web channel's send: a payload that
// cannot be structured-cloned closed the WHOLE channel, killing every other
// in-flight call, and `catch (_)` dropped the reason so the caller saw
// UNAVAILABLE. The fix was analyser-verified and sibling-verified and had no
// test, because the class lived in a file that opens with `dart:js_interop`:
// unimportable on the VM, and needing a real Worker on the web.
//
// It lives in `web_bridge.dart` now, which imports no JS library, so a stub
// `send` reaches the defect with no Worker at all.
//
// BOTH halves are asserted, because either alone passes on a wrong fix:
//   - the failing send reports a NAMED error, not a swallowed one;
//   - a second call on the same channel still completes.

// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

/// Stands in for `postMessage` refusing a payload it cannot structured-clone.
///
/// Throws for the frame on [failStreamId] and records everything else, which is
/// what lets the test see that the other calls still got through.
class _CloneRefusingSend {
  _CloneRefusingSend(this.failStreamId);

  final int failStreamId;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  void call(Map<String, Object?> data) {
    if (data['streamId'] == failStreamId) {
      throw ArgumentError('could not be cloned');
    }
    sent.add(data);
  }
}

RpcTransportMessage _payloadOn(int streamId) => RpcTransportMessage(
  streamId: streamId,
  payload: Uint8List.fromList(const [1, 2, 3]),
);

void main() {
  group('a payload the worker cannot clone', () {
    late StreamController<dynamic> inbound;
    late _CloneRefusingSend send;
    late WebMultiplexedChannel channel;

    setUp(() {
      inbound = StreamController<dynamic>();
      send = _CloneRefusingSend(7);
      channel = WebMultiplexedChannel(
        messageStream: inbound.stream,
        send: send.call,
      );
    });

    tearDown(() async {
      await channel.close();
      await inbound.close();
    });

    test('WITNESS: the caller is told WHAT went wrong', () async {
      await expectLater(
        channel.send(_payloadOn(7)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(
              contains('stream 7'),
              contains('structured-cloned'),
              contains('could not be cloned'),
            ),
          ),
        ),
        reason:
            'swallowing the reason reports this as UNAVAILABLE, which is a '
            'claim about the worker rather than about the payload',
      );
    });

    test('WITNESS: the other calls on the channel survive it', () async {
      await channel.send(_payloadOn(3));
      await channel.send(_payloadOn(7)).catchError((Object _) {});
      await channel.send(_payloadOn(5));

      expect(
        channel.isClosed,
        isFalse,
        reason:
            'one bad payload closed the channel, taking every other in-flight '
            'call with it',
      );
      expect(
        send.sent.map((frame) => frame['streamId']).toList(),
        [3, 5],
        reason: 'the frames either side of the refusal must still be sent',
      );
    });

    test('WITNESS: the channel still RECEIVES after a refused send', () async {
      final seen = <int>[];
      channel.incoming.listen((message) => seen.add(message.streamId));

      await channel.send(_payloadOn(7)).catchError((Object _) {});
      inbound.add(
        BridgeMessage(
          type: BridgeType.data,
          streamId: 9,
          payload: const [1, 2, 3],
        ).toMap(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen, [9], reason: 'the inbound half was torn down with it');
    });

    // GUARD: refusing to close on a SEND failure must not stop the channel
    // closing when it is told to. Either half alone passes on a wrong fix.
    test('GUARD: an explicit close still closes', () async {
      await channel.close();
      expect(channel.isClosed, isTrue);
    });

    // GUARD: the peer's close frame still closes it, which is the path that
    // must keep working for a worker that shuts down normally.
    test('GUARD: the peer closing still closes', () async {
      inbound.add(BridgeMessage(type: BridgeType.close, streamId: 0).toMap());
      await Future<void>.delayed(Duration.zero);
      expect(channel.isClosed, isTrue);
    });
  });
}
