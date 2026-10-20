// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A web worker is a separately compiled script a browser may cache. The host
// and the worker exchange the bridge protocol version in init and ready, and
// spawn() refuses a worker of another version by name. The Worker plumbing
// needs a browser; the handshake it relies on is checked here.

import 'package:rpc_dart_isolate/src/port_channel.dart';
import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('init carries the version and still parses as an init frame', () {
    final raw = bridgeHandshakeOf(PortFrameType.init, body: {'a': 1});

    expect(bridgeVersionOf(raw), kWorkerProtocolVersion);
    final frame = bridgeFrameOf(raw)!;
    expect(frame.type, PortFrameType.init);
    expect(frame.streamId, 0);
    expect(frame.body, {'a': 1});
  });

  test('ready carries the version', () {
    final raw = bridgeHandshakeOf(PortFrameType.ready);
    expect(bridgeFrameOf(raw)!.type, PortFrameType.ready);
    expect(bridgeVersionOf(raw), kWorkerProtocolVersion);
  });

  test('the same version is accepted', () {
    expect(workerVersionMismatch(kWorkerProtocolVersion), isNull);
  });

  test('another version is refused, naming both', () {
    final reason = workerVersionMismatch(kWorkerProtocolVersion + 1);
    expect(reason, contains('protocol ${kWorkerProtocolVersion + 1}'));
    expect(reason, contains('protocol $kWorkerProtocolVersion'));
    expect(reason, contains('stale'));
  });

  test('a ready without a version is refused', () {
    final legacy = bridgeMapOf(
      const PortFrame(type: PortFrameType.ready, streamId: 0),
    );
    expect(bridgeVersionOf(legacy), isNull);
    expect(workerVersionMismatch(null), contains('no protocol version'));
  });
}
