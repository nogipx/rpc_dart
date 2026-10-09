// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every pre-dispatch rejection (wrong method, wrong content type, bad path,
// metadata over the policy, too many requests) warned once per REQUEST, so
// any client -- a scanner, a cross-origin preflight, a health check -- chose
// how many warnings the server wrote. Measured, 100 requests each: 100
// warnings for GET, OPTIONS, text/html, no content type and a bad path.
// Each kind now warns once per transport; every request still gets its
// status.

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
      methodName: 'u',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({int port, List<String> warnings});

Future<_Rig> _serve() async {
  final controller = LogController(minLevel: RpcLogLevel.warning);
  final warnings = <String>[];
  controller.stream.listen((r) {
    if (r is LogEvent && r.level == RpcLogLevel.warning) {
      warnings.add(r.message);
    }
  });
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    logController: controller,
    logger: controller.scope('http'),
  );
  await server.start();
  await server.afterModulesStart();
  addTearDown(server.stop);
  return (port: server.actualPort!, warnings: warnings);
}

Future<int> _send(
  HttpClient client,
  int port,
  String method, {
  String? contentType,
}) async {
  final req = await client.open(method, '127.0.0.1', port, '/Svc/u');
  if (contentType != null) req.headers.set('content-type', contentType);
  final res = await req.close();
  await res.drain<void>();
  return res.statusCode;
}

void main() {
  late HttpClient client;
  setUp(() => client = HttpClient());
  tearDown(() => client.close(force: true));

  test('repeated GETs warn once and are each refused 405', () async {
    // WITNESS. Before: 10 warnings.
    final rig = await _serve();
    final codes = [
      for (var i = 0; i < 10; i++) await _send(client, rig.port, 'GET'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(codes, everyElement(405));
    expect(rig.warnings.where((m) => m.contains('not POST')), hasLength(1));
  });

  test('repeated wrong content types warn once and are each 415', () async {
    final rig = await _serve();
    final codes = [
      for (var i = 0; i < 10; i++)
        await _send(client, rig.port, 'POST', contentType: 'text/html'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(codes, everyElement(415));
    expect(rig.warnings.where((m) => m.contains('Content-Type')), hasLength(1));
  });

  test('GUARD: different rejections each still warn once', () async {
    final rig = await _serve();
    await _send(client, rig.port, 'GET');
    await _send(client, rig.port, 'POST', contentType: 'text/html');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.warnings, hasLength(2), reason: '${rig.warnings}');
  });
}
