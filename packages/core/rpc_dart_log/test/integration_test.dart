// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_dart_log/rpc_dart_log_server.dart';
import 'package:rpc_dart_log/src/contract/logview_caller.dart';
import 'package:rpc_dart_log/src/contract/logview_responder.dart';
import 'package:rpc_dart_log/src/contract/messages.dart';
import 'package:test/test.dart';

void main() {
  group('LogviewOutput + LogviewServer (contract-based)', () {
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
      expect(event.session.deviceName, 'TestDevice');
      expect(event.session.app, 'TestApp');
      expect(server.sessions, hasLength(1));

      controller.dispose();
    });

    test('log records flow from client to server', () async {
      final records = <TaggedRecord>[];
      final received = Completer<void>();
      server.onRecord.listen((r) {
        records.add(r);
        if (records.length >= 3 && !received.isCompleted) {
          received.complete();
        }
      });

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
      final output = LogviewOutput(
        uri: Uri.parse('ws://127.0.0.1:1'),
        device: DeviceInfo(name: 'Phone', app: 'App'),
        bufferSize: 100,
      );

      final controller = LogController(
        minLevel: RpcLogLevel.debug,
        outputs: [output],
      );

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

  group('Contract unit test (in-memory)', () {
    test('handshake and send via in-memory transport', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      final responder = RpcResponderEndpoint(transport: serverTransport);
      final caller = RpcCallerEndpoint(transport: clientTransport);

      // Track received records on server side
      final received = <LogviewRecord>[];
      LogviewHandshake? handshakeInfo;

      final contract = LogviewServiceResponder(
        onHandshake: (info) => handshakeInfo = info,
        onRecord: (record) => received.add(record),
      );
      responder.registerServiceContract(contract);

      responder.start();
      caller.start();

      // Use caller contract
      final callerContract = LogviewServiceCaller(caller);
      final welcome = await callerContract.handshake(
        LogviewHandshake(deviceName: 'TestPhone', app: 'TestApp'),
      );

      expect(welcome.sessionId, isPositive);
      expect(handshakeInfo?.deviceName, 'TestPhone');
      expect(handshakeInfo?.app, 'TestApp');

      await callerContract.send(LogviewRecord({
        'type': 'event',
        'scope': 'test',
        'level': 'info',
        'message': 'hello',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));

      expect(received, hasLength(1));
      expect(received[0].payload['message'], 'hello');

      await clientTransport.close();
      await serverTransport.close();
    });
  });
}
