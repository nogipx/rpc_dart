// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the connection under RpcHttp2CallerTransport is lost, every call in
// flight on it must be told UNAVAILABLE -- retryable, and at once -- rather
// than wait out its deadline or end clean as if it had completed. The
// transport then closes itself, which is how a reconnecting layer above learns
// of the drop.
//
// The calls are failed before the transport closes: close() cancels each
// stream's subscription, and package:http2 delivers its per-stream errors
// asynchronously, so a stream whose error had not arrived by then would end
// clean. Three server streams are in flight, so an ordering that loses even
// one error shows.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Sends one item per stream and then holds it open forever, so every call is
/// genuinely in flight when the teardown lands. [accepted] collects the
/// server side of every connection, so a test can drop it.
Future<ServerSocket> _dripServer(List<Socket> accepted) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    accepted.add(client);
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

/// Three in-flight server streams, then [tearDown]. Returns what each consumer
/// was told, what [tearDown] threw, the transport's leftover stream-controller
/// count, and whether the transport ended up closed.
Future<(List<String>, Object?, Object?, bool)> _threeInFlightThen(
  Future<void> Function(RpcHttp2CallerTransport t, List<Socket> accepted)
  tearDown,
) async {
  final accepted = <Socket>[];
  final socket = await _dripServer(accepted);
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: socket.port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
    for (final s in accepted) {
      s.destroy();
    }
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
              ? 'status ${e.statusCode.code}'
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
    await tearDown(transport, accepted);
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
    transport.isClosed,
  );
}

void main() {
  test('a lost connection tells every in-flight call why it ended', () async {
    final (outcomes, threw, controllers, closed) = await _threeInFlightThen((
      _,
      accepted,
    ) async {
      expect(accepted, isNotEmpty, reason: 'the client never connected');
      for (final s in accepted) {
        s.destroy();
      }
    });

    expect(threw, isNull);
    expect(
      outcomes,
      everyElement('status ${RpcStatus.unavailable.code}'),
      reason:
          'a call in flight when its connection is lost must fail fast and '
          'retryably, not wait out its deadline or end as if it completed',
    );
    expect(
      controllers,
      0,
      reason:
          'a stream controller left per lost connection is a leak, and the '
          'only side that can see it is this one',
    );
    expect(
      closed,
      isTrue,
      reason: 'a transport whose connection is lost closes itself',
    );
  });

  test('CONTROL: close() tells them all the same thing', () async {
    final (outcomes, threw, _, closed) = await _threeInFlightThen(
      (t, _) => t.close(),
    );

    expect(threw, isNull);
    expect(closed, isTrue);
    expect(
      outcomes,
      everyElement('status ${RpcStatus.unavailable.code}'),
      reason:
          'this side hung up, so no call may be told its peer forgot a '
          'status -- and all three must be told the same thing',
    );
  });
}
