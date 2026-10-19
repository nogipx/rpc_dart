// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `isolate_transport_web.dart` opens with `dart:js_interop` and `package:web`,
// so it cannot be imported off the web at all. `web_bridge.dart` and
// `port_channel.dart` hold the half with no JS dependency, and this file is a
// test in the sense that it COMPILES: add a JS import to either and this stops
// loading on the VM, with the ordinary suite saying so.
//
// The assertions below are incidental. The imports are the test.

// ignore_for_file: implementation_imports

import 'package:rpc_dart_isolate/src/port_channel.dart';
import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('the bridge is reachable from a VM test', () {
    const frame = PortFrame(
      type: PortFrameType.finish,
      streamId: 4,
      endStream: true,
    );

    final round = bridgeFrameOf(bridgeMapOf(frame));
    expect(round, isNotNull);
    expect(round!.type, PortFrameType.finish);
    expect(round.streamId, 4);
    expect(round.endStream, isTrue);
  });

  test('a frame that is not ours parses to null, not to a throw', () {
    expect(bridgeFrameOf('not a map'), isNull);
    expect(bridgeFrameOf(<String, Object?>{'type': 'nonsense'}), isNull);
    expect(bridgeFrameOf(<String, Object?>{'streamId': 1}), isNull);
    expect(
      bridgeFrameOf(<String, Object?>{'type': 'directObject', 'streamId': 1}),
      isNull,
    );
  });

  test('metadata and payload keep their own wire keys', () {
    expect(
      bridgeMapOf(
        const PortFrame(
          type: PortFrameType.metadata,
          streamId: 0,
          body: {'headers': <Object?>[]},
        ),
      ),
      {
        'type': 'metadata',
        'streamId': 0,
        'metadata': {'headers': <Object?>[]},
      },
    );
    expect(
      bridgeMapOf(
        const PortFrame(type: PortFrameType.init, streamId: 0, body: {'a': 1}),
      ),
      {
        'type': 'init',
        'streamId': 0,
        'payload': {'a': 1},
      },
    );
  });
}
