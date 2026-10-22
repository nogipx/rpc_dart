// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A guard in UnaryCaller no test held: a request send that fails must fail
// the call, not leave it to its deadline (with no deadline, forever). Beside
// it, a response arriving after the call completed must reach no zone.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Throws on every send that carries a DATA frame.
void _failDataSends(Uint8List data) {
  final (frames, _) = RpcChannelFrame.decodeAll(data);
  if (frames.any((f) => !f.isMetadata && f.streamId != 0)) {
    throw StateError('the wire is gone');
  }
}

Uint8List _data(int id, String s) => RpcChannelFrame.encodeData(
  streamId: id,
  payload: RpcMessageFrame.encode(_codec.serialize(s.rpc)),
);

void main() {
  // A GUARD, not a witness: with the completer guard removed this stays green,
  // because call() drops its subscription once it completes.
  test('GUARD a response after the call completed reaches no zone', () async {
    final uncaught = <Object>[];
    String? value;
    await runZonedGuarded(() async {
      final chan = RawPeerChannel();
      final caller = RpcCallerEndpoint(
        transport: RpcChannelTransport.fromChannel(
          channel: chan,
          isClient: true,
        ),
      );
      final call = caller.unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'm',
        request: 'q'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final id = chan.sentStreamIds.firstWhere((s) => s != 0);
      chan
        ..feed(
          RpcChannelFrame.encodeMetadata(
            streamId: id,
            metadata: RpcMetadata.forServerInitialResponse(),
          ),
        )
        ..feed(_data(id, 'a'))
        // Only a status with END_STREAM completes the call.
        ..feed(
          RpcChannelFrame.encodeMetadata(
            streamId: id,
            metadata: RpcTrailers.status(RpcStatus.ok),
            endOfStream: true,
          ),
        )
        ..feed(_data(id, 'b'));
      value = (await call).value;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await caller.close();
    }, (e, _) => uncaught.add(e));
    expect(value, 'a');
    expect(uncaught, isEmpty);
  });

  test('WITNESS a request send that fails fails the call', () async {
    final uncaught = <Object>[];
    Object? outcome;
    await runZonedGuarded(() async {
      final caller = RpcCallerEndpoint(
        transport: RpcChannelTransport.fromChannel(
          channel: RawPeerChannel(onSend: _failDataSends),
          isClient: true,
        ),
      );
      outcome = await caller
          .unary<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'm',
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then<Object?>((r) => r, onError: (Object e) => e)
          .timeout(const Duration(seconds: 3), onTimeout: () => 'HUNG');
      await caller.close();
    }, (e, _) => uncaught.add(e));
    expect(outcome, isNot('HUNG'));
    expect(outcome, isNot(isA<RpcString>()));
    expect(uncaught, isEmpty);
  });
}
