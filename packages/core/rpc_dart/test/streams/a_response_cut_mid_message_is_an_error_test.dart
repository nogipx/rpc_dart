// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response stream that ends inside a gRPC frame, then an OK trailer: the
// partial frame was dropped and the call ended OK, so a server stream cut
// mid-message read as complete with its last item gone. The request side has
// answered this since round 554 (`holdsPartialFrame`); the response side had
// no check.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Chan implements IRpcChannel {
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
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _in.close();
  }

  void feed(Uint8List chunk) => _in.add(chunk);
}

/// Two whole frames, then a third cut after [cut] bytes (none if 0), then an
/// OK trailer. Returns the items and the error the consumer saw.
Future<(List<String>, Object?)> _serverStream(int cut) async {
  final chan = _Chan();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: true,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(caller.close);
  final items = <String>[];
  Object? error;
  final done = Completer<void>();
  caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'items',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen(
        (r) => items.add(r.value),
        onError: (Object e) => error = e,
        onDone: done.complete,
      );
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final id = chan.sentStreamIds.firstWhere((s) => s != 0);
  final frame = RpcMessageFrame.encode(_codec.serialize('item'.rpc));
  final body = BytesBuilder()
    ..add(frame)
    ..add(frame);
  if (cut > 0) body.add(frame.sublist(0, cut));
  chan
    ..feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forServerInitialResponse(),
      ),
    )
    ..feed(RpcChannelFrame.encodeData(streamId: id, payload: body.takeBytes()))
    ..feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forTrailer(0),
        endOfStream: true,
      ),
    );
  await done.future.timeout(const Duration(seconds: 3));
  return (items, error);
}

void main() {
  for (final (cut, where) in [
    (2, 'inside the prefix'),
    (5, 'right after the prefix'),
    (7, 'inside the body'),
  ]) {
    test('WITNESS a response cut $where ends with INTERNAL', () async {
      final (items, error) = await _serverStream(cut);
      expect(items, ['item', 'item']);
      expect(
        error,
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
      );
    });
  }

  test('GUARD a response that ends between frames ends OK', () async {
    final (items, error) = await _serverStream(0);
    expect(items, ['item', 'item']);
    expect(error, isNull);
  });
}
