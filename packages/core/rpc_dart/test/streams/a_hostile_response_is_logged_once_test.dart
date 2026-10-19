// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The streaming callers logged one record per message of a hostile response:
// an error with a stack for each undecodable message in a chunk, and a
// warning for each message that arrived after the call had ended. The peer
// chose the volume with the size of its chunk. Unary stopped at the first.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _frames(Uint8List frame, int n) {
  final b = BytesBuilder();
  for (var i = 0; i < n; i++) {
    b.add(frame);
  }
  return b.takeBytes();
}

/// A server stream answered with [first], then [after] in a second chunk,
/// then an OK trailer. Returns the caller's log records at warning and above.
Future<List<LogEvent>> _serverStream(Uint8List first, Uint8List? after) async {
  final logs = LogController(minLevel: RpcLogLevel.warning);
  final records = <LogEvent>[];
  logs.stream.listen((r) {
    if (r is LogEvent) records.add(r);
  });
  final chan = RawPeerChannel();
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport.fromChannel(channel: chan, isClient: true),
    logController: logs,
  );
  addTearDown(caller.close);
  final done = Completer<void>();
  caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'items',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .listen((_) {}, onError: (Object _) {}, onDone: done.complete);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final id = chan.sentStreamIds.firstWhere((s) => s != 0);
  chan
    ..feed(
      RpcChannelFrame.encodeMetadata(
        streamId: id,
        metadata: RpcMetadata.forServerInitialResponse(),
      ),
    )
    ..feed(RpcChannelFrame.encodeData(streamId: id, payload: first));
  if (after != null) {
    chan.feed(RpcChannelFrame.encodeData(streamId: id, payload: after));
  }
  chan.feed(
    RpcChannelFrame.encodeMetadata(
      streamId: id,
      metadata: RpcTrailers.status(0),
      endOfStream: true,
    ),
  );
  await done.future.timeout(const Duration(seconds: 3));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return records;
}

void main() {
  final bad = RpcMessageFrame.encode(Uint8List.fromList([0x7b, 0x7b]));
  final good = RpcMessageFrame.encode(_codec.serialize('a'.rpc));

  test(
    'WITNESS a chunk of undecodable responses logs one decode error',
    () async {
      final records = await _serverStream(_frames(bad, 100), null);
      expect(
        records.where((r) => r.message.startsWith('Failed to deserialize')),
        hasLength(1),
      );
    },
  );

  test('WITNESS responses after a failed decode are reported once', () async {
    final records = await _serverStream(_frames(bad, 1), _frames(good, 100));
    expect(records.where((r) => r.level == RpcLogLevel.warning), hasLength(1));
  });

  test('GUARD a valid response stream logs nothing at warning', () async {
    final records = await _serverStream(_frames(good, 100), null);
    expect(records, isEmpty);
  });
}
