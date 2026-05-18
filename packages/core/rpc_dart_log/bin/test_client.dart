// Quick smoke test: connect to a running logview server and send records.
// Usage: dart run bin/test_client.dart [ws://host:port]

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';

void main(List<String> args) async {
  final uri = args.isNotEmpty ? args[0] : 'ws://127.0.0.1:9500';
  print('Connecting to $uri ...');

  final controller = LogController(
    minLevel: RpcLogLevel.debug,
    outputs: [
      ConsoleOutput(),
      LogviewOutput(
        uri: Uri.parse(uri),
        device: DeviceInfo(name: 'TestClient', app: 'smoke_test'),
      ),
    ],
  );

  // Wait for connection
  await Future.delayed(Duration(seconds: 2));

  final log = controller.scope('test');

  for (var i = 1; i <= 5; i++) {
    log.info('test message $i', data: {'i': i});
    print('Sent message $i');
    await Future.delayed(Duration(milliseconds: 500));
  }

  log.error('test error', error: 'SomeError');
  print('Sent error');

  await Future.delayed(Duration(seconds: 1));
  controller.dispose();
  print('Done.');
}
