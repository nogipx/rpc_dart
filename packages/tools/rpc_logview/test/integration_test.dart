// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_logview/rpc_logview.dart';
import 'package:rpc_logview/rpc_logview_server.dart';
import 'package:test/test.dart';

void main() {
  group('LogviewOutput + LogviewServer', () {
    late LogviewServer server;

    setUp(() async {
      server = LogviewServer(host: '127.0.0.1', port: 0);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('client connects and server receives handshake', () async {
      final connected = Completer<DeviceConnected>();
      server.onConnection.listen((e) {
        if (e is DeviceConnected) connected.complete(e);
      });

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [
          LogviewOutput(
            uri: Uri.parse('ws://127.0.0.1:${server.boundPort}'),
            device: DeviceInfo(name: 'TestDevice', app: 'TestApp'),
          ),
        ],
      );

      final event = await connected.future.timeout(Duration(seconds: 5));
      expect(event.session.device.name, 'TestDevice');
      expect(event.session.device.app, 'TestApp');
      expect(server.sessions, hasLength(1));

      controller.dispose();
    });

    test('log records flow from client to server', () async {
      final records = <TaggedRecord>[];
      final received = Completer<void>();
      server.onRecord.listen((r) {
        records.add(r);
        if (records.length >= 3) {
          if (!received.isCompleted) received.complete();
        }
      });

      // Wait for connection first
      final connected = Completer<void>();
      server.onConnection.listen((e) {
        if (e is DeviceConnected && !connected.isCompleted) {
          connected.complete();
        }
      });

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [
          LogviewOutput(
            uri: Uri.parse('ws://127.0.0.1:${server.boundPort}'),
            device: DeviceInfo(name: 'Phone', app: 'App'),
          ),
        ],
      );

      await connected.future.timeout(Duration(seconds: 5));

      final log = controller.scope('test.service');
      log.info('hello from mobile');
      log.debug('debug message', data: {'key': 'value'});
      log.error('something broke', error: 'TestError');

      await received.future.timeout(Duration(seconds: 5));

      expect(records, hasLength(3));
      expect(records[0].deviceLabel, 'Phone');
      expect((records[0].record as LogEvent).message, 'hello from mobile');
      expect((records[0].record as LogEvent).scope, 'test.service');
      expect((records[1].record as LogEvent).message, 'debug message');
      expect((records[2].record as LogEvent).error.toString(), 'TestError');

      controller.dispose();
    });

    test('output buffers records when server is unavailable', () async {
      // Create output pointing to a port with no server
      final output = LogviewOutput(
        uri: Uri.parse('ws://127.0.0.1:1'),
        device: DeviceInfo(name: 'Phone', app: 'App'),
        bufferSize: 100,
      );

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );

      // Write records -- they should be buffered, not lost
      final log = controller.scope('test');
      for (var i = 0; i < 10; i++) {
        log.info('message $i');
      }

      // No crash, no hang -- fire-and-forget works
      controller.dispose();
    });

    test('disconnect event when client disposes', () async {
      final connected = Completer<void>();
      final disconnected = Completer<void>();

      server.onConnection.listen((e) {
        if (e is DeviceConnected && !connected.isCompleted) {
          connected.complete();
        }
        if (e is DeviceDisconnected && !disconnected.isCompleted) {
          disconnected.complete();
        }
      });

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [
          LogviewOutput(
            uri: Uri.parse('ws://127.0.0.1:${server.boundPort}'),
            device: DeviceInfo(name: 'Phone', app: 'App'),
          ),
        ],
      );

      await connected.future.timeout(Duration(seconds: 5));
      controller.dispose();

      await disconnected.future.timeout(Duration(seconds: 5));
      expect(server.sessions, isEmpty);
    });
  });
}
