import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/rpc_dart_data.dart';

import 'messages.dart';

/// Entry point invoked inside the analytics isolate.
void analyticsWorkerEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> customParams,
) {
  // Run async initialization without blocking isolate startup.
  // ignore: discarded_futures
  runZonedGuarded<Future<void>>(
    () async {
      final config = _WorkerBootstrapParams.fromMap(customParams);
      final storage = await AnalyticsStorageManager.open(
        databasePath: config.databasePath,
        publicKey: config.licenseKey,
        enabledByDefault: config.enabledByDefault,
        logSqlStatements: config.logSqlStatements,
      );

      final endpoint = RpcResponderEndpoint(
        transport: transport,
        debugLabel: 'rpc_dart_analytics_worker',
      );
      final responder = AnalyticsResponder(storage: storage);
      endpoint.registerServiceContract(responder);
      endpoint.start();
    },
    (error, stackTrace) {
      stderr.writeln('rpc_dart_analytics worker crashed: $error');
      stderr.writeln(stackTrace);
    },
  );
}

@immutable
class _WorkerBootstrapParams {
  const _WorkerBootstrapParams({
    required this.databasePath,
    required this.licenseKey,
    required this.enabledByDefault,
    required this.logSqlStatements,
  });

  factory _WorkerBootstrapParams.fromMap(Map<String, dynamic> raw) {
    final keyPaserk = raw['licenseKeyPaserk'];
    if (keyPaserk is! String || keyPaserk.trim().isEmpty) {
      throw ArgumentError('licenseKeyPaserk must be a non-empty string');
    }

    final licenseKey = LicensifyPublicKey.fromPaserk(paserk: keyPaserk.trim());

    final databasePath = raw['databasePath'] as String?;
    if (databasePath == null || databasePath.isEmpty) {
      throw ArgumentError('databasePath must be provided for analytics worker');
    }

    return _WorkerBootstrapParams(
      databasePath: databasePath,
      licenseKey: licenseKey,
      enabledByDefault: raw['enabled'] as bool? ?? true,
      logSqlStatements: raw['logStatements'] as bool? ?? false,
    );
  }

  final String databasePath;
  final LicensifyPublicKey licenseKey;
  final bool enabledByDefault;
  final bool logSqlStatements;
}

final class AnalyticsResponder extends RpcResponderContract {
  AnalyticsResponder({required AnalyticsStorageManager storage})
      : _storage = storage,
        super(
          AnalyticsContract.serviceName,
          dataTransferMode: RpcDataTransferMode.codec,
        );

  final AnalyticsStorageManager _storage;

  bool _disposed = false;

  @override
  void setup() {
    addUnaryMethod<AnalyticsLogEventRequest, AnalyticsAck>(
      methodName: AnalyticsContract.methodLogEvent,
      requestCodec: AnalyticsLogEventRequest.codec,
      responseCodec: AnalyticsAck.codec,
      handler: _handleLogEvent,
    );

    addUnaryMethod<AnalyticsSetEnabledRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodSetEnabled,
      requestCodec: AnalyticsSetEnabledRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
      handler: _handleSetEnabled,
    );

    addUnaryMethod<AnalyticsClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodClear,
      requestCodec: AnalyticsClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
      handler: _handleClear,
    );

    addUnaryMethod<AnalyticsDisableAndClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodDisableAndClear,
      requestCodec: AnalyticsDisableAndClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
      handler: _handleDisableAndClear,
    );

    addUnaryMethod<AnalyticsClearRequest, AnalyticsStatusSnapshot>(
      methodName: AnalyticsContract.methodGetStatus,
      requestCodec: AnalyticsClearRequest.codec,
      responseCodec: AnalyticsStatusSnapshot.codec,
      handler: (request, {context}) => _storage.snapshot(),
    );

    addUnaryMethod<AnalyticsShutdownRequest, AnalyticsAck>(
      methodName: AnalyticsContract.methodShutdown,
      requestCodec: AnalyticsShutdownRequest.codec,
      responseCodec: AnalyticsAck.codec,
      handler: _handleShutdown,
    );
  }

  Future<AnalyticsAck> _handleLogEvent(
    AnalyticsLogEventRequest request, {
    RpcContext? context,
  }) async {
    if (_disposed) {
      return const AnalyticsAck(
        success: false,
        message: 'analytics storage disposed',
      );
    }

    final accepted = await _storage.insertEvent(request);
    return AnalyticsAck(
      success: accepted,
      message: accepted ? 'stored' : 'disabled',
    );
  }

  Future<AnalyticsStatusSnapshot> _handleSetEnabled(
    AnalyticsSetEnabledRequest request, {
    RpcContext? context,
  }) {
    if (_disposed) {
      return Future.value(
        const AnalyticsStatusSnapshot(
          enabled: false,
          eventCount: 0,
        ),
      );
    }
    return _storage.setEnabled(request.enabled);
  }

  Future<AnalyticsStatusSnapshot> _handleClear(
    AnalyticsClearRequest request, {
    RpcContext? context,
  }) {
    if (_disposed) {
      return Future.value(
        const AnalyticsStatusSnapshot(
          enabled: false,
          eventCount: 0,
        ),
      );
    }
    return _storage.clear();
  }

  Future<AnalyticsStatusSnapshot> _handleDisableAndClear(
    AnalyticsDisableAndClearRequest request, {
    RpcContext? context,
  }) {
    if (_disposed) {
      return Future.value(
        const AnalyticsStatusSnapshot(
          enabled: false,
          eventCount: 0,
        ),
      );
    }
    return _storage.disableAndClear();
  }

  Future<AnalyticsAck> _handleShutdown(
    AnalyticsShutdownRequest request, {
    RpcContext? context,
  }) async {
    if (_disposed) {
      return const AnalyticsAck(success: true, message: 'already disposed');
    }

    await _storage.dispose();
    _disposed = true;
    return const AnalyticsAck(success: true, message: 'shutdown');
  }

  @override
  void dispose() {
    if (!_disposed) {
      // ignore: discarded_futures
      _storage.dispose();
      _disposed = true;
    }
    super.dispose();
  }
}

final class AnalyticsStorageManager {
  AnalyticsStorageManager._({
    required DriftDataStorageAdapter storage,
    required LicensifyPublicKey publicKey,
    required bool enabled,
  })  : _storage = storage,
        _publicKey = publicKey,
        _enabled = enabled;

  static Future<AnalyticsStorageManager> open({
    required String databasePath,
    required LicensifyPublicKey publicKey,
    required bool enabledByDefault,
    required bool logSqlStatements,
  }) async {
    final file = File(databasePath);
    file.parent.createSync(recursive: true);
    final adapter = DriftDataStorageAdapter.file(
      file,
      logStatements: logSqlStatements,
    );
    await adapter.ensureReady();
    final manager = AnalyticsStorageManager._(
      storage: adapter,
      publicKey: publicKey,
      enabled: enabledByDefault,
    );
    await manager._ensureSchema();
    return manager;
  }

  final DriftDataStorageAdapter _storage;
  final LicensifyPublicKey _publicKey;
  bool _enabled;
  bool _schemaReady = false;

  Future<void> _ensureSchema() async {
    if (_schemaReady) return;

    await _storage.database.customStatement(
      'CREATE TABLE IF NOT EXISTS analytics_events ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'created_at_ms INTEGER NOT NULL,'
      'encrypted_token TEXT NOT NULL'
      ')',
    );

    _schemaReady = true;
  }

  Future<bool> insertEvent(AnalyticsLogEventRequest request) async {
    if (!_enabled) {
      return false;
    }

    await _ensureSchema();
    final encryptedToken = await Licensify.encryptDataForPublicKey(
      data: <String, dynamic>{
        'event': request.eventName,
        'timestamp': request.timestamp.toUtc().toIso8601String(),
        if (request.properties != null) 'properties': request.properties!,
      },
      publicKey: _publicKey,
    );

    await _storage.database.customStatement(
      'INSERT INTO analytics_events (created_at_ms, encrypted_token) '
      'VALUES (?, ?)',
      <Object?>[
        DateTime.now().toUtc().millisecondsSinceEpoch,
        encryptedToken,
      ],
    );

    return true;
  }

  Future<AnalyticsStatusSnapshot> setEnabled(bool enabled) async {
    _enabled = enabled;
    return snapshot();
  }

  Future<AnalyticsStatusSnapshot> clear() async {
    await _ensureSchema();
    await _storage.database.customStatement('DELETE FROM analytics_events');
    return snapshot();
  }

  Future<AnalyticsStatusSnapshot> disableAndClear() async {
    _enabled = false;
    await _ensureSchema();
    await _storage.database.customStatement('DELETE FROM analytics_events');
    return snapshot();
  }

  Future<AnalyticsStatusSnapshot> snapshot() async {
    await _ensureSchema();
    final countRows = await _storage.database
        .customSelect('SELECT COUNT(*) AS cnt FROM analytics_events')
        .getSingle();
    final count = countRows.read<int>('cnt');

    DateTime? lastEventAt;
    if (count > 0) {
      final lastRow = await _storage.database
          .customSelect(
            'SELECT MAX(created_at_ms) AS last FROM analytics_events',
          )
          .getSingle();
      final lastValue = lastRow.read<int?>('last');
      if (lastValue != null) {
        lastEventAt =
            DateTime.fromMillisecondsSinceEpoch(lastValue, isUtc: true).toUtc();
      }
    }

    return AnalyticsStatusSnapshot(
      enabled: _enabled,
      eventCount: count,
      lastEventAt: lastEventAt,
    );
  }

  Future<void> dispose() async {
    await _storage.dispose();
  }
}
