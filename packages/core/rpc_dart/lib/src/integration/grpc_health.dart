// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import '../codec/_index.dart';
import '../contracts/_index.dart';
import '../core/errors.dart' show RpcStatusException;
import '../core/protobuf.dart';
import '../core/protocol.dart' show RpcStatus;

// ---------------------------------------------------------------------------
// gRPC Health Checking Protocol (grpc.health.v1)
//
// Spec: https://github.com/grpc/grpc/blob/master/doc/health-checking.md
// ---------------------------------------------------------------------------

/// gRPC serving status per the health checking protocol.
///
/// Open: it mirrors a protobuf enum, which can grow, so a minor release may
/// add a value and a `switch` keeps a default.
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
///
/// On the wire it is the protobuf `grpc.health.v1.HealthCheckRequest`
/// (`string service = 1`), so any gRPC health client can send it.
final class GrpcHealthCheckRequest {
  /// The fully-qualified service name to check.
  final String service;

  /// Creates a [GrpcHealthCheckRequest].
  const GrpcHealthCheckRequest({this.service = ''});

  /// Protobuf codec for [GrpcHealthCheckRequest].
  static const IRpcCodec<GrpcHealthCheckRequest> codec =
      RpcBinaryCodec<GrpcHealthCheckRequest>(
        toBytes: _encode,
        fromBytes: _decode,
      );

  static Uint8List _encode(GrpcHealthCheckRequest request) {
    if (request.service.isEmpty) return Uint8List(0);
    return (RpcProtoWriter()..writeStringField(1, request.service)).toBytes();
  }

  static GrpcHealthCheckRequest _decode(Uint8List bytes) {
    final reader = RpcProtoReader(bytes);
    var service = '';
    while (!reader.atEnd) {
      final (:field, :wireType) = reader.readTag();
      if (field == 1 && wireType == RpcProtoWireType.lengthDelimited) {
        service = reader.readString();
      } else {
        reader.skip(wireType);
      }
    }
    return GrpcHealthCheckRequest(service: service);
  }
}

/// Health check response carrying the [status] of a service.
///
/// On the wire it is the protobuf `grpc.health.v1.HealthCheckResponse`
/// (`ServingStatus status = 1`).
final class GrpcHealthCheckResponse {
  /// The serving status of the queried service.
  final GrpcServingStatus status;

  /// Creates a [GrpcHealthCheckResponse].
  const GrpcHealthCheckResponse({required this.status});

  /// Protobuf codec for [GrpcHealthCheckResponse].
  static const IRpcCodec<GrpcHealthCheckResponse> codec =
      RpcBinaryCodec<GrpcHealthCheckResponse>(
        toBytes: _encode,
        fromBytes: _decode,
      );

  static Uint8List _encode(GrpcHealthCheckResponse response) {
    final value = response.status.value;
    if (value == 0) return Uint8List(0);
    return (RpcProtoWriter()..writeVarintField(1, value)).toBytes();
  }

  static GrpcHealthCheckResponse _decode(Uint8List bytes) {
    final reader = RpcProtoReader(bytes);
    var value = 0;
    while (!reader.atEnd) {
      final (:field, :wireType) = reader.readTag();
      if (field == 1 && wireType == RpcProtoWireType.varint) {
        value = reader.readVarint();
      } else {
        reader.skip(wireType);
      }
    }
    return GrpcHealthCheckResponse(status: GrpcServingStatus.fromValue(value));
  }
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

  /// Asynchronous, so a listener may set a status itself: a synchronous
  /// broadcast controller throws on an event added while it delivers one.
  final StreamController<(String, GrpcServingStatus)> _changes =
      StreamController<(String, GrpcServingStatus)>.broadcast();

  /// Sets the serving status for [service].
  ///
  /// Empty string means the overall server status. After [dispose] the store
  /// still answers [getStatus], and nobody is notified.
  void setStatus(String service, GrpcServingStatus status) {
    _statuses[service] = status;
    _notify(service, status);
  }

  /// Returns the current status for [service], or null if not registered.
  GrpcServingStatus? getStatus(String service) => _statuses[service];

  /// Clears the status for [service].
  void clearStatus(String service) {
    _statuses.remove(service);
    _notify(service, GrpcServingStatus.serviceUnknown);
  }

  /// Clears all statuses.
  void clearAll() {
    final keys = _statuses.keys.toList();
    _statuses.clear();
    for (final key in keys) {
      _notify(key, GrpcServingStatus.serviceUnknown);
    }
  }

  void _notify(String service, GrpcServingStatus status) {
    if (!_changes.isClosed) _changes.add((service, status));
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
/// Implements the standard gRPC health checking protocol, protobuf on the
/// wire, so `grpc_health_probe` and Kubernetes gRPC probes can query it over
/// an HTTP/2 transport:
/// - `Check` — unary: returns current status for a service; an unknown one
///   fails with NOT_FOUND
/// - `Watch` — server stream: streams status changes for a service; an
///   unknown one reads SERVICE_UNKNOWN until it is registered
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

  /// Creates a [GrpcHealthCheckContract] backed by the given [status] store.
  GrpcHealthCheckContract(GrpcHealthServiceStatus status)
    : _status = status,
      super(grpcServiceName);

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
      // The protocol answers an unknown service with NOT_FOUND; SERVICE_UNKNOWN
      // is for Watch only.
      throw RpcStatusException(
        RpcStatus.notFound,
        'Unknown service: ${request.service}',
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
