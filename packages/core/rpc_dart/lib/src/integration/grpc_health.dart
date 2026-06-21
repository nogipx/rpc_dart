// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../codec/_index.dart';
import '../contracts/_index.dart';

// ---------------------------------------------------------------------------
// gRPC Health Checking Protocol (grpc.health.v1)
//
// Spec: https://github.com/grpc/grpc/blob/master/doc/health-checking.md
// ---------------------------------------------------------------------------

/// gRPC serving status per the health checking protocol.
enum GrpcServingStatus {
  /// Status is not known.
  unknown(0),

  /// The service is currently serving.
  serving(1),

  /// The service is not currently serving.
  notServing(2),

  /// Used by Watch only. The requested service is not registered.
  serviceUnknown(3);

  const GrpcServingStatus(this.value);

  /// Wire value per the gRPC health proto.
  final int value;

  /// Creates a [GrpcServingStatus] from its wire [v]alue.
  static GrpcServingStatus fromValue(int v) => switch (v) {
    0 => unknown,
    1 => serving,
    2 => notServing,
    3 => serviceUnknown,
    _ => unknown,
  };
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Health check request. [service] is the fully-qualified service name
/// (e.g. `"grpc.health.v1.Health"`). Empty string means the overall server.
final class GrpcHealthCheckRequest implements IRpcSerializable {
  /// The fully-qualified service name to check.
  final String service;

  /// Creates a [GrpcHealthCheckRequest].
  const GrpcHealthCheckRequest({this.service = ''});

  /// Deserializes from JSON.
  factory GrpcHealthCheckRequest.fromJson(Map<String, dynamic> json) {
    final s = json['service'];
    return GrpcHealthCheckRequest(service: s is String ? s : '');
  }

  @override
  Map<String, dynamic> toJson() => {'service': service};

  /// Codec for [GrpcHealthCheckRequest].
  static RpcCodec<GrpcHealthCheckRequest> get codec =>
      RpcCodec<GrpcHealthCheckRequest>(GrpcHealthCheckRequest.fromJson);
}

/// Health check response carrying the [status] of a service.
final class GrpcHealthCheckResponse implements IRpcSerializable {
  /// The serving status of the queried service.
  final GrpcServingStatus status;

  /// Creates a [GrpcHealthCheckResponse].
  const GrpcHealthCheckResponse({required this.status});

  /// Deserializes from JSON.
  factory GrpcHealthCheckResponse.fromJson(Map<String, dynamic> json) {
    final s = json['status'];
    final value = s is int ? s : 0;
    return GrpcHealthCheckResponse(status: GrpcServingStatus.fromValue(value));
  }

  @override
  Map<String, dynamic> toJson() => {'status': status.value};

  /// Codec for [GrpcHealthCheckResponse].
  static RpcCodec<GrpcHealthCheckResponse> get codec =>
      RpcCodec<GrpcHealthCheckResponse>(GrpcHealthCheckResponse.fromJson);
}

// ---------------------------------------------------------------------------
// Service status store
// ---------------------------------------------------------------------------

/// Manages per-service health status and notifies watchers on changes.
///
/// Thread-safe for single-isolate use. Shared between the health contract
/// and the application code that updates statuses.
final class GrpcHealthServiceStatus {
  final Map<String, GrpcServingStatus> _statuses = {};
  final StreamController<(String, GrpcServingStatus)> _changes =
      StreamController<(String, GrpcServingStatus)>.broadcast(sync: true);

  /// Sets the serving status for [service].
  ///
  /// Empty string means the overall server status.
  void setStatus(String service, GrpcServingStatus status) {
    _statuses[service] = status;
    _changes.add((service, status));
  }

  /// Returns the current status for [service], or null if not registered.
  GrpcServingStatus? getStatus(String service) => _statuses[service];

  /// Clears the status for [service].
  void clearStatus(String service) {
    _statuses.remove(service);
    _changes.add((service, GrpcServingStatus.serviceUnknown));
  }

  /// Clears all statuses.
  void clearAll() {
    final keys = _statuses.keys.toList();
    _statuses.clear();
    for (final key in keys) {
      _changes.add((key, GrpcServingStatus.serviceUnknown));
    }
  }

  /// Stream of (service, status) changes for watchers.
  Stream<(String, GrpcServingStatus)> get changes => _changes.stream;

  /// Closes the change stream. Call on server shutdown.
  void dispose() {
    if (!_changes.isClosed) _changes.close();
  }
}

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

/// gRPC Health Checking service contract (`grpc.health.v1.Health`).
///
/// Implements the standard gRPC health checking protocol:
/// - `Check` — unary: returns current status for a service
/// - `Watch` — server stream: streams status changes for a service
///
/// Usage:
/// ```dart
/// final healthStatus = GrpcHealthServiceStatus();
/// healthStatus.setStatus('', GrpcServingStatus.serving); // overall server
/// healthStatus.setStatus('MyService', GrpcServingStatus.serving);
///
/// final healthContract = GrpcHealthCheckContract(healthStatus);
/// endpoint.registerServiceContract(healthContract);
/// ```
final class GrpcHealthCheckContract extends RpcResponderContract {
  /// Standard gRPC service name for health checking.
  static const String grpcServiceName = 'grpc.health.v1.Health';

  final GrpcHealthServiceStatus _status;

  /// Creates a [GrpcHealthCheckContract] backed by the given [_status] store.
  GrpcHealthCheckContract(this._status) : super(grpcServiceName);

  @override
  void setup() {
    addUnaryMethod<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
      methodName: 'Check',
      handler: _check,
      requestCodec: GrpcHealthCheckRequest.codec,
      responseCodec: GrpcHealthCheckResponse.codec,
      description: 'Returns the serving status of a service',
    );

    addServerStreamMethod<GrpcHealthCheckRequest, GrpcHealthCheckResponse>(
      methodName: 'Watch',
      handler: _watch,
      requestCodec: GrpcHealthCheckRequest.codec,
      responseCodec: GrpcHealthCheckResponse.codec,
      description: 'Streams status changes for a service',
    );
  }

  Future<GrpcHealthCheckResponse> _check(
    GrpcHealthCheckRequest request, {
    RpcContext? context,
  }) async {
    final status = _status.getStatus(request.service);
    if (status == null) {
      // Per gRPC spec: if service is not registered, return NOT_FOUND via
      // grpc-status. But since the contract layer returns a response (not
      // a trailer), we return SERVICE_UNKNOWN in the response body as a
      // fallback. The caller contract can inspect this status.
      //
      // For strict gRPC compliance, the endpoint-level error handling sends
      // grpc-status NOT_FOUND. However, returning a response here is more
      // compatible with non-gRPC transports.
      return const GrpcHealthCheckResponse(
        status: GrpcServingStatus.serviceUnknown,
      );
    }
    return GrpcHealthCheckResponse(status: status);
  }

  Stream<GrpcHealthCheckResponse> _watch(
    GrpcHealthCheckRequest request, {
    RpcContext? context,
  }) {
    final service = request.service;

    // IMPORTANT: do not use `async*` with a `yield` before `await for` --
    // on dart2js such a generator does not subscribe to the stream after the
    // first yield, and events are silently lost. Use a StreamController.
    late final StreamController<GrpcHealthCheckResponse> controller;
    StreamSubscription<(String, GrpcServingStatus)>? sub;

    controller = StreamController<GrpcHealthCheckResponse>(
      onListen: () {
        // Emit the current status immediately.
        final current = _status.getStatus(service);
        var lastStatus = current ?? GrpcServingStatus.serviceUnknown;
        controller.add(GrpcHealthCheckResponse(status: lastStatus));

        // Stream subsequent changes.
        sub = _status.changes.listen(
          (change) {
            final (changedService, newStatus) = change;
            if (changedService != service) return;
            if (newStatus == lastStatus) return;
            lastStatus = newStatus;
            controller.add(GrpcHealthCheckResponse(status: newStatus));
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );

    return controller.stream;
  }
}
