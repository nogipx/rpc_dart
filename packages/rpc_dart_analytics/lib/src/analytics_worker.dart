import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
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
        encryptionKey: config.encryptionKey,
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
    required this.encryptionKey,
    required this.enabledByDefault,
    required this.logSqlStatements,
  });

  factory _WorkerBootstrapParams.fromMap(Map<String, dynamic> raw) {
    final keyData = raw['encryptionKey'];
    late final Uint8List encryptionKey;
    if (keyData is Uint8List) {
      encryptionKey = Uint8List.fromList(keyData);
    } else if (keyData is List<int>) {
      encryptionKey = Uint8List.fromList(keyData);
    } else {
      throw ArgumentError('Invalid encryptionKey payload: ${keyData.runtimeType}');
    }

    final databasePath = raw['databasePath'] as String?;
    if (databasePath == null || databasePath.isEmpty) {
      throw ArgumentError('databasePath must be provided for analytics worker');
    }

    return _WorkerBootstrapParams(
      databasePath: databasePath,
      encryptionKey: encryptionKey,
      enabledByDefault: raw['enabled'] as bool? ?? true,
      logSqlStatements: raw['logStatements'] as bool? ?? false,
    );
  }

  final String databasePath;
  final Uint8List encryptionKey;
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
    required bool enabled,
  })  : _storage = storage,
        _enabled = enabled;

  static Future<AnalyticsStorageManager> open({
    required String databasePath,
    required Uint8List encryptionKey,
    required bool enabledByDefault,
    required bool logSqlStatements,
  }) async {
    final file = File(databasePath);
    file.parent.createSync(recursive: true);
    final adapter = DriftDataStorageAdapter.file(
      file,
      logStatements: logSqlStatements,
      sqlCipherKey: SqlCipherKey.fromBytes(
        keyBytes: Uint8List.fromList(encryptionKey),
      ),
    );
    await adapter.ensureReady();
    final manager = AnalyticsStorageManager._(
      storage: adapter,
      enabled: enabledByDefault,
    );
    await manager._ensureSchema();
    return manager;
  }

  final DriftDataStorageAdapter _storage;
  bool _enabled;
  bool _schemaReady = false;

  Future<void> _ensureSchema() async {
    if (_schemaReady) return;

    await _storage.database.customStatement(
      'CREATE TABLE IF NOT EXISTS analytics_events ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'event_name TEXT NOT NULL,'
      'properties_json TEXT,'
      'created_at_ms INTEGER NOT NULL'
      ')',
    );

    await _storage.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_analytics_events_created_at '
      'ON analytics_events(created_at_ms)',
    );

    _schemaReady = true;
  }

  Future<bool> insertEvent(AnalyticsLogEventRequest request) async {
    if (!_enabled) {
      return false;
    }

    await _ensureSchema();
    final payload = request.properties == null
        ? null
        : jsonEncode(request.properties);

    await _storage.database.customStatement(
      'INSERT INTO analytics_events (event_name, properties_json, created_at_ms) '
      'VALUES (?, ?, ?)',
      <Object?>[
        request.eventName,
        payload,
        request.timestamp.toUtc().millisecondsSinceEpoch,
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
