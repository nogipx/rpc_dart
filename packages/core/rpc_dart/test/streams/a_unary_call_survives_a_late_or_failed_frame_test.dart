// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A guard in UnaryCaller no test held: a request send that fails must fail
// the call, not leave it to its deadline (with no deadline, forever). Beside
// it, a response arriving after the call completed must reach no zone.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Chan implements IRpcChannel {
  _Chan({this.failDataSends = false});

  /// Throws on every send that carries a DATA frame.
  final bool failDataSends;

  final _in = StreamController<Uint8List>();
  bool _closed = false;
  final sentStreamIds = <int>[];

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (data.length >= 4) {
      sentStreamIds.add(
        (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3],
      );
    }
    if (failDataSends) {
      final (frames, _) = RpcChannelFrame.decodeAll(data);
      if (frames.any((f) => !f.isMetadata && f.streamId != 0)) {
        throw StateError('the wire is gone');
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _in.close();
  }

  void feed(Uint8List chunk) => _in.add(chunk);
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
      final chan = _Chan();
      final caller = RpcCallerEndpoint(
        transport: RpcChannelTransport.fromChannel(
          channel: chan,
          isClient: true,
        ),
      );
      final call = caller.unaryRequest<RpcString, RpcString>(
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
            metadata: RpcMetadata.forTrailer(0),
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
          channel: _Chan(failDataSends: true),
          isClient: true,
        ),
      );
      outcome = await caller
          .unaryRequest<RpcString, RpcString>(
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
