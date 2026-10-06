// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// bodyIdleTimeout refuses a body that STOPS arriving and never one that keeps
// arriving, whatever its size. bodyReadTimeout, a total, cannot tell the two
// apart: at a budget shorter than an honest upload it refuses both.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A valid 256 KiB gRPC frame.
final Uint8List _body = RpcMessageFrame.encode(
  _codec.serialize(('x' * (256 * 1024 - 64)).rpc),
  compressed: false,
);

Future<int> _server({Duration? total, Duration? idle}) async {
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    bodyReadTimeout: total,
    bodyIdleTimeout: idle,
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc());
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(server.stop);
  return server.actualPort!;
}

/// Posts [_body] at about 128 KiB/s (two seconds), or 5 bytes and then
/// nothing. Returns the status line.
Future<String> _post(int port, {required bool stall}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  addTearDown(socket.destroy);
  final answer = Completer<String>();
  socket.listen(
    (b) {
      if (!answer.isCompleted) {
        answer.complete(String.fromCharCodes(b).split('\r\n').first);
      }
    },
    onDone: () {
      if (!answer.isCompleted) answer.complete('closed');
    },
    onError: (Object _) {
      if (!answer.isCompleted) answer.complete('closed');
    },
  );
  socket.write(
    'POST /Svc/Echo HTTP/1.1\r\n'
    'host: 127.0.0.1:$port\r\n'
    'content-type: application/grpc\r\n'
    'te: trailers\r\n'
    'content-length: ${_body.length}\r\n'
    '\r\n',
  );
  unawaited(() async {
    if (stall) {
      socket.add(_body.sublist(0, 5));
      return;
    }
    const chunk = 8 * 1024;
    for (var i = 0; i < _body.length && !answer.isCompleted; i += chunk) {
      final end = i + chunk > _body.length ? _body.length : i + chunk;
      try {
        socket.add(_body.sublist(i, end));
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 62));
    }
  }());
  return answer.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => 'NOTHING',
  );
}

void main() {
  test(
    'an upload that keeps arriving is not refused by the idle bound',
    () async {
      final port = await _server(idle: const Duration(seconds: 1));
      expect(await _post(port, stall: false), contains('200'));
    },
  );

  test('a client that stops sending gets its 408', () async {
    final port = await _server(idle: const Duration(seconds: 1));
    expect(await _post(port, stall: true), contains('408'));
  });

  test('CONTROL: a total bound shorter than the upload refuses it', () async {
    final port = await _server(total: const Duration(seconds: 1), idle: null);
    expect(await _post(port, stall: false), contains('408'));
  });

  test('the idle bound is on by default', () {
    expect(RpcHttpResponderTransport().bodyIdleTimeout, isNotNull);
  });
}
