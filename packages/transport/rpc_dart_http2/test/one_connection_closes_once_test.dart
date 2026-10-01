// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two paths release the endpoint for one connection: the preface deadline releases
// it and then destroys the socket, whose `done` releases it again. So
// `onConnectionClosed` fired TWICE for a connection reclaimed that way — a user's
// callback double-counting connections, and whatever it releases released twice.
//
// An ordinary close goes through one path only, which is the control: without it a
// count of 1 could mean the callback had stopped firing at all.
@TestOn('vm')
library;

import 'dart:async';
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

typedef _Counts = ({int opened, int closed});

/// One connection, either silent until the preface deadline reclaims it or
/// speaking HTTP/2 and leaving politely.
Future<_Counts> _oneConnection({required bool speaks}) async {
  var opened = 0;
  var closed = 0;
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    prefaceTimeout: const Duration(milliseconds: 100),
    onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    onConnectionOpened: (_) => opened++,
    onConnectionClosed: (_) => closed++,
  );
  await server.start();
  addTearDown(() => server.stop().catchError((Object _) {}));

  if (speaks) {
    final t = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    await t.close().catchError((Object _) {});
  } else {
    final c = await Socket.connect('127.0.0.1', server.port);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    c.destroy();
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));

  return (opened: opened, closed: closed);
}

void main() {
  test(
    'CONTROL a polite close reports one open and one close',
    () async {
      final c = await _oneConnection(speaks: true);

      expect(c.opened, 1);
      expect(c.closed, 1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS a preface-deadline close reports it ONCE',
    () async {
      final c = await _oneConnection(speaks: false);

      expect(c.opened, 1);
      expect(
        c.closed,
        1,
        reason:
            'the deadline releases the endpoint and destroys the socket, whose '
            "`done` released it again — so the user's callback saw two closes "
            'for one connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
