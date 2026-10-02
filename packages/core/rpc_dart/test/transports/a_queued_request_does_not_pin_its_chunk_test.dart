// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A decoded payload is a view into the chunk it arrived in. While the request
// waits for a handler that has not read it yet, the view keeps the WHOLE chunk
// alive -- and the buffer limits charge only the payload. A peer that packs a
// one-byte request with a megabyte on a closed stream id held hundreds of MiB
// under a few KiB of charge.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Chan implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    _closed = true;
    await _in.close();
  }

  void feed(Uint8List chunk) => _in.add(chunk);
}

final class _Contract extends RpcResponderContract {
  _Contract(this.release) : super('Svc');

  final Completer<void> release;
  int consumed = 0;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'hold',
      handler: (requests, {RpcContext? context}) async {
        await release.future;
        await for (final _ in requests) {
          consumed++;
        }
        return 'ok'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'quick',
      handler: (request, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Uint8List _cat(Uint8List a, Uint8List b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  test(
    '300 one-byte requests packed with 1 MiB each hold no 300 MiB',
    () async {
      final chan = _Chan();
      final transport = RpcChannelTransport.fromChannel(
        channel: chan,
        isClient: false,
      );
      final contract = _Contract(Completer<void>());
      final responder = RpcResponderEndpoint(transport: transport)
        ..registerServiceContract(contract)
        ..start();
      addTearDown(() async {
        if (!contract.release.isCompleted) contract.release.complete();
        await responder.close();
        await transport.close();
      });

      // Stream 3 finishes, so frames on it are dropped; stream 1 is held.
      chan
        ..feed(
          RpcChannelFrame.encodeMetadata(
            streamId: 3,
            metadata: RpcMetadata.forClientRequest('Svc', 'quick'),
          ),
        )
        ..feed(
          RpcChannelFrame.encodeData(
            streamId: 3,
            payload: RpcMessageFrame.encode(_codec.serialize('q'.rpc)),
            endOfStream: true,
          ),
        )
        ..feed(
          RpcChannelFrame.encodeMetadata(
            streamId: 1,
            metadata: RpcMetadata.forClientRequest('Svc', 'hold'),
          ),
        );
      await _settle();

      final tiny = RpcChannelFrame.encodeData(
        streamId: 1,
        payload: RpcMessageFrame.encode(_codec.serialize('a'.rpc)),
      );
      const count = 300;
      final before = ProcessInfo.currentRss;
      for (var i = 0; i < count; i++) {
        chan.feed(
          _cat(
            tiny,
            RpcChannelFrame.encodeData(
              streamId: 3,
              payload: Uint8List(1 << 20),
            ),
          ),
        );
        if (i % 10 == 0) await Future<void>.delayed(Duration.zero);
      }
      await _settle();
      final grownMiB = (ProcessInfo.currentRss - before) >> 20;

      expect(
        grownMiB,
        lessThan(100),
        reason: '$count MiB of chunks pinned by $count queued requests',
      );

      contract.release.complete();
      chan.feed(RpcChannelFrame.encodeEndOfStream(1));
      await _settle();
      expect(contract.consumed, count, reason: 'every request still arrives');
    },
  );
}
