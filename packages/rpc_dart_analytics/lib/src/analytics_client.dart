import 'dart:async';
import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

import 'analytics_worker.dart';
import 'config.dart';
import 'messages.dart';

/// High-level analytics facade consumed by Flutter applications.
class RpcAnalytics {
  RpcAnalytics._(
    this._caller,
    this._endpoint,
    this._killIsolate,
  );

  final _AnalyticsCaller _caller;
  final RpcCallerEndpoint _endpoint;
  final void Function() _killIsolate;

  bool _disposed = false;

  /// Spawns the analytics worker isolate and prepares the RPC stack.
  static Future<RpcAnalytics> initialize(RpcAnalyticsConfig config) async {
    final trimmed = config.licenseKeyPaserk.trim();
    // Validate the PASERK string eagerly so configuration errors surface early.
    LicensifyPublicKey.fromPaserk(paserk: trimmed);

    final spawnResult = await RpcIsolateTransport.spawn(
      entrypoint: analyticsWorkerEntrypoint,
      customParams: <String, dynamic>{
        'databasePath': config.databasePath,
        'licenseKeyPaserk': trimmed,
        'enabled': config.enabledByDefault,
        'logStatements': config.logSqlStatements,
        'diagnostics': config.diagnosticsOptions.toJson(),
      },
      debugName: 'rpc_dart_analytics_worker',
    );

    final endpoint = RpcCallerEndpoint(
      transport: spawnResult.transport,
      debugLabel: 'rpc_dart_analytics_client',
    );
    final caller = _AnalyticsCaller(endpoint);

    // Ensure the worker is fully initialized before returning control.
    await caller.getStatus();

    return RpcAnalytics._(
      caller,
      endpoint,
      spawnResult.kill,
    );
  }

  /// Records a new analytics event.
  Future<void> logEvent(
    String eventName, {
    Map<String, dynamic>? properties,
    DateTime? timestamp,
  }) async {
    _throwIfDisposed();
    final request = AnalyticsLogEventRequest(
      eventName: eventName,
      properties: properties,
      timestamp: (timestamp ?? DateTime.now()).toUtc(),
    );

    final ack = await _caller.logEvent(request);
    if (!ack.success && ack.message == 'disabled') {
      return;
    }

    if (!ack.success) {
      throw StateError(ack.message ?? 'Analytics event rejected');
    }
  }

  /// Updates the enabled state of the analytics worker.
  Future<AnalyticsStatusSnapshot> setEnabled(bool enabled) async {
    _throwIfDisposed();
    return _caller.setEnabled(AnalyticsSetEnabledRequest(enabled));
  }

  /// Returns the current storage snapshot.
  Future<AnalyticsStatusSnapshot> status() async {
    _throwIfDisposed();
    return _caller.getStatus();
  }

  /// Returns a diagnostics snapshot with recent buffered events.
  Future<AnalyticsDiagnosticsSnapshot> diagnostics() async {
    _throwIfDisposed();
    return _caller.getDiagnostics();
  }

  /// Fetches a batch of encrypted events ready to be uploaded.
  Future<AnalyticsUploadBatch> fetchForUpload({int limit = 50}) {
    _throwIfDisposed();
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be greater than zero');
    }

    return _caller.fetchForUpload(
      AnalyticsUploadFetchRequest(limit: limit),
    );
  }

  /// Removes uploaded events from local storage once the backend confirms.
  Future<void> acknowledgeUpload(Iterable<int> eventIds) async {
    _throwIfDisposed();
    final uniqueIds = eventIds.toSet().toList(growable: false);
    if (uniqueIds.isEmpty) {
      return;
    }

    await _caller.acknowledgeUpload(
      AnalyticsUploadAcknowledgeRequest(eventIds: uniqueIds),
    );
  }

  /// Convenience helper that iterates through stored events and uploads them.
  ///
  /// The provided [uploader] receives the encrypted batch; once it completes
  /// without throwing, the events are removed from local storage. Returns the
  /// total number of uploaded events.
  Future<int> uploadPendingEvents(
    Future<void> Function(List<AnalyticsUploadEnvelope> events) uploader, {
    int batchSize = 50,
  }) async {
    _throwIfDisposed();
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }

    var uploaded = 0;
    while (true) {
      final batch = await fetchForUpload(limit: batchSize);
      final events = batch.events;
      if (events.isEmpty) {
        break;
      }

      await uploader(events);
      await acknowledgeUpload(events.map((e) => e.id));
      uploaded += events.length;

      if (!batch.hasMore) {
        break;
      }
    }

    return uploaded;
  }

  /// Removes all stored events without disabling the pipeline.
  Future<AnalyticsStatusSnapshot> clear() async {
    _throwIfDisposed();
    return _caller.clear();
  }

  /// Disables analytics and wipes the encrypted store.
  Future<AnalyticsStatusSnapshot> disableAndClear() async {
    _throwIfDisposed();
    return _caller.disableAndClear();
  }

  /// Gracefully shuts down the analytics worker and releases resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    try {
      await _caller.shutdown();
    } catch (_) {
      // Ignore shutdown errors – the isolate will be killed anyway.
    }

    await _endpoint.close();
    _killIsolate();
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RpcAnalytics has been disposed');
    }
  }
}

class _AnalyticsCaller extends RpcCallerContract {
  _AnalyticsCaller(RpcCallerEndpoint endpoint)
      : super(
          AnalyticsContract.serviceName,
          endpoint,
          dataTransferMode: RpcDataTransferMode.codec,
        );

  Future<AnalyticsAck> logEvent(AnalyticsLogEventRequest request) {
    return callUnary<AnalyticsLogEventRequest, AnalyticsAck>(
      methodName: AnalyticsContract.methodLogEvent,
      request: request,
      requestCodec: AnalyticsLogEventRequest.codec,
      responseCodec: AnalyticsAck.codec,
    );
  }

  Future<AnalyticsStatusSnapshot> setEnabled(
    AnalyticsSetEnabledRequest request,
  ) {
    return callUnary<AnalyticsSetEnabledRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodSetEnabled,
      request: request,
      requestCodec: AnalyticsSetEnabledRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
    );
  }

  Future<AnalyticsStatusSnapshot> clear() {
    return callUnary<AnalyticsClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodClear,
      request: const AnalyticsClearRequest(),
      requestCodec: AnalyticsClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
    );
  }

  Future<AnalyticsStatusSnapshot> disableAndClear() {
    return callUnary<AnalyticsDisableAndClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodDisableAndClear,
      request: const AnalyticsDisableAndClearRequest(),
      requestCodec: AnalyticsDisableAndClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
    );
  }

  Future<AnalyticsStatusSnapshot> getStatus() {
    return callUnary<AnalyticsClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodGetStatus,
      request: const AnalyticsClearRequest(),
      requestCodec: AnalyticsClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
    );
  }

  Future<AnalyticsDiagnosticsSnapshot> getDiagnostics() {
    return callUnary<AnalyticsDiagnosticsRequest, AnalyticsDiagnosticsSnapshot>(
      methodName: AnalyticsContract.methodDiagnostics,
      request: const AnalyticsDiagnosticsRequest(),
      requestCodec: AnalyticsDiagnosticsRequest.codec,
      responseCodec: AnalyticsDiagnosticsSnapshot.codec,
    );
  }

  Future<AnalyticsUploadBatch> fetchForUpload(
    AnalyticsUploadFetchRequest request,
  ) {
    return callUnary<AnalyticsUploadFetchRequest, AnalyticsUploadBatch>(
      methodName: AnalyticsContract.methodFetchForUpload,
      request: request,
      requestCodec: AnalyticsUploadFetchRequest.codec,
      responseCodec: AnalyticsUploadBatch.codec,
    );
  }

  Future<void> acknowledgeUpload(AnalyticsUploadAcknowledgeRequest request) {
    return callUnary<AnalyticsUploadAcknowledgeRequest, AnalyticsAck>(
      methodName: AnalyticsContract.methodAcknowledgeUpload,
      request: request,
      requestCodec: AnalyticsUploadAcknowledgeRequest.codec,
      responseCodec: AnalyticsAck.codec,
    ).then((value) {
      if (!value.success) {
        throw StateError(value.message ?? 'Failed to acknowledge analytics events');
      }
    });
  }

  Future<void> shutdown() async {
    await callUnary<AnalyticsShutdownRequest, AnalyticsAck>(
      methodName: AnalyticsContract.methodShutdown,
      request: const AnalyticsShutdownRequest(),
      requestCodec: AnalyticsShutdownRequest.codec,
      responseCodec: AnalyticsAck.codec,
    );
  }
}

