// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

/// Example: one trace from a caller to a responder over an in-memory
/// transport.
///
/// Spans are printed to stdout. To send them to an OpenTelemetry collector
/// instead, pass its OTLP/HTTP traces endpoint to [bootstrapTracing]:
///
///   docker run -p 4318:4318 otel/opentelemetry-collector-contrib
///   bootstrapTracing(otlpTraces: Uri.parse('http://localhost:4318/v1/traces'))
///
/// `CollectorExporter` ships in `package:opentelemetry/sdk.dart` and sends
/// OTLP over HTTP with protobuf, so use the HTTP port 4318, not gRPC 4317.
TracerProviderBase bootstrapTracing({Uri? otlpTraces}) {
  final provider = TracerProviderBase(
    processors: [
      if (otlpTraces == null)
        SimpleSpanProcessor(ConsoleExporter())
      else
        BatchSpanProcessor(CollectorExporter(otlpTraces)),
    ],
  );
  registerGlobalTracerProvider(provider);
  return provider;
}

final class GreeterResponder extends RpcResponderContract {
  GreeterResponder() : super('Greeter');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _hello(RpcString request, {RpcContext? context}) async {
    // OtelRpcInterceptor stores the server span of this call in the context.
    final span = context?.getValue<Span>(OtelRpcKeys.span);
    span?.setAttribute(Attribute.fromString('greeting.name', request.value));
    return RpcString('Hello, ${request.value}');
  }
}

final class GreeterCaller extends RpcCallerContract {
  GreeterCaller(RpcCallerEndpoint endpoint) : super('Greeter', endpoint);

  Future<RpcString> hello(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'hello',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );
}

Future<void> main() async {
  final provider = bootstrapTracing();
  final tracer = globalTracerProvider.getTracer('greeter', version: '1.0.0');

  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();

  // Server side: one SERVER span per call, parented on the incoming
  // traceparent.
  final responder = RpcResponderEndpoint(transport: serverTransport)
    ..addInterceptor(OtelRpcInterceptor(tracer: tracer))
    ..registerServiceContract(GreeterResponder())
    ..start();

  // Client side: one CLIENT span per call, traceparent injected into the
  // outgoing metadata.
  final caller = RpcCallerEndpoint(transport: clientTransport)
    ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer));

  // One trace: client span Greeter/hello -> server span Greeter/hello.
  await GreeterCaller(caller).hello(const RpcString('Ada'));

  await caller.close();
  await responder.close();

  // Flush buffered spans before the process exits.
  provider.shutdown();
}
