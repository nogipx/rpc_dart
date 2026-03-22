// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Counter, Meter;
import 'package:opentelemetry/api.dart' show Attribute;
import 'package:rpc_dart/rpc_dart.dart';

/// Records RPC call metrics via OpenTelemetry Metrics API (experimental).
///
/// Instruments:
/// - `rpc_dart.calls.total`   — Counter, total calls per service/method/call_type
/// - `rpc_dart.errors.total`  — Counter, failed calls per service/method/call_type
///
/// Note: the OTel Dart Metrics API is currently marked `@experimental`.
/// Histogram (latency distribution) is not yet available in the Workiva package.
class RpcOtelMetrics {
  final Counter<int> _callsTotal;
  final Counter<int> _errorsTotal;

  RpcOtelMetrics({required Meter meter})
      : _callsTotal = meter.createCounter<int>(
          'rpc_dart.calls.total',
          description: 'Total number of RPC calls',
          unit: '{call}',
        ),
        _errorsTotal = meter.createCounter<int>(
          'rpc_dart.errors.total',
          description: 'Total number of failed RPC calls',
          unit: '{call}',
        );

  void recordCall(RpcMiddlewareContext call, Duration duration) {
    _callsTotal.add(1, attributes: _attributes(call));
  }

  void recordError(RpcMiddlewareContext call, Duration duration) {
    _callsTotal.add(1, attributes: _attributes(call));
    _errorsTotal.add(1, attributes: _attributes(call));
  }

  List<Attribute> _attributes(RpcMiddlewareContext call) {
    return [
      Attribute.fromString('rpc.system', 'rpc_dart'),
      Attribute.fromString('rpc.service', call.serviceName),
      Attribute.fromString('rpc.method', call.methodName),
    ];
  }
}
