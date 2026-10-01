// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcHttp2OutgoingPump` holds a send while the peer's window is closed, so the
// whole request does not settle in package:http2's outgoing queue. Two ways that
// parked send used to disappear, both reporting success to the caller:
//
//   - a half-close arriving meanwhile added END_STREAM and closed the sink under
//     the parked `add`, which then returned normally with its payload dropped;
//   - disposing the pump did the same.
//
// Silent request truncation either way — the class B-74 fixed in core. A send that
// did not reach the peer must not read as success, so a half-close now waits for
// parked payload and an undeliverable `add` throws.
//
// The peer's closed window is stood in for by a sink nothing drains: the pump parks
// because `addStream`'s subscription is paused, which is not http2-specific.
@TestOn('vm')
library;

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';
import 'package:test/test.dart';

/// A stream whose outgoing sink only drains once [drain] is called.
final class _StalledStream implements http2.ClientTransportStream {
  final _ctl = StreamController<http2.StreamMessage>();
  final seen = <String>[];

  void drain() {
    _ctl.stream.listen((m) {
      seen.add(
        m is http2.DataStreamMessage
            ? 'data ${m.bytes.length}B eos=${m.endStream}'
            : 'headers eos=${m.endStream}',
      );
    });
  }

  @override
  StreamSink<http2.StreamMessage> get outgoingMessages => _ctl.sink;

  @override
  Stream<http2.StreamMessage> get incomingMessages => const Stream.empty();

  @override
  Stream<http2.TransportStreamPush> get peerPushes => const Stream.empty();

  @override
  int get id => 1;

  @override
  set onTerminated(void Function(int?) value) {}

  @override
  void terminate() {}

  @override
  void sendData(List<int> bytes, {bool endStream = false}) {
    _ctl.sink.add(
      http2.DataStreamMessage(Uint8List.fromList(bytes), endStream: endStream),
    );
    if (endStream) _ctl.sink.close();
  }

  @override
  void sendHeaders(List<http2.Header> headers, {bool endStream = false}) {
    _ctl.sink.add(http2.HeadersStreamMessage(headers, endStream: endStream));
    if (endStream) _ctl.sink.close();
  }
}

typedef _Ended = ({bool returned, Object? threw});

/// Starts one `add` on a pump whose window is closed and reports how it ended.
({RpcHttp2OutgoingPump pump, _StalledStream stream, Future<_Ended> ended})
_park() {
  final stream = _StalledStream();
  final pump = RpcHttp2OutgoingPump(stream);
  final ended = (() async {
    try {
      await pump.add(http2.DataStreamMessage(Uint8List(64)));
      return (returned: true, threw: null);
    } catch (e) {
      return (returned: false, threw: e);
    }
  })();
  return (pump: pump, stream: stream, ended: ended);
}

void main() {
  test('CONTROL an open window sends payload then END_STREAM', () async {
    // Without this the witnesses below cannot distinguish "the payload was
    // dropped" from "this rig never delivers payload".
    final stream = _StalledStream()..drain();
    final pump = RpcHttp2OutgoingPump(stream);

    await pump.add(http2.DataStreamMessage(Uint8List(64)));
    pump.endStreamNow();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(stream.seen, ['data 64B eos=false', 'data 0B eos=true']);
  });

  test('WITNESS a half-close does not overtake a parked send', () async {
    final rig = _park();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    rig.pump.endStreamNow();
    // The window opens only now, which is what makes this a parked send rather
    // than a slow one.
    rig.stream.drain();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      rig.stream.seen,
      ['data 64B eos=false', 'data 0B eos=true'],
      reason: 'the payload was queued first, so it must reach the wire first',
    );
    final ended = await rig.ended;
    expect(ended.returned, isTrue);
    expect(ended.threw, isNull);
  });

  test('WITNESS a disposed pump FAILS the parked send', () async {
    final rig = _park();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The owner is about to close or terminate the stream, so the payload really
    // cannot go — but the caller has to learn that.
    rig.pump.dispose();
    rig.stream.drain();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(rig.stream.seen, isEmpty);
    final ended = await rig.ended;
    expect(
      ended.returned,
      isFalse,
      reason: 'returning normally told the caller a dropped payload was sent',
    );
    expect(
      ended.threw,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.unavailable,
      ),
    );
  });

  test('GUARD an end-of-stream message still ends the stream itself', () async {
    // `add` with endStream set is the ordinary half-close, and it must not be
    // affected by the parked-payload path.
    final stream = _StalledStream()..drain();
    final pump = RpcHttp2OutgoingPump(stream);

    await pump.add(http2.DataStreamMessage(Uint8List(8), endStream: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(stream.seen, ['data 8B eos=true']);
  });
}
