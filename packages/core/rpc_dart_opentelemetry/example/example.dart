// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: avoid_print

import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

/// Example: wiring up rpc_dart_opentelemetry with a local OTLP collector.
///
/// Prerequisites (Docker):
///   docker run -p 4317:4317 otel/opentelemetry-collector-contrib
void main() async {
  // -------------------------------------------------------------------------
  // 1. Bootstrap OTel SDK
  //    ConsoleExporter prints spans to stdout — swap for CollectorExporter in prod.
  // -------------------------------------------------------------------------
  final exporter = ConsoleExporter();
  final processor = SimpleSpanProcessor(exporter);

  final tracerProvider = TracerProviderBase(processors: [processor]);
  registerGlobalTracerProvider(tracerProvider);

  // For production OTLP export (requires `opentelemetry_exporter_otlp_grpc` or similar):
  // final exporter = CollectorExporter(Uri.parse('http://localhost:4317'));

  // -------------------------------------------------------------------------
  // 2. Build the interceptor
  // -------------------------------------------------------------------------
  final tracer = globalTracerProvider.getTracer('my-service', version: '1.0.0');

  final otelInterceptor = OtelRpcInterceptor(tracer: tracer);

  // -------------------------------------------------------------------------
  // 3. Register on your endpoint
  // -------------------------------------------------------------------------
  //
  // final endpoint = MyResponderEndpoint(transport: ...)
  //   ..addInterceptor(otelInterceptor);
  //
  // Every RPC call will now produce a trace span automatically.

  print('OtelRpcInterceptor ready: $otelInterceptor');

  // -------------------------------------------------------------------------
  // 4. Client side — register OtelRpcClientInterceptor on the caller endpoint
  //    so every outgoing call gets a CLIENT span and W3C headers automatically.
  // -------------------------------------------------------------------------
  //
  // final callerEndpoint = MyCallerEndpoint(transport: ...)
  //   ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer));
  //
  // For ad-hoc one-off calls without an interceptor:
  //   final outgoingCtx = RpcOtelPropagator.inject(RpcContext.empty());
  //   final response = await callerEndpoint.myMethod(outgoingCtx, request);

  // -------------------------------------------------------------------------
  // 5. Accessing the active span inside a handler (optional enrichment)
  // -------------------------------------------------------------------------
  //
  // Future<MyResponse> handle(RpcContext ctx, MyRequest req) async {
  //   final span = ctx.getValue(OtelRpcKeys.span) as Span?;
  //   span?.setAttribute(Attribute.fromString('user.id', req.userId));
  //   ...
  // }

  // -------------------------------------------------------------------------
  // 6. Graceful shutdown — flush and release OTel SDK resources.
  //    Always call this before process exit so buffered spans are exported.
  // -------------------------------------------------------------------------
  tracerProvider.shutdown();
}
