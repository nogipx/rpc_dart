@TestOn('vm || chrome')
library;

// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart' as api;
import 'package:opentelemetry/sdk.dart' as sdk;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '_support.dart';

/// One process's logger and tracer: what each side of a connection has.
final class _Process {
  _Process({required bool ids, bool ambient = false}) {
    final spanIds = ids ? LogSpanIds() : null;
    final provider = sdk.TracerProviderBase(
      processors: [sdk.SimpleSpanProcessor(exporter)],
      idGenerator: spanIds ?? const sdk.IdGenerator(),
    );
    tracer = provider.getTracer('test');
    output = LogControllerOtelOutput(tracer: tracer, ids: spanIds);
    logs = LogController(
      outputs: [output],
      ambientParent: ambient ? otelTraceparent : null,
    );
  }

  final exporter = InMemorySpanExporter();
  late final api.Tracer tracer;
  late final LogControllerOtelOutput output;
  late final LogController logs;

  void dispose() {
    logs.dispose();
    output.dispose();
  }
}

void main() {
  test('a span another process opens with a traceparent is a child of that '
      'span, in its OTel trace', () {
    final host = _Process(ids: true);
    final peer = _Process(ids: true);
    final call = host.logs.scope('host').startSpan('call');
    final serve = peer.logs
        .scope('peer')
        .startSpan('serve', parent: call.traceparent);
    serve.end();
    call.end();

    final there = peer.exporter.spans.single;
    final here = host.exporter.spans.single;
    expect('${here.spanContext.spanId}', call.spanId);
    expect('${here.spanContext.traceId}', call.traceId);
    expect('${there.spanContext.traceId}', '${here.spanContext.traceId}');
    expect('${there.parentSpanId}', '${here.spanContext.spanId}');
    expect('${there.spanContext.spanId}', serve.spanId);
    host.dispose();
    peer.dispose();
  });

  test('within a process a child still nests under its open parent', () {
    final p = _Process(ids: true);
    final outer = p.logs.scope('api').startSpan('outer');
    final inner = outer.startSpan('inner')..end();
    outer.end();
    final spans = {for (final s in p.exporter.spans) s.name: s};
    expect(
      '${spans['inner']!.parentSpanId}',
      '${spans['outer']!.spanContext.spanId}',
    );
    expect('${spans['inner']!.spanContext.spanId}', inner.spanId);
    p.dispose();
  });

  test('a span of the app beside the log spans keeps ids of its own', () {
    final ids = LogSpanIds();
    final exporter = InMemorySpanExporter();
    final provider = sdk.TracerProviderBase(
      processors: [sdk.SimpleSpanProcessor(exporter)],
      idGenerator: ids,
    );
    final tracer = provider.getTracer('test');
    final output = LogControllerOtelOutput(tracer: tracer, ids: ids);
    final logs = LogController(outputs: [output]);
    final logged = logs.scope('api').startSpan('logged')..end();
    tracer.startSpan('own').end();
    final own = exporter.spans.singleWhere((s) => s.name == 'own');
    expect('${own.spanContext.spanId}', isNot(logged.spanId));
    expect('${own.spanContext.traceId}', isNot(logged.traceId));
    expect(own.spanContext.isValid, isTrue);
    logs.dispose();
    output.dispose();
  });

  test('inside an RPC span a log span is its child, and a remote child of '
      'the log span finds it', () {
    final host = _Process(ids: true, ambient: true);
    final peer = _Process(ids: true);
    final rpc = host.tracer.startSpan('Service/method');
    final token = api.Context.attach(
      api.contextWithSpan(api.Context.current, rpc),
    );
    final call = host.logs.scope('host').startSpan('call');
    api.Context.detach(token);
    peer.logs.scope('peer').startSpan('serve', parent: call.traceparent).end();
    call.end();
    rpc.end();

    final spans = {for (final s in host.exporter.spans) s.name: s};
    final logged = spans['call']!;
    expect('${logged.parentSpanId}', '${rpc.spanContext.spanId}');
    expect('${logged.spanContext.traceId}', '${rpc.spanContext.traceId}');
    expect(call.traceId, '${rpc.spanContext.traceId}');
    final there = peer.exporter.spans.single;
    expect('${there.spanContext.traceId}', '${rpc.spanContext.traceId}');
    expect('${there.parentSpanId}', '${logged.spanContext.spanId}');
    host.dispose();
    peer.dispose();
  });

  test('a span that answers a message links the span that said it', () {
    final p = _Process(ids: true);
    final said = p.logs.scope('chat').startSpan('said')..end();
    p.logs.scope('api').startSpan('answer', links: [said.traceparent!]).end();
    final answer = p.exporter.spans.singleWhere((s) => s.name == 'answer');
    final link = answer.links.single.context;
    expect('${link.spanId}', said.spanId);
    expect('${link.traceId}', said.traceId);
    expect('${answer.spanContext.traceId}', isNot(said.traceId));
    p.dispose();
  });

  test('without LogSpanIds a remote parent is still taken, by its ids', () {
    final peer = _Process(ids: false);
    const parent = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
    peer.logs.scope('peer').startSpan('serve', parent: parent).end();
    final there = peer.exporter.spans.single;
    expect('${there.spanContext.traceId}', '0af7651916cd43dd8448eb211c80319c');
    expect('${there.parentSpanId}', 'b7ad6b7169203331');
    peer.dispose();
  });
}
