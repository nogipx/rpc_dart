// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server that refuses an oversized request killed the CLIENT process.
//
// `UnaryCaller.call` sends, and only then reaches `await completer.future`. A
// server refusing a large request does exactly the wrong thing for that order:
// it stops reading, so the send parks on the peer's flow-control window, while
// its RESOURCE_EXHAUSTED trailer arrives on the same stream. The response
// subscription then calls `completeError` on a future nobody is listening to
// yet, and an unhandled async error in the root zone takes the isolate with it:
//
//     Unhandled exception:
//     RpcStatusException(8): RpcException: gRPC frame payload is too large:
//     2097160 bytes (max: 262144)
//
// The status was correct. Only nobody was listening.
//
// This runs the call in a SEPARATE PROCESS, because that is the only way to
// observe the difference: an unhandled root-zone error cannot be caught from
// inside the isolate it kills, and `dart test` would report it as a crashed
// suite rather than a failed expectation.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// The client half, run as a child process so its death is observable.
const _clientSource = r'''
import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final _codec = RpcCodec(RpcString.fromJson);

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
    // Generous: the ceiling under test is the SERVER's, and a shared one would
    // make the client refuse its own request first.
    policy: const RpcSecurityPolicy(maxMessageLengthBytes: 32 * 1024 * 1024),
  );
  final caller = RpcCallerEndpoint(transport: client);
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'sink',
          request: ('x' * (2 * 1024 * 1024)).rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withTimeout(const Duration(seconds: 5)),
        )
        // A backstop only. The call must settle on the SERVER's answer long
        // before this; if it ever fires, the wait is gated on the send again.
        .timeout(const Duration(seconds: 20));
    stdout.writeln('RETURNED');
  } catch (e) {
    stdout.writeln(
      'CAUGHT ${e.runtimeType}'
      '${e is RpcStatusException ? ' status=${e.statusCode}' : ''}',
    );
  }
  await caller.close();
  stdout.writeln('SURVIVED');
  exit(0);
}
''';

const _serverSource = r'''
import 'dart:io';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'sink',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
    );
  }
}

Future<void> main() async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: 256 * 1024),
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  stdout.writeln('PORT ${server.port}');
  await Future<void>.delayed(const Duration(seconds: 60));
  await server.stop();
}
''';

void main() {
  test(
    'a refused oversized request does not kill the client isolate',
    () async {
      // WITNESS. Pre-fix the child died with an unhandled RpcStatusException(8)
      // and a non-zero exit code; nothing it printed reached "SURVIVED".
      final dir = Directory('${Directory.current.path}/.dart_tool/probe')
        ..createSync(recursive: true);
      File(
        '${dir.path}/oversized_client.dart',
      ).writeAsStringSync(_clientSource);
      File(
        '${dir.path}/oversized_server.dart',
      ).writeAsStringSync(_serverSource);

      final server = await Process.start(Platform.resolvedExecutable, [
        'run',
        '${dir.path}/oversized_server.dart',
      ]);
      addTearDown(() => server.kill(ProcessSignal.sigkill));

      final portLine = await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.startsWith('PORT '))
          .timeout(const Duration(seconds: 60));
      final port = portLine.substring(5).trim();

      final client = await Process.run(Platform.resolvedExecutable, [
        'run',
        '${dir.path}/oversized_client.dart',
        port,
      ]).timeout(const Duration(seconds: 90));

      expect(
        client.stderr.toString(),
        isNot(contains('Unhandled exception')),
        reason: 'the client isolate must survive a refused request',
      );
      expect(
        client.stdout.toString(),
        contains('SURVIVED'),
        reason: 'the client must reach the end of main()',
      );
      expect(client.exitCode, 0);

      // The SERVER's answer, not a local deadline. Once the crash was gone the
      // call still hung: `call()` was inside `await sendMessage` when the
      // trailer arrived, so the wait was gated on a send the peer had stopped
      // reading, and `RpcContext.withTimeout(5s)` never applied. Measured
      // through the probe: still running at 15 s -> RpcStatusException(8) in
      // 19 ms.
      expect(
        client.stdout.toString(),
        contains(
          'CAUGHT RpcStatusException status=${RpcStatus.resourceExhausted}',
        ),
        reason:
            'the refusal is already on the stream; the call must read it '
            'rather than wait for a send the peer will never drain',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
