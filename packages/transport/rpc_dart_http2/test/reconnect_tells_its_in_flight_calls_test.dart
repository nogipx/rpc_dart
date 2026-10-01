// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `reconnect()` terminated the connection and then cancelled each stream's
// subscription. `terminate()` delivers its per-stream errors ASYNCHRONOUSLY, so
// the FIRST subscription was gone before its error arrived and its consumer waited
// out its deadline with nothing. Measured with three in-flight server streams:
//
//     call 0  STILL WAITING
//     call 1  error after 10ms: status 14
//     call 2  error after 11ms: status 14
//     maps after: 1 stream controller left behind
//
// And before any of that, the loop iterated the LIVE `_streamSubscriptions` map
// across an `await`, while each ending removed its own entry -- so with two or
// more streams in flight reconnect() threw
// `Concurrent modification during iteration` and died half-torn-down, with every
// map cleared and no new connection.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Sends one item per stream and then holds it open forever, so every call is
/// genuinely in flight when the teardown lands.
Future<ServerSocket> _dripServer() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc+proto'),
      ]);
      stream.sendData(
        RpcMessageFrame.encode(_codec.serialize('item'.rpc), compressed: false),
      );
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

/// Three in-flight server streams, then [tearDown]. Returns what each consumer was
/// told, and the transport's leftover stream-controller count.
Future<(List<String>, Object?, Object?)> _threeInFlightThen(
  Future<void> Function(RpcHttp2CallerTransport t) tearDown,
) async {
  final socket = await _dripServer();
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: socket.port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
    await socket.close();
  });

  final outcome = <int, String>{};
  for (var i = 0; i < 3; i++) {
    outcome[i] = 'STILL WAITING';
    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'drip',
          request: 'go'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen(
          (_) {},
          onError: (Object e) => outcome[i] = e is RpcStatusException
              ? 'status ${e.statusCode}'
              : e.runtimeType.toString(),
          onDone: () {
            if (outcome[i] == 'STILL WAITING') outcome[i] = 'CLEAN END';
          },
          cancelOnError: false,
        );
    addTearDown(sub.cancel);
  }

  // Long enough that every call is established and has had its first item.
  await Future<void>.delayed(const Duration(milliseconds: 600));

  Object? threw;
  try {
    await tearDown(transport);
  } catch (e) {
    threw = e;
  }
  // Generous: a call that fails fast does so in milliseconds, so anything still
  // waiting here is waiting for its deadline.
  await Future<void>.delayed(const Duration(seconds: 3));

  return (
    [for (var i = 0; i < 3; i++) outcome[i]!],
    threw,
    (await transport.health()).details['streamControllers'],
  );
}

void main() {
  // WITNESS. Before: reconnect() THREW Concurrent modification, and once that was
  // fixed, call 0 read STILL WAITING.
  test('reconnect tells every in-flight call why it ended', () async {
    final (outcomes, threw, controllers) = await _threeInFlightThen(
      (t) => t.reconnect(),
    );

    expect(
      threw,
      isNull,
      reason: 'the subscription loop iterated a map its own awaits mutate',
    );
    expect(
      outcomes,
      everyElement('status ${RpcStatus.unavailable}'),
      reason:
          'a call in flight at a reconnect must fail fast and retryably, '
          'not wait out its deadline for an error that can no longer arrive',
    );
    // The leftover entry is what `closeAll` is needed for whichever way the race
    // above goes: one controller stayed behind per stranded call.
    expect(
      controllers,
      0,
      reason:
          'a stream controller per reconnect is a leak over the life of the '
          'transport, and the only side that can see it is this one',
    );
  });

  // CONTROL. `close()` was measured and is NOT an instance: its in-flight calls
  // already got errors from the connection teardown. It is here because round 571
  // made that answer order-dependent -- status 14 for the first stream and 13 for
  // the rest -- which `_isClosed` in the dying test settles.
  test('CONTROL: close() tells them all the same thing', () async {
    final (outcomes, threw, _) = await _threeInFlightThen((t) => t.close());

    expect(threw, isNull);
    expect(
      outcomes,
      everyElement('status ${RpcStatus.unavailable}'),
      reason:
          'this side hung up, so no call may be told its peer forgot a '
          'status -- and all three must be told the same thing',
    );
  });
}
