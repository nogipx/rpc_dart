// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server that sends a status without END_STREAM and then another with it
// broke the protocol, and the caller's outcome depended on the call shape:
// unary and client stream took the first status, server stream and bidi
// failed on any error status and ended OK only on END_STREAM. Every shape now
// takes the status on the END_STREAM frame, as grpc-go does.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _frame(String s) => RpcMessageFrame.encode(_codec.serialize(s.rpc));
Uint8List _head(int id) => RpcChannelFrame.encodeMetadata(
  streamId: id,
  metadata: RpcMetadata.forServerInitialResponse(),
);
Uint8List _data(int id, Uint8List payload, {bool end = false}) =>
    RpcChannelFrame.encodeData(
      streamId: id,
      payload: payload,
      endOfStream: end,
    );
Uint8List _status(int id, String code, {required bool end}) =>
    RpcChannelFrame.encodeMetadata(
      streamId: id,
      metadata: RpcMetadata([RpcHeader(RpcHeaders.grpcStatus, code)]),
      endOfStream: end,
    );

/// What a caller of [shape] ends with when the server answers [frames].
Future<String> _outcome(
  String shape,
  List<Uint8List> Function(int) frames,
) async {
  final chan = RawPeerChannel();
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport.fromChannel(channel: chan, isClient: true),
  );
  addTearDown(caller.close);
  final ctx = RpcContext.withTimeout(const Duration(seconds: 2));
  final requests = StreamController<RpcString>()..add('q'.rpc);
  unawaited(requests.close());
  final items = <String>[];
  final Future<String> outcome = switch (shape) {
    'unary' =>
      caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'm',
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: ctx,
          )
          .then((r) => 'OK ${r.value}'),
    'client' =>
      caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'm',
            requestCodec: _codec,
            responseCodec: _codec,
            context: ctx,
            requests: requests.stream,
          )
          .then((r) => 'OK ${r.value}'),
    'server' =>
      caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'm',
            request: 'q'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: ctx,
          )
          .forEach((r) => items.add(r.value))
          .then((_) => 'OK ${items.join(',')}'),
    _ =>
      caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'm',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
            context: ctx,
          )
          .forEach((r) => items.add(r.value))
          .then((_) => 'OK ${items.join(',')}'),
  };
  final settled = outcome.then<String>(
    (s) => s,
    onError: (Object e) =>
        e is RpcStatusException ? 'ERROR ${e.statusCode.code}' : 'ERROR $e',
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final id = chan.sentStreamIds.firstWhere((s) => s != 0);
  for (final f in frames(id)) {
    chan.feed(f);
  }
  return settled.timeout(const Duration(seconds: 4), onTimeout: () => 'HUNG');
}

void main() {
  for (final shape in ['unary', 'client', 'server', 'bidi']) {
    group(shape, () {
      test('WITNESS OK without END_STREAM, then 13 with it, ends 13', () async {
        expect(
          await _outcome(
            shape,
            (id) => [
              _head(id),
              _data(id, _frame('a')),
              _status(id, '0', end: false),
              _status(id, '13', end: true),
            ],
          ),
          'ERROR 13',
        );
      });

      test('WITNESS 13 without END_STREAM, then OK with it, ends OK', () async {
        expect(
          await _outcome(
            shape,
            (id) => [
              _head(id),
              _data(id, _frame('a')),
              _status(id, '13', end: false),
              _status(id, '0', end: true),
            ],
          ),
          'OK a',
        );
      });

      test('WITNESS a status before a cut frame ending the stream is a cut, '
          'not a retryable close', () async {
        expect(
          await _outcome(
            shape,
            (id) => [
              _head(id),
              _status(id, '0', end: false),
              _data(
                id,
                Uint8List.fromList([..._frame('a'), 0, 0, 0]),
                end: true,
              ),
            ],
          ),
          'ERROR 13',
        );
      });

      test('GUARD an ordinary call ends OK', () async {
        expect(
          await _outcome(
            shape,
            (id) => [
              _head(id),
              _data(id, _frame('a')),
              _status(id, '0', end: true),
            ],
          ),
          'OK a',
        );
      });
    });
  }
}
