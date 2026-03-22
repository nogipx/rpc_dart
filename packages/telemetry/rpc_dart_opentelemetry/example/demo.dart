// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: avoid_print

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

// =============================================================================
// Run: fvm dart run example/demo.dart
//
// Демонстрирует OtelRpcInterceptor на всех 4 типах вызовов через InMemoryTransport.
//
// Режимы:
//   ConsoleExporter  — без Docker, spans в stdout
//   CollectorExporter — с Jaeger:
//     docker run -d --name jaeger -p 4318:4318 -p 16686:16686 jaegertracing/all-in-one
//     UI: http://localhost:16686 → сервис "rpc-demo"
// =============================================================================

const _useJaeger = bool.fromEnvironment('JAEGER', defaultValue: false);

void main() async {
  // ---------------------------------------------------------------------------
  // 1. OTel SDK
  // ---------------------------------------------------------------------------
  final exporter = _useJaeger
      ? CollectorExporter(Uri.parse('http://localhost:4318/v1/traces'))
      : ConsoleExporter();

  final tracerProvider = TracerProviderBase(
    processors: [SimpleSpanProcessor(exporter)],
    resource: Resource([
      Attribute.fromString('service.name', 'rpc-demo'),
      Attribute.fromString('service.version', '0.1.0'),
    ]),
  );
  registerGlobalTracerProvider(tracerProvider);

  final tracer = globalTracerProvider.getTracer('rpc-demo');
  final interceptor = OtelRpcInterceptor(tracer: tracer);

  // ---------------------------------------------------------------------------
  // 2. Транспорт и endpoints
  // ---------------------------------------------------------------------------
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  final server = RpcResponderEndpoint(transport: serverTransport)
    ..addInterceptor(interceptor);
  final client = RpcCallerEndpoint(transport: clientTransport);

  // Регистрируем все сервисы
  server
    ..registerServiceContract(_GreetingService())
    ..registerServiceContract(_CounterService())
    ..registerServiceContract(_BrokenService())
    ..start();

  // ---------------------------------------------------------------------------
  // 3. Демонстрация
  // ---------------------------------------------------------------------------

  print('\n${'=' * 60}');
  print('  rpc_dart_opentelemetry demo');
  print('=' * 60);

  await _demoUnary(client);
  await _demoServerStream(client);
  await _demoError(client);
  await _demoContextPropagation(client, tracer);

  // ---------------------------------------------------------------------------
  // 4. Cleanup
  // ---------------------------------------------------------------------------
  await client.close();
  await server.close();
  print('\n${'=' * 60}');
  print('  Done. Check spans above.');
  print('=' * 60);
}

// =============================================================================
// Demos
// =============================================================================

Future<void> _demoUnary(RpcCallerEndpoint client) async {
  print('\n▶ Unary call: GreetingService/Hello');

  final response = await client.unaryRequest<RpcString, RpcString>(
    serviceName: 'GreetingService',
    methodName: 'Hello',
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
    request: 'World'.rpc,
    context: RpcContext.withTraceId('demo-trace-001'),
  );

  print('  ← ${response.value}');
}

Future<void> _demoServerStream(RpcCallerEndpoint client) async {
  print('\n▶ Server stream: CounterService/Count (5 messages)');

  var received = 0;
  await for (final msg in client.serverStream<RpcString, RpcString>(
    serviceName: 'CounterService',
    methodName: 'Count',
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
    request: '5'.rpc,
    context: RpcContext.withTraceId('demo-trace-002'),
  )) {
    received++;
    print('  ← ${msg.value}');
  }

  print('  Total messages received: $received (span will have rpc.stream.messages=$received)');
}

Future<void> _demoError(RpcCallerEndpoint client) async {
  print('\n▶ Error case: BrokenService/Fail');

  try {
    await client.unaryRequest<RpcString, RpcString>(
      serviceName: 'BrokenService',
      methodName: 'Fail',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: 'boom'.rpc,
      context: RpcContext.withTraceId('demo-trace-003'),
    );
  } catch (e) {
    print('  ✗ Got expected error: $e');
    print('  (span status=ERROR, exception recorded)');
  }
}

Future<void> _demoContextPropagation(
  RpcCallerEndpoint client,
  Tracer tracer,
) async {
  print('\n▶ W3C context propagation');

  // Начинаем родительский span на "клиенте"
  final parentSpan = tracer.startSpan('client-operation');

  // Инжектим текущий span в RpcContext → traceparent header
  final ctx = RpcOtelPropagator.inject(
    RpcContext.withTraceId('demo-trace-004'),
  );

  print('  traceparent header: ${ctx.getHeader('traceparent') ?? '(none — no active span in Zone)'}');

  final response = await client.unaryRequest<RpcString, RpcString>(
    serviceName: 'GreetingService',
    methodName: 'Hello',
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
    request: 'propagation'.rpc,
    context: ctx,
  );

  print('  ← ${response.value}');
  parentSpan.end();
}

// =============================================================================
// Service contracts
// =============================================================================

final class _GreetingService extends RpcResponderContract {
  _GreetingService() : super('GreetingService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _hello(RpcString name, {RpcContext? context}) async {
    // Показываем что span доступен из контекста
    final span = context?.getValue(OtelRpcKeys.span) as Span?;
    span?.setAttribute(Attribute.fromString('greeting.name', name.value));
    return 'Hello, ${name.value}!'.rpc;
  }
}

final class _CounterService extends RpcResponderContract {
  _CounterService() : super('CounterService');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Count',
      handler: _count,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Stream<RpcString> _count(RpcString request, {RpcContext? context}) async* {
    final n = int.tryParse(request.value) ?? 3;
    for (var i = 1; i <= n; i++) {
      await Future.delayed(Duration(milliseconds: 5));
      yield 'tick $i/$n'.rpc;
    }
  }
}

final class _BrokenService extends RpcResponderContract {
  _BrokenService() : super('BrokenService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Fail',
      handler: _fail,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _fail(RpcString request, {RpcContext? context}) async {
    throw StateError('Intentional failure for demo: ${request.value}');
  }
}
