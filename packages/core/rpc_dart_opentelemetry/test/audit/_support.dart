// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart' as api;
import 'package:opentelemetry/sdk.dart' as sdk;
import 'package:rpc_dart/rpc_dart.dart';

/// Collects every exported (ended) span in memory for assertions.
class InMemorySpanExporter implements sdk.SpanExporter {
  final List<sdk.ReadOnlySpan> spans = [];
  var _stopped = false;

  @override
  void export(List<sdk.ReadOnlySpan> spans) {
    if (_stopped) return;
    this.spans.addAll(spans);
  }

  @override
  // ignore: deprecated_member_use
  void forceFlush() {}

  @override
  void shutdown() => _stopped = true;
}

/// Builds a tracer wired to an [InMemorySpanExporter] via a SimpleSpanProcessor.
({
  api.Tracer tracer,
  InMemorySpanExporter exporter,
  sdk.TracerProviderBase provider,
})
buildTracer() {
  final exporter = InMemorySpanExporter();
  final provider = sdk.TracerProviderBase(
    processors: [sdk.SimpleSpanProcessor(exporter)],
  );
  final tracer = provider.getTracer('audit-test');
  return (tracer: tracer, exporter: exporter, provider: provider);
}

/// Minimal real endpoint so we can construct an [RpcMiddlewareContext].
/// The interceptor never touches transport behaviour; it only reads
/// serviceName/methodName/context.
RpcMiddlewareContext buildCall({
  String service = 'TestService',
  String method = 'testMethod',
  RpcContext? context,
}) {
  final (_, serverTransport) = RpcInMemoryTransport.pair();
  final endpoint = RpcResponderEndpoint(transport: serverTransport);
  return RpcMiddlewareContext(
    endpoint: endpoint,
    serviceName: service,
    methodName: method,
    context: context ?? RpcContext.empty(),
  );
}
