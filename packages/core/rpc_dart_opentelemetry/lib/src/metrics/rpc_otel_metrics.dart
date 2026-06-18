// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Counter, Meter;
import 'package:opentelemetry/api.dart' show Attribute;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_status_names.dart';

/// Which side of the RPC a metric measurement belongs to.
///
/// OTel RPC semantic conventions require distinct instrument namespaces for the
/// client and the server. A single [RpcOtelMetrics] instance can be shared by
/// both the client and the server interceptor (they both call [recordCall]), so
/// the call site must say which side it is so the measurement lands in the
/// correct `rpc.client.*` / `rpc.server.*` instrument.
enum RpcMetricSide { client, server }

/// Records RPC call metrics via OpenTelemetry Metrics API (experimental).
///
/// Instruments follow OpenTelemetry semantic conventions for RPC
/// (https://opentelemetry.io/docs/specs/semconv/rpc/rpc-metrics/):
///
/// - `rpc.server.requests` / `rpc.client.requests` — Counter. One increment per
///   completed call, regardless of success or failure. The outcome is encoded
///   in the `rpc.grpc.status_code` attribute (numeric gRPC code, 0 = OK).
/// - `rpc.server.duration` / `rpc.client.duration` — Counter (ms). Running sum
///   of the measured call duration, labelled identically. Every published
///   `opentelemetry` version up to and including the latest (0.18.11, checked
///   2026-06) exposes only [Meter.createCounter] — there is no Histogram or
///   UpDownCounter instrument on [Meter] — so duration is recorded as a sum
///   counter.
///   TODO(#6): switch to a Histogram (createHistogram/record) once the Workiva
///   `opentelemetry` package exposes one. Still blocked upstream as of 0.18.11.
///   A sum counter loses the distribution (no percentiles) but at least makes
///   the measured time observable instead of discarding it.
///
/// The same instance is used by both the server interceptor
/// ([OtelRpcInterceptor]) and the client interceptor
/// ([OtelRpcClientInterceptor]); [recordCall] takes a [RpcMetricSide] so each
/// call is recorded under the correct namespace.
class RpcOtelMetrics {
  final Counter<int> _serverRequests;
  final Counter<int> _serverDurationMs;
  final Counter<int> _clientRequests;
  final Counter<int> _clientDurationMs;

  RpcOtelMetrics({required Meter meter})
      : _serverRequests = meter.createCounter<int>(
          'rpc.server.requests',
          description:
              'Count of RPC calls handled by the server, labelled by status_code.',
          unit: '{call}',
        ),
        _serverDurationMs = meter.createCounter<int>(
          'rpc.server.duration',
          description:
              'Running sum of RPC call durations in milliseconds (server side), '
              'labelled by status_code.',
          unit: 'ms',
        ),
        _clientRequests = meter.createCounter<int>(
          'rpc.client.requests',
          description:
              'Count of RPC calls issued by the client, labelled by status_code.',
          unit: '{call}',
        ),
        _clientDurationMs = meter.createCounter<int>(
          'rpc.client.duration',
          description:
              'Running sum of RPC call durations in milliseconds (client side), '
              'labelled by status_code.',
          unit: 'ms',
        );

  /// Records one finished RPC call.
  ///
  /// [side] selects the instrument namespace: [RpcMetricSide.server] routes to
  /// the `rpc.server.*` instruments, [RpcMetricSide.client] to `rpc.client.*`.
  ///
  /// [statusCode] is the gRPC numeric status (0 = OK), emitted directly as the
  /// `rpc.grpc.status_code` attribute per semconv.
  ///
  /// [duration] is added to the matching `*.duration` sum counter (in ms).
  void recordCall(
    RpcMiddlewareContext call, {
    required int statusCode,
    required Duration duration,
    RpcMetricSide side = RpcMetricSide.server,
  }) {
    final attributes = _attributes(call, statusCode);
    final requests =
        side == RpcMetricSide.client ? _clientRequests : _serverRequests;
    final durationMs =
        side == RpcMetricSide.client ? _clientDurationMs : _serverDurationMs;
    requests.add(1, attributes: attributes);
    durationMs.add(duration.inMilliseconds, attributes: attributes);
  }

  List<Attribute> _attributes(RpcMiddlewareContext call, int statusCode) {
    return [
      Attribute.fromString('rpc.system', 'rpc_dart'),
      Attribute.fromString('rpc.service', call.serviceName),
      Attribute.fromString('rpc.method', call.methodName),
      // semconv: numeric gRPC status code (0..16).
      Attribute.fromInt('rpc.grpc.status_code', statusCode),
      Attribute.fromString('rpc.grpc.status', rpcGrpcStatusName(statusCode)),
    ];
  }
}