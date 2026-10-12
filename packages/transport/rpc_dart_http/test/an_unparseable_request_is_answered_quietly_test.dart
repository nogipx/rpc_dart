// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request shelf cannot turn into a Request (an asterisk target, a fragment,
// a Host that is not a host) was answered by shelf_io, which wrote an ERROR,
// the peer's URI and a stack trace to stderr for every one: six to nine lines
// per request from any client, with its text unescaped.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final class _Capture implements Stdout {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  void write(Object? object) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<String> _send(int port, String target, String host) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final got = Completer<String>();
  s.listen(
    (b) => got.isCompleted
        ? null
        : got.complete(latin1.decode(b).split('\r\n').first),
    onDone: () => got.isCompleted ? null : got.complete('closed'),
    onError: (Object _) => got.isCompleted ? null : got.complete('error'),
  );
  s.write(
    'POST $target HTTP/1.1\r\nhost: $host\r\n'
    'content-type: application/grpc\r\ncontent-length: 0\r\n\r\n',
  );
  final status = await got.future.timeout(const Duration(seconds: 3));
  s.destroy();
  return status;
}

void main() {
  test('WITNESS an unparseable request is answered 400 with nothing on '
      'stderr', () async {
    final err = _Capture();
    var answers = <String>[];
    await IOOverrides.runZoned(() async {
      final server = RpcHttpServer(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (_) {},
      );
      await server.start();
      await server.afterModulesStart();
      try {
        final port = server.actualPort!;
        final esc = String.fromCharCode(27);
        answers = [
          await _send(port, '*', '127.0.0.1:$port'),
          await _send(port, '/Svc/m#frag', '127.0.0.1:$port'),
          await _send(port, '/Svc/m', '127.0.0.1:$esc[31mX'),
        ];
      } finally {
        await server.stop();
      }
    }, stderr: () => err);
    expect(err.lines, isEmpty, reason: err.lines.take(3).join(' | '));
    expect(answers, everyElement(contains('400')));
  });

  test('GUARD a well-formed request is still served', () async {
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (_) {},
    );
    await server.start();
    await server.afterModulesStart();
    addTearDown(server.stop);
    final port = server.actualPort!;
    expect(await _send(port, '/Svc/m', '127.0.0.1:$port'), contains('200'));
  });
}
