// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `Future.timeout` abandons the await, not the work, and that cuts two ways. The
// late-ARRIVAL half was already handled: a socket that opens after the caller
// gave up is closed rather than dropped. The half that was not is the attempt
// that never arrives — against a black hole the OS retries the SYN for over a
// minute, holding one descriptor per abandoned connect, and a reconnect loop
// against an unreachable host accumulates them.
//
// Nothing about a `Future` can cancel a connect. What can is the HttpClient
// underneath, and `WebSocket.connect` uses a process-wide one unless it is given
// its own — so the fix is to give a timed attempt a private client and force it
// closed when the timeout fires.
//
// Counted with lsof, because an fd is the thing being leaked and every indirect
// reading of it sits behind a retry the OS controls. Counted against the
// black-hole ADDRESS rather than against every TCP line, so the number belongs to
// this test and not to whichever suites share the process. If lsof is missing the
// test SKIPS loudly rather than passing on no data.
//
// The guard is the one that makes the fix safe rather than merely effective: a
// connect that SUCCEEDS has had its socket detached from that client, so closing
// the client must not disturb it. A round trip over the opened channel is what
// says so.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_dart_websocket/src/websocket_io_connections.dart';
import 'package:rpc_dart_websocket/src/ws_open_io.dart';
import 'package:test/test.dart';

// RFC 5737 TEST-NET-1: guaranteed not routed anywhere real, so a SYN goes out and
// nothing ever answers.
const _blackHole = 'ws://192.0.2.1:9/';
const _attempts = 20;
const _timeout = Duration(milliseconds: 100);

final _codec = RpcCodec(RpcString.fromJson);

/// TCP descriptors held against the black-hole ADDRESS, not every TCP
/// descriptor this process holds.
///
/// `lsof -p` reports the whole process, and `dart test` runs suites as isolates
/// inside one — so a count of all TCP lines includes every socket every other
/// suite has open, and this suite's neighbours open plenty. Filtering on the
/// address makes the reading this test's own: nothing else in the repository
/// connects to TEST-NET-1.
Future<int?> _blackHoleFds() async {
  try {
    final out = await Process.run('lsof', ['-p', '$pid', '-nP']);
    if (out.exitCode != 0) return null;
    return '${out.stdout}'
        .split('\n')
        .where((line) => line.contains('TCP') && line.contains('192.0.2.1'))
        .length;
  } catch (_) {
    return null;
  }
}

void main() {
  test(
    'WITNESS: a connect that timed out does not keep its descriptor',
    () async {
      final before = await _blackHoleFds();
      if (before == null) {
        markTestSkipped('lsof unavailable: nothing here can be counted');
        return;
      }

      var timedOut = 0;
      for (var i = 0; i < _attempts; i++) {
        try {
          final channel = await openWebSocket(
            Uri.parse(_blackHole),
            connectTimeout: _timeout,
          );
          await channel.sink.close();
        } on TimeoutException {
          timedOut++;
        } catch (_) {
          // Something other than a black hole answered; counted below.
        }
      }

      expect(
        timedOut,
        _attempts,
        reason:
            'the address is not a black hole on this machine, so the rest of '
            'this test measures nothing',
      );

      // Well short of any OS connect timeout, and long enough for anything that
      // was going to settle by itself to have settled.
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(
        (await _blackHoleFds())! - before,
        lessThan(_attempts ~/ 2),
        reason:
            'one descriptor per abandoned connect, held until the OS gives up — '
            'a reconnect loop against an unreachable host accumulates them',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  // GUARD: closing the private client must not disturb a connect that SUCCEEDED.
  // WebSocket.connect detaches the upgraded socket from it, and a round trip is
  // what says the detachment really happened.
  test(
    'GUARD: a connect that succeeded still works after its client is closed',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer.createWithContracts(
        connections: rpcWebSocketConnections(http),
        contracts: [_Echo()..setup()],
      );
      await server.start();
      addTearDown(() async {
        await server.dispose().catchError((Object _) {});
        await http.close(force: true);
      });

      final channel = await openWebSocket(
        Uri.parse('ws://127.0.0.1:${http.port}/'),
        connectTimeout: const Duration(seconds: 5),
      );
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(channel),
      );
      addTearDown(() => caller.close().catchError((Object _) {}));

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(
        reply.value,
        'echo:hi',
        reason:
            'closing the private HttpClient took the upgraded socket with it, so '
            'a bounded connect now produces a dead connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: and an open with NO timeout is unchanged — it gets no private client,
  // so there is nothing to close and nothing to get wrong.
  test(
    'GUARD: an unbounded open still works',
    () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer.createWithContracts(
        connections: rpcWebSocketConnections(http),
        contracts: [_Echo()..setup()],
      );
      await server.start();
      addTearDown(() async {
        await server.dispose().catchError((Object _) {});
        await http.close(force: true);
      });

      final channel = await openWebSocket(
        Uri.parse('ws://127.0.0.1:${http.port}/'),
      );
      final caller = RpcCallerEndpoint(
        transport: RpcWebSocketCallerTransport(channel),
      );
      addTearDown(() => caller.close().catchError((Object _) {}));

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));

      expect(reply.value, 'echo:hi');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _Echo extends RpcResponderContract {
  _Echo() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'echo:${req.value}'.rpc,
    );
  }
}
