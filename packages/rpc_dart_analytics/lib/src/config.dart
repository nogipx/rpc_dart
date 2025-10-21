import 'package:meta/meta.dart';

/// Diagnostics settings that control developer tooling support.
@immutable
class RpcAnalyticsDiagnosticsOptions {
  /// Creates options for enabling the developer diagnostics pipeline.
  const RpcAnalyticsDiagnosticsOptions({
    this.enabled = false,
    this.maxEvents = 200,
  }) : assert(maxEvents > 0, 'maxEvents must be greater than zero');

  /// Convenience constructor that disables diagnostics entirely.
  const RpcAnalyticsDiagnosticsOptions.disabled()
      : enabled = false,
        maxEvents = 200;

  /// Whether diagnostics tooling is active.
  final bool enabled;

  /// Maximum number of recent events kept in memory for inspection.
  final int maxEvents;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'enabled': enabled,
      'maxEvents': maxEvents,
    };
  }
}

/// Immutable runtime configuration for [RpcAnalytics].
@immutable
class RpcAnalyticsConfig {
  /// Creates configuration for the analytics runtime.
  const RpcAnalyticsConfig({
    required this.licenseKeyPaserk,
    required this.databasePath,
    this.enabledByDefault = true,
    this.logSqlStatements = false,
    this.diagnosticsOptions = const RpcAnalyticsDiagnosticsOptions.disabled(),
  })  : assert(databasePath != '', 'databasePath must not be empty'),
        assert(
          licenseKeyPaserk.trim().startsWith('k4.public'),
          'licenseKeyPaserk must be a PASERK k4.public string',
        );

  /// The PASERK `k4.public` string required for the analytics runtime.
  final String licenseKeyPaserk;

  /// Absolute path to the encrypted SQLite database on the device.
  final String databasePath;

  /// Controls the initial enabled state when the worker spins up.
  final bool enabledByDefault;

  /// Enables verbose SQL logging on the worker side.
  final bool logSqlStatements;

  /// Controls developer diagnostics buffers and APIs.
  final RpcAnalyticsDiagnosticsOptions diagnosticsOptions;
}
