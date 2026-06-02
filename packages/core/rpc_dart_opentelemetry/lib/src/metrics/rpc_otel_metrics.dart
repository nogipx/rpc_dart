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
///   `rpc.grpc.status_code` attribute (`OK`, `UNAVAILABLE`, ...).
///
/// Pending (require unreleased OpenTelemetry Dart API surface):
/// - `rpc.server.duration` — Histogram (ms).
/// - `rpc.server.active_requests` — UpDownCounter / Gauge.
///
/// These will be added once the Workiva package exposes Histogram and
/// UpDownCounter; the interceptor already measures the elapsed time and
/// passes it here so the wiring point will not change.
class RpcOtelMetrics {
  final Counter<int> _requests;

  RpcOtelMetrics({required Meter meter})
      : _requests = meter.createCounter<int>(
          'rpc.server.requests',
          description:
              'Count of RPC calls handled by the server, labelled by status_code.',
          unit: '{call}',
        );

  /// Records one finished RPC call.
  ///
  /// [statusCode] is the gRPC numeric status (0 = OK). It is translated to
  /// the canonical uppercase name (`OK`, `UNAVAILABLE`, ...) before being
  /// emitted as an attribute — a bounded, well-known set with 17 values.
  ///
  /// [duration] is accepted today for API stability; it will be recorded as
  /// a histogram once the OpenTelemetry Dart API exposes one.
  void recordCall(
    RpcMiddlewareContext call, {
    required int statusCode,
    required Duration duration,
  }) {
    _requests.add(1, attributes: _attributes(call, statusCode));
  }

  List<Attribute> _attributes(RpcMiddlewareContext call, int statusCode) {
    return [
      Attribute.fromString('rpc.system', 'rpc_dart'),
      Attribute.fromString('rpc.service', call.serviceName),
      Attribute.fromString('rpc.method', call.methodName),
      Attribute.fromString(
        'rpc.grpc.status_code',
        rpcGrpcStatusName(statusCode),
      ),
    ];
  }
}