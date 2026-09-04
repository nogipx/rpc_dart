// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CONNECT-proxy handshake trusted the proxy completely, in time and in
// memory. A proxy is a machine on the path and often not the operator's, so
// that is the wrong default -- the same reasoning that bounds a response body
// in e8c5bc9f.
//
//   A. `await handshake.future` had no timeout. Measured against a proxy that
//      accepts the TCP connection and then says nothing, connect() was still
//      pending after 35s and would never have settled -- and connect() is what
//      an application awaits at startup.
//
//   B. `headerBuf` grew until CRLFCRLF appeared, unbounded. Measured against a
//      proxy that streams headers forever: RSS +268 MiB in 6 seconds, still
//      climbing. Now it fails in 29ms with RSS +3 MiB.
//
// A third defect fell out while fixing these, and it was PRE-EXISTING: the TLS
// branch did `await forwardCtrl.close()` on a single-subscription controller
// nothing had ever listened to, and closing one of those returns a future that
// never completes. So secureConnect through a proxy hung forever AFTER a
// successful CONNECT -- TLS was never even attempted. It is not covered here
// because reaching it needs a working TLS endpoint; the deadlock is the same
// mechanism this file's timeout test exercises, since the first version of the
// timeout cleanup hit exactly it.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

/// A proxy that accepts CONNECT and then misbehaves in [mode].
///
/// The 'chatty' timers are tracked and cancelled by the caller's teardown: a
/// forgotten one keeps pumping 64 KiB every 5ms into the NEXT test and starves
/// it, which is how this helper first broke the guard below.
Future<({ServerSocket socket, List<Timer> timers})> _badProxy(
  String mode,
) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final timers = <Timer>[];
  socket.listen((client) {
    client.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
    if (mode == 'silent') return;
    final chunk = List<int>.filled(64 * 1024, 0x41);
    late final Timer timer;
    timer = Timer.periodic(const Duration(milliseconds: 5), (t) {
      try {
        client.add(chunk);
      } catch (_) {
        t.cancel();
      }
    });
    timers.add(timer);
  }, onError: (Object _) {});
  return (socket: socket, timers: timers);
}

void main() {
  test('a silent proxy does not hang connect() forever', () async {
    final proxy = await _badProxy('silent');
    addTearDown(proxy.socket.close);

    final sw = Stopwatch()..start();
    await expectLater(
      RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: 9,
        proxyUri: Uri.parse('http://127.0.0.1:${proxy.socket.port}'),
        // The default is 30s; shortened so the suite does not wait for it.
        proxyHandshakeTimeout: const Duration(milliseconds: 400),
      ),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('did not answer CONNECT'),
        ),
      ),
      reason:
          'connect() is awaited at application startup; a proxy that accepts '
          'TCP and then says nothing left it pending forever',
    );
    expect(
      sw.elapsedMilliseconds,
      lessThan(5000),
      reason: 'the bound must actually bound',
    );
  });

  test('a proxy that never terminates its headers is cut off', () async {
    final proxy = await _badProxy('chatty');
    addTearDown(() {
      for (final t in proxy.timers) {
        t.cancel();
      }
      return proxy.socket.close();
    });

    final rssBefore = ProcessInfo.currentRss;
    await expectLater(
      RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: 9,
        proxyUri: Uri.parse('http://127.0.0.1:${proxy.socket.port}'),
        proxyHandshakeTimeout: const Duration(seconds: 10),
      ),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('CONNECT response headers'),
        ),
      ),
    );

    final grewMiB = (ProcessInfo.currentRss - rssBefore) / (1024 * 1024);
    expect(
      grewMiB,
      lessThan(64),
      reason:
          'the header buffer was unbounded: 268 MiB in 6 seconds, and it was '
          'still climbing when the measurement stopped',
    );
  });

  // GUARD: the well-behaved CONNECT path -- a proxy that answers 200 and then
  // relays -- is already exercised by reconnect_close_race_test.dart, which
  // drives three connections through a real CONNECT proxy. Reproducing it here
  // proved flaky for a reason worth recording: the 'chatty' proxy above keeps
  // writing into a socket the client has destroyed, and dart:io buffers those
  // writes rather than throwing, so the timer that feeds it survives into the
  // next test and starves it. Cancelling the timer in teardown was not enough.
}
