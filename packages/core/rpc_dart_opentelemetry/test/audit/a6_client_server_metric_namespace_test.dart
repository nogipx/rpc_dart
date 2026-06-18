@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart';
// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Counter, Meter;
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

/// Counter that records every value it receives, keyed by instrument name.
class _RecordingCounter implements Counter<int> {
  final String name;
  final List<int> values = [];
  _RecordingCounter(this.name);

  @override
  void add(int value, {List<Attribute>? attributes, Context? context}) {
    values.add(value);
  }
}

/// Meter that hands out and tracks recording counters by name.
class _RecordingMeter implements Meter {
  final Map<String, _RecordingCounter> counters = {};

  @override
  Counter<T> createCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  }) {
    final c = _RecordingCounter(name);
    counters[name] = c;
    return c as Counter<T>;
  }

  bool hasValues(String name) => (counters[name]?.values.isNotEmpty) ?? false;
}

void main() {
  test('server interceptor records under rpc.server.* only', () async {
    final meter = _RecordingMeter();
    final metrics = RpcOtelMetrics(meter: meter);
    final t = buildTracer();
    final interceptor = OtelRpcInterceptor(tracer: t.tracer, metrics: metrics);

    await interceptor.interceptUnary<String, String>(
      buildCall(),
      'req',
      (ctx, req) async => 'res',
    );

    expect(meter.hasValues('rpc.server.requests'), isTrue);
    expect(meter.hasValues('rpc.server.duration'), isTrue);
    expect(
      meter.hasValues('rpc.client.requests'),
      isFalse,
      reason: 'server call must not touch the client namespace',
    );
    expect(meter.hasValues('rpc.client.duration'), isFalse);
  });

  test('client interceptor records under rpc.client.* only', () async {
    final meter = _RecordingMeter();
    final metrics = RpcOtelMetrics(meter: meter);
    final t = buildTracer();
    final interceptor = OtelRpcClientInterceptor(
      tracer: t.tracer,
      metrics: metrics,
    );

    await interceptor.interceptUnary<String, String>(
      buildCall(),
      'req',
      (ctx, req) async => 'res',
    );

    expect(meter.hasValues('rpc.client.requests'), isTrue);
    expect(meter.hasValues('rpc.client.duration'), isTrue);
    expect(
      meter.hasValues('rpc.server.requests'),
      isFalse,
      reason:
          'client call must not be recorded under rpc.server.* '
          '(OTel semconv violation)',
    );
    expect(meter.hasValues('rpc.server.duration'), isFalse);
  });

  test('shared metrics instance separates the two sides', () async {
    final meter = _RecordingMeter();
    final metrics = RpcOtelMetrics(meter: meter);
    final t = buildTracer();
    final server = OtelRpcInterceptor(tracer: t.tracer, metrics: metrics);
    final client = OtelRpcClientInterceptor(tracer: t.tracer, metrics: metrics);

    await server.interceptUnary<String, String>(
      buildCall(),
      'req',
      (ctx, req) async => 'res',
    );
    await client.interceptUnary<String, String>(
      buildCall(),
      'req',
      (ctx, req) async => 'res',
    );

    expect(meter.counters['rpc.server.requests']!.values, [1]);
    expect(meter.counters['rpc.client.requests']!.values, [1]);
  });
}
