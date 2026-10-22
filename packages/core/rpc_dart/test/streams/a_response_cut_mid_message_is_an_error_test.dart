// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A response stream that ends inside a gRPC frame, then an OK trailer: the
// partial frame was dropped and the call ended OK, so a server stream cut
// mid-message read as complete with its last item gone. The request side has
// answered this since round 554 (`holdsPartialFrame`); the response side had
// no check.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Two whole frames, then a third cut after [cut] bytes (none if 0), then an
/// OK trailer. Returns the items and the error the consumer saw.
Future<(List<String>, Object?)> _serverStream(int cut) async {
  final chan = RawPeerChannel();
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
        metadata: RpcTrailers.status(RpcStatus.ok),
        endOfStream: true,
      ),
    );
  await done.future.timeout(const Duration(seconds: 3));
  return (items, error);
}

/// A unary response of one whole frame and the first [cut] bytes of a second
/// (none if 0), then an OK trailer. Returns what the call completed with.
Future<Object?> _unary(int cut) async {
  final chan = RawPeerChannel();
  final transport = RpcChannelTransport.fromChannel(
    channel: chan,
    isClient: true,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(caller.close);
  final outcome = caller
      .unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .then<Object?>((r) => r.value, onError: (Object e) => e);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final id = chan.sentStreamIds.firstWhere((s) => s != 0);
  final frame = RpcMessageFrame.encode(_codec.serialize('item'.rpc));
  final body = BytesBuilder()..add(frame);
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
        metadata: RpcTrailers.status(RpcStatus.ok),
        endOfStream: true,
      ),
    );
  return outcome.timeout(const Duration(seconds: 3));
}

void main() {
  test(
    'WITNESS a unary response with a cut second frame ends with INTERNAL',
    () async {
      expect(
        await _unary(3),
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.internal,
        ),
      );
    },
  );

  test('GUARD a unary response of one whole frame ends OK', () async {
    expect(await _unary(0), 'item');
  });

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
