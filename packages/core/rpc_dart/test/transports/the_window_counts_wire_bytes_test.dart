// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `flowControlWindowBytes` charges the bytes a message occupies ON THE WIRE, and
// nothing else: not the message count, and not whatever the decoded object
// weighs. So the same window admits a few large messages or very many small
// ones, and a type that expands on decode turns one window's worth of wire bytes
// into an arbitrarily larger backlog above the transport.
//
// Both halves are witnessed here because an operator reads the field as a bound
// on memory. The arm that holds the wire size fixed and varies only the decoded
// size is the one that shows the window cannot see the difference.
//
// A paused consumer is what engages it at all: the pause reaches the transport,
// credit stops being returned, and the sender parks within one message of the
// window. Resuming releases it — if it did not, this would be a wedge rather
// than a bound.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A message whose WIRE size and DECODED size are set independently: [wire] is
/// padding that is serialized, [payload] is a length the receiver would
/// allocate.
final class _Blob implements IRpcSerializable {
  _Blob(this.wire, this.payload);

  final String wire;
  final int payload;

  @override
  Map<String, dynamic> toJson() => {'w': wire, 'n': payload};

  static _Blob fromJson(Map<String, dynamic> json) =>
      _Blob(json['w'] as String, json['n'] as int);
}

const _codec = RpcCodec<_Blob>(_Blob.fromJson);
const _kib = 1024;

final class _Firehose extends RpcResponderContract {
  _Firehose(this._produced, this._wire, this._payload) : super('Svc');

  final List<int> _produced;
  final int _wire;
  final int _payload;

  @override
  void setup() {
    final padding = 'x' * _wire;
    addServerStreamMethod<RpcString, _Blob>(
      methodName: 'firehose',
      requestCodec: const RpcCodec(RpcString.fromJson),
      responseCodec: _codec,
      handler: (req, {context}) async* {
        while (true) {
          yield _Blob(padding, _payload);
          _produced[0]++;
          await Future<void>.delayed(Duration.zero);
        }
      },
    );
  }
}

typedef _Run = ({
  int first,
  int second,
  int received,
  Map<String, int> senderState,
});

/// Runs a firehose into a consumer that pauses after one message, and reports
/// what the producer reached after one settle and after two.
///
/// Equal counts mean the producer is BOUNDED; a second larger than the first
/// means it is merely being timed.
Future<_Run> _run({
  required int? window,
  required int wire,
  int payload = _kib,
  bool resume = false,
  Duration settle = const Duration(milliseconds: 250),
}) async {
  final produced = [0];
  final (client, server) = RpcChannelTransport.pair(
    policy: RpcSecurityPolicy(
      flowControlWindowBytes: window,
      // Both off, so a single field is under test. The connection pool would
      // bound the same traffic at its own number, and the initial send window
      // bounds a sender until the peer's first grant — set to the window under
      // test it would pass every arm below whether or not the window works.
      flowControlConnectionWindowBytes: null,
      initialSendWindowBytes: null,
      // Lifted: round 550's depth ceiling would bind first and this test would
      // measure that field instead.
      maxBufferedMessagesPerStream: 1 << 30,
    ),
  );
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Firehose(produced, wire, payload)..setup())
    ..start();
  final caller = RpcCallerEndpoint(transport: client);

  var received = 0;
  final sub = caller
      .serverStream<RpcString, _Blob>(
        serviceName: 'Svc',
        methodName: 'firehose',
        request: 'go'.rpc,
        requestCodec: const RpcCodec(RpcString.fromJson),
        responseCodec: _codec,
      )
      .listen(null);
  sub.onData((_) {
    received++;
    if (received == 1) sub.pause();
  });
  sub.onError((Object _) {});

  await Future<void>.delayed(settle);
  final first = produced[0];
  // `server` IS the sender: a server stream flows responder -> caller, so its
  // own credit map is what bounds it.
  final senderState = server.flowControlStateSizes;
  if (resume) sub.resume();
  await Future<void>.delayed(settle);
  final second = produced[0];

  await sub.cancel();
  await caller.close();
  await responder.close();
  return (
    first: first,
    second: second,
    received: received,
    senderState: senderState,
  );
}

void main() {
  test(
    'WITNESS a half-closed request does not end the response\'s window',
    () async {
      // A server stream half-closes its request immediately, and that inbound
      // end-of-stream used to drop the whole stream's flow-control state on the
      // responder — which is the SENDER of the response. With the state gone, a
      // grant for that id reads as one for a call that has ended and is discarded,
      // so the window could never be re-established and the only credit a stream
      // ever had was what `initialSendWindowBytes` seeded.
      final r = await _run(window: 64 * _kib, wire: _kib);

      expect(
        r.senderState['advertised'],
        1,
        reason:
            'the responder advertised its window for this stream and the call is '
            'still live in the sending direction',
      );
      expect(
        r.senderState['sendCredit'],
        1,
        reason: 'no credit entry means the window was never applied at all',
      );
      expect(
        r.senderState['waiters'],
        1,
        reason: 'the sender must be parked on the window, not running free',
      );
    },
  );

  test(
    'WITNESS the window bounds un-consumed WIRE bytes, to one message',
    () async {
      const window = 64 * _kib;
      final r = await _run(window: window, wire: _kib);

      expect(
        r.second,
        r.first,
        reason:
            'a bound does not move when the producer is given twice as long; if '
            'this grows, the window is not what stopped it',
      );
      // One message of slack: a send is admitted whenever ANY credit remains, so
      // the last one crosses a window that cannot fit it.
      expect(
        r.first * _kib,
        inInclusiveRange(window - 2 * _kib, window + 2 * _kib),
        reason:
            'the un-consumed wire bytes must be the window itself, not a multiple '
            'of it: ${r.first} messages of 1 KiB against a $window-byte window',
      );
    },
  );

  test('WITNESS the bound tracks the configured value', () async {
    // The witness above passes for any fixed ceiling. This is what ties the
    // number the operator sets to the number they get.
    final small = await _run(window: 64 * _kib, wire: _kib);
    final large = await _run(window: 512 * _kib, wire: _kib);

    expect(large.second, greaterThan(small.second * 6));
    expect(large.second, lessThan(small.second * 10));
  });

  test('WITNESS the window cannot see what a message decodes to', () async {
    // Same wire size, 16x the decoded size. The message COUNT is unchanged, so
    // the backlog above the transport is 16x for one unchanged window — which is
    // the half of this field an operator is most likely to read as memory.
    final lean = await _run(window: 64 * _kib, wire: _kib);
    final fat = await _run(window: 64 * _kib, wire: _kib, payload: 16 * _kib);

    expect(
      fat.second,
      inInclusiveRange(lean.second - 2, lean.second + 2),
      reason:
          'the window charges the wire payload, so a 16x larger decoded object '
          'must not change how many are admitted',
    );
  });

  test('CONTROL with no window the producer is not bounded at all', () async {
    // Without this the witnesses would also pass against a transport that had
    // simply stopped. A 1-byte wire payload keeps the unbounded arm cheap.
    final r = await _run(window: null, wire: 1);

    expect(
      r.second,
      greaterThan((r.first * 1.5).round()),
      reason: 'with the field off, more time must buy more messages',
    );
  });

  test('CONTROL resuming the consumer releases the producer', () async {
    // A bound that never releases is a wedge, and the witness above cannot tell
    // the two apart.
    final r = await _run(window: 64 * _kib, wire: _kib, resume: true);

    expect(r.second, greaterThan(r.first * 4));
    expect(r.received, greaterThan(r.first));
  });
}
