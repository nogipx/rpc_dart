// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request past the server's size limit is answered RESOURCE_EXHAUSTED, and
// the server then closes the connection. When the request is much larger than
// the limit, the client is still writing it at that moment. Destroying the
// socket with those bytes unread makes the kernel reset the connection, and
// the reset discards the trailer the client had received but not read: the
// caller saw its own failed write, UNAVAILABLE, which a retry repeats.
//
// The guard below bounds the other side of the fix: the server reads and
// drops the rest of the request, but a peer that never stops sending is still
// cut off by the close timeout.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

import 'support/echo.dart';

const _limit = 64 * 1024;

void main() {
  test(
    'WITNESS: a request far past the limit reads RESOURCE_EXHAUSTED',
    () async {
      final address = RpcSocketAddress.unix(tempSocketPath());
      final server = RpcSocketServer(
        address: address,
        policy: const RpcSecurityPolicy(maxMessageLengthBytes: _limit),
        mode: RpcResponderMode(
          (e) => e.registerServiceContract(EchoResponder()),
        ),
      );
      await server.start();
      addTearDown(server.stop);

      final request = 'x' * (8 * 1024 * 1024);
      final statuses = <String>[];
      for (var i = 0; i < 5; i++) {
        final caller = await dialEcho(address);
        statuses.add(await statusOf(() => caller.serverStream(request)));
      }

      expect(
        statuses,
        everyElement('status ${RpcStatus.resourceExhausted.code}'),
        reason:
            'the server reset the connection with the request still arriving, '
            'which discarded the RESOURCE_EXHAUSTED trailer: the caller saw '
            'its own failed write, UNAVAILABLE, and a retry sends it again',
      );
    },
  );

  test('GUARD: a peer that sends fast is cut off by the byte bound', () async {
    final elapsed = await _closeOversizeAgainst(
      chunk: 64 * 1024,
      pause: Duration.zero,
      closeTimeout: const Duration(seconds: 10),
    );
    expect(elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('GUARD: a peer that trickles is cut off by the close timeout', () async {
    final elapsed = await _closeOversizeAgainst(
      chunk: 1024,
      pause: const Duration(milliseconds: 20),
      closeTimeout: const Duration(milliseconds: 300),
    );
    expect(elapsed, lessThan(const Duration(seconds: 2)));
  });
}

/// How long [RpcSocketChannel.closeFor] an oversize takes against a peer that
/// writes [chunk] bytes every [pause] and never closes.
Future<Duration> _closeOversizeAgainst({
  required int chunk,
  required Duration pause,
  required Duration closeTimeout,
}) async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(listener.close);
  final accepted = listener.first;
  final client = await Socket.connect(
    InternetAddress.loopbackIPv4,
    listener.port,
  );
  addTearDown(client.destroy);
  unawaited(client.done.catchError((Object _) {}));
  client.listen((_) {}, onError: (Object _) {});

  final channel = RpcSocketChannel(await accepted, closeTimeout: closeTimeout);
  unawaited(channel.incoming.drain<void>().catchError((Object _) {}));

  var writing = true;
  addTearDown(() => writing = false);
  final bytes = Uint8List(chunk);
  unawaited(() async {
    while (writing) {
      try {
        client.add(bytes);
        await client.flush();
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      } catch (_) {
        return;
      }
    }
  }());

  final sw = Stopwatch()..start();
  await channel
      .closeFor(const RpcCloseForOversize('too large'))
      .timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the drain followed the peer past the bound this test leaves it',
        ),
      );
  expect(channel.isClosed, isTrue);
  return sw.elapsed;
}
