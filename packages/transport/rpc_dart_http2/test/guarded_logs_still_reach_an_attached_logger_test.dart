// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 337 put level guards on 41 interpolating `_logger?.internal(...)` sites
// in this package, so a call no longer builds strings a filtered logger throws
// away. The transports' guard is a DIFFERENT idiom from core's, because the
// field is nullable:
//
//   core        if (_logger.isInternal)          { _logger.internal(...); }
//   transports  if (_logger?.isInternal ?? false) { _logger?.internal(...); }
//
// Get the `?? false` backwards and every one of those lines is muted for
// everyone, on a tree where nothing else asserts they are emitted -- the call
// still succeeds, so no other test can notice. This is that assertion.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

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

void main() {
  test('both HTTP/2 transports still log at internal level', () async {
    final controller = LogController(minLevel: RpcLogLevel.internal);
    final seen = <String>[];
    final sub = controller.stream.listen((record) {
      if (record is LogEvent) seen.add(record.message);
    });
    addTearDown(() async {
      await sub.cancel();
      controller.dispose();
    });

    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      logger: controller.scope('test.server'),
      onEndpointCreated: (endpoint) => endpoint.registerServiceContract(_Svc()),
    );
    await server.start();
    addTearDown(server.stop);

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: controller.scope('test.caller'),
    );
    final caller = RpcCallerEndpoint(transport: client, logger: controller);

    final reply = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    expect(reply.value, 'x');

    await Future<void>.delayed(const Duration(milliseconds: 100));

    void expectLine(String prefix, String where) => expect(
      seen.any((m) => m.startsWith(prefix)),
      isTrue,
      reason: '$where was muted: no line starting with "$prefix"',
    );

    expectLine('Opening an HTTP/2 connection to', 'caller transport');
    expectLine('Sending metadata for stream', 'caller transport');
    expectLine('Sent ', 'caller transport');
    expectLine('New incoming stream', 'responder transport');
    expectLine('Headers received for stream', 'responder transport');
    expectLine('Parsed ', 'responder transport');

    await caller.close();
    await client.close();
  });

  // The reachable form of the round-338 defect. `logger:` takes a LogScope, so
  // a user may hand these transports a TAGGED one — and turning a tag up is the
  // documented way to get verbose output from one subsystem without drowning in
  // the rest. The guard used to ask `accepts(level, name)` while the filter asks
  // `accepts(level, name, tag)`, so this configuration muted every guarded line
  // in the package: the call still succeeded and nothing reported anything.
  test('a TAGGED scope still logs when the tag level allows it', () async {
    final controller = LogController(minLevel: RpcLogLevel.error)
      ..setTagLevel('verbose', RpcLogLevel.internal);
    final seen = <String>[];
    final sub = controller.stream.listen((record) {
      if (record is LogEvent) seen.add(record.message);
    });
    addTearDown(() async {
      await sub.cancel();
      controller.dispose();
    });

    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      logger: controller.scope('test.server', tag: 'verbose'),
      onEndpointCreated: (endpoint) => endpoint.registerServiceContract(_Svc()),
    );
    await server.start();
    addTearDown(server.stop);

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: controller.scope('test.caller', tag: 'verbose'),
    );
    final caller = RpcCallerEndpoint(transport: client);

    final reply = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    expect(reply.value, 'x');

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      seen.any((m) => m.startsWith('Sending metadata for stream')),
      isTrue,
      reason:
          'the tag level says internal, so these must arrive; the guard was '
          'reading a threshold resolved WITHOUT the tag',
    );
    expect(
      seen.any((m) => m.startsWith('Headers received for stream')),
      isTrue,
      reason: 'the responder half, same cause',
    );

    await caller.close();
    await client.close();
  });
}
