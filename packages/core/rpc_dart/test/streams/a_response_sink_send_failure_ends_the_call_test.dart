// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi responseSink whose response cannot be serialized went on pumping:
// the client read the responses behind it as the stream continuing, and the
// failure arrived only at the end, which an endless source never reaches.
// The endpoint's own pump stops there (a_response_that_cannot_be_sent_ends_
// the_stream_test); this is the sink a direct user of the responder drives.

import 'dart:async';

import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Throws on serializing 'bad'.
final class _Refuses implements IRpcCodec<RpcString> {
  @override
  Uint8List serialize(RpcString message) {
    if (message.value == 'bad') throw StateError('cannot serialize');
    return _codec.serialize(message);
  }

  @override
  RpcString deserialize(Uint8List bytes) => _codec.deserialize(bytes);
}

/// Drives [values] through the responder's responseSink and returns what the
/// client read and how its call ended.
Future<String> _clientSees(List<String> values) async {
  final (rawClient, rawServer) = RpcChannelTransport.memoryPair();
  final clientTransport = NoZeroCopyTransport(rawClient);
  final serverTransport = NoZeroCopyTransport(rawServer);
  final responder = BidirectionalStreamResponder<RpcString, RpcString>(
    id: 1,
    transport: serverTransport,
    serviceName: 'S',
    methodName: 'M',
    requestCodec: _codec,
    responseCodec: _Refuses(),
  );
  responder.bindToMessageStream(
    serverTransport.incomingMessages.where((m) => m.streamId == 1),
  );
  final caller = BidirectionalStreamCaller<RpcString, RpcString>(
    transport: clientTransport,
    serviceName: 'S',
    methodName: 'M',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  addTearDown(() async {
    await caller.close().catchError((_) {});
    await responder.close().catchError((_) {});
    await rawClient.close();
    await rawServer.close();
  });

  final got = <String>[];
  final done = Completer<String>();
  caller.payloadResponses.listen(
    (v) => got.add(v.value),
    onDone: () => done.isCompleted ? null : done.complete('ended OK'),
    onError: (Object e) => done.isCompleted
        ? null
        : done.complete(
            e is RpcStatusException ? 'status ${e.statusCode}' : '$e',
          ),
  );
  await caller.send('start'.rpc);
  await Future<void>.delayed(const Duration(milliseconds: 30));
  await responder.responseSink
      .addStream(Stream.fromIterable([for (final v in values) v.rpc]))
      .catchError((_) {});
  await responder.responseSink.close().catchError((_) {});
  final how = await done.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => 'never ended',
  );
  return '$got, $how';
}

void main() {
  test(
    'WITNESS a response that cannot be serialized ends the call there',
    () async {
      expect(
        await _clientSees(['x', 'bad', 'y', 'z']),
        '[x], status ${RpcStatus.internal}',
      );
    },
  );

  test('GUARD every response serializes', () async {
    expect(await _clientSees(['x', 'y', 'z']), '[x, y, z], ended OK');
  });
}
