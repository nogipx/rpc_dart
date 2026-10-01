// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `start()`'s guard read `_isRunning`, which is assigned AFTER the bind's await —
// so two concurrent callers both passed it and both bound. The loser's catch then
// set the flag FALSE over the winner's true, and `stop()` gives up on exactly that
// flag: the socket went on serving calls while `isRunning` reported false, and
// nothing could release it for the life of the process.
//
// Same shape as the HTTP/1.1 server's phase two and the opposite symptom — there
// the loser closed the shared transport, so calls failed while the server claimed
// to be up. Here they succeed while it claims to be down.
//
// THE PORT MUST BE FIXED. With port 0 each concurrent bind gets its own and the
// path under test never runs.
@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind('127.0.0.1', 0);
  final port = s.port;
  await s.close();
  return port;
}

typedef _Run = ({bool isRunning, bool portFreeAfterStop});

Future<_Run> _start({required int starts}) async {
  final port = await _freePort();
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: port,
    onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
  );

  await Future.wait(
    List.generate(starts, (_) => server.start().catchError((Object _) {})),
  );
  final running = server.isRunning;

  await server.stop().catchError((Object _) {});

  // The leak is only visible from outside: `stop()` returns either way, and what
  // differs is whether anything still holds the port.
  var free = false;
  try {
    final probe = await ServerSocket.bind('127.0.0.1', port);
    await probe.close();
    free = true;
  } catch (_) {
    free = false;
  }

  return (isRunning: running, portFreeAfterStop: free);
}

void main() {
  test(
    'CONTROL one start() binds and releases',
    () async {
      final r = await _start(starts: 1);

      expect(r.isRunning, isTrue);
      expect(r.portFreeAfterStop, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS two concurrent starts leave nothing bound',
    () async {
      final r = await _start(starts: 2);

      expect(
        r.isRunning,
        isTrue,
        reason: "the loser's catch cleared the flag the winner had just set",
      );
      expect(
        r.portFreeAfterStop,
        isTrue,
        reason:
            'stop() gives up on !isRunning, so a cleared flag left the listener '
            'bound for the life of the process',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
