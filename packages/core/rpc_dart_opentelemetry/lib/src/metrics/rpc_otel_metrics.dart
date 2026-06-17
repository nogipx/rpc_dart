// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Counter, Meter;
import 'package:opentelemetry/api.dart' show Attribute;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_status_names.dart';

/// Records RPC call metrics via OpenTelemetry Metrics API (experimental).
///
/// Instruments follow OpenTelemetry semantic conventions for RPC
/// (https://opentelemetry.io/docs/specs/semconv/rpc/rpc-metrics/):
///
/// - `rpc.server.requests` — Counter. One increment per completed call,
///   regardless of success or failure. The outcome is encoded in the
///   `rpc.grpc.status_code` attribute (numeric gRPC code, 0 = OK).
/// - `rpc.server.duration` — Counter (ms). Running sum of the measured call
///   duration, labelled identically. Every published `opentelemetry` version
///   up to and including the latest (0.18.11, checked 2026-06) exposes only
///   [Meter.createCounter] — there is no Histogram or UpDownCounter instrument
///   on [Meter] — so duration is recorded as a sum counter.
///   TODO(#6): switch to a Histogram (createHistogram/record) once the Workiva
///   `opentelemetry` package exposes one. Still blocked upstream as of 0.18.11.
///   A sum counter loses the distribution (no percentiles) but at least makes
///   the measured time observable instead of discarding it.
class RpcOtelMetrics {
  final Counter<int> _requests;
  final Counter<int> _durationMs;

  RpcOtelMetrics({required Meter meter})
      : _requests = meter.createCounter<int>(
          'rpc.server.requests',
          description:
              'Count of RPC calls handled by the server, labelled by status_code.',
          unit: '{call}',
        ),
        _durationMs = meter.createCounter<int>(
          'rpc.server.duration',
          description:
              'Running sum of RPC call durations in milliseconds, labelled by '
              'status_code.',
          unit: 'ms',
        );

  /// Records one finished RPC call.
  ///
  /// [statusCode] is the gRPC numeric status (0 = OK), emitted directly as the
  /// `rpc.grpc.status_code` attribute per semconv.
  ///
  /// [duration] is added to the `rpc.server.duration` sum counter (in ms).
  void recordCall(
    RpcMiddlewareContext call, {
    required int statusCode,
    required Duration duration,
  }) {
    final attributes = _attributes(call, statusCode);
    _requests.add(1, attributes: attributes);
    _durationMs.add(duration.inMilliseconds, attributes: attributes);
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