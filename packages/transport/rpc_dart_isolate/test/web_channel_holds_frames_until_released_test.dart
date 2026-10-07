// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A host channel built with holdUntilReleased sends nothing until release(),
// then everything it was given, in order. The host's transport advertises its
// connection window from its constructor, before a module worker is listening,
// and that first frame must not be lost.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/src/web_bridge.dart';
import 'package:test/test.dart';

RpcTransportMessage _payloadOn(int streamId) => RpcTransportMessage(
  streamId: streamId,
  payload: Uint8List.fromList(const [1]),
);

void main() {
  test('frames are held, then sent in order on release', () async {
    final sent = <Object?>[];
    final channel = WebMultiplexedChannel(
      messageStream: StreamController<dynamic>().stream,
      send: (data) => sent.add(data['streamId']),
      holdUntilReleased: true,
    );

    await channel.send(_payloadOn(1));
    await channel.send(_payloadOn(3));
    expect(sent, isEmpty);

    channel.release();
    expect(sent, [1, 3]);

    await channel.send(_payloadOn(5));
    expect(sent, [1, 3, 5]);
  });

  test('GUARD: without holding, frames go at once', () async {
    final sent = <Object?>[];
    final channel = WebMultiplexedChannel(
      messageStream: StreamController<dynamic>().stream,
      send: (data) => sent.add(data['streamId']),
    );

    await channel.send(_payloadOn(1));
    expect(sent, [1]);
  });
}
