// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Bridges W3C Trace Context (traceparent/tracestate) between OTel and RpcContext headers.
///
/// Use [extract] on the server side to restore the parent span from incoming headers.
/// Use [inject] on the client side to propagate the active span to outgoing headers.
abstract final class RpcOtelPropagator {
  static final _propagator = W3CTraceContextPropagator();

  /// Extracts OTel [Context] from [RpcContext] headers (server-side / incoming call).
  ///
  /// Returns the restored context with parent span information, or [Context.current]
  /// if no traceparent header is present.
  static Context extract(RpcContext rpcContext) {
    return _propagator.extract(
      Context.current,
      rpcContext.headers,
      _RpcContextGetter(),
    );
  }

  /// Injects the current OTel span into [RpcContext] headers (client-side / outgoing call).
  ///
  /// Returns a new [RpcContext] with traceparent (and tracestate if present) headers added.
  static RpcContext inject(RpcContext rpcContext, {Context? context}) {
    final carrier = <String, String>{};
    _propagator.inject(
      context ?? Context.current,
      carrier,
      _RpcContextSetter(),
    );
    if (carrier.isEmpty) return rpcContext;
    return rpcContext.withAdditionalHeaders(carrier);
  }
}

/// TextMapGetter that reads from a `Map<String, String>`.
class _RpcContextGetter implements TextMapGetter<Map<String, String>> {
  @override
  String? get(Map<String, String> carrier, String key) => carrier[key];

  @override
  Iterable<String> keys(Map<String, String> carrier) => carrier.keys;
}

/// TextMapSetter that writes into a `Map<String, String>`.
class _RpcContextSetter implements TextMapSetter<Map<String, String>> {
  @override
  void set(Map<String, String> carrier, String key, String value) {
    carrier[key] = value;
  }
}

/// The OTel span active in [context] (default `Context.current`) as a W3C
/// `traceparent`, or null when there is none: give it to
/// `LogController(ambientParent: otelTraceparent)`, and a log span started
/// with no parent of its own inside an RPC handler is a child of the
/// server's span, with ids the OTel trace has.
String? otelTraceparent([Context? context]) {
  final c = spanContextFromContext(context ?? Context.current);
  if (!c.isValid) return null;
  final flags = c.traceFlags.toRadixString(16).padLeft(2, '0');
  return '00-${c.traceId}-${c.spanId}-$flags';
}
