// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The boundary B-31's witness rests on, pinned so it cannot quietly move back.
//
// `isolate_transport_web.dart` opens with `dart:js_interop` and `package:web`,
// so it cannot be imported off the web at ALL — measured in round 428, which is
// why B-31's decided route ("@visibleForTesting plus a VM test") could not have
// worked as written. `web_bridge.dart` holds the half with no JS dependency,
// and this file is a test only in the sense that it COMPILES: add a JS import
// to the bridge and this stops loading on the VM, with the ordinary suite
// saying so.
//
// The assertions below are incidental. The import is the test.

// ignore_for_file: implementation_imports

import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('the bridge is reachable from a VM test', () {
    final frame = BridgeMessage(
      type: BridgeType.finish,
      streamId: 4,
      endStream: true,
    );

    final round = BridgeMessage.fromMap(frame.toMap());
    expect(round, isNotNull);
    expect(round!.type, BridgeType.finish);
    expect(round.streamId, 4);
    expect(round.endStream, isTrue);
  });

  test('a frame that is not ours parses to null, not to a throw', () {
    expect(BridgeMessage.fromMap('not a map'), isNull);
    expect(
      BridgeMessage.fromMap(<String, Object?>{'type': 'nonsense'}),
      isNull,
    );
    expect(BridgeMessage.fromMap(<String, Object?>{'streamId': 1}), isNull);
  });
}
