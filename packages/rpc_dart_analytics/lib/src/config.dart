import 'package:licensify/licensify.dart';
import 'package:meta/meta.dart';

/// Immutable runtime configuration for [RpcAnalytics].
@immutable
class RpcAnalyticsConfig {
  /// Creates configuration for the analytics runtime.
  const RpcAnalyticsConfig({
    required this.licenseKey,
    required this.databasePath,
    this.enabledByDefault = true,
    this.logSqlStatements = false,
  }) : assert(databasePath != '', 'databasePath must not be empty');

  /// The application-level Licensify key required for the analytics runtime.
  final LicensifyPublicKey licenseKey;

  /// Absolute path to the encrypted SQLite database on the device.
  final String databasePath;

  /// Controls the initial enabled state when the worker spins up.
  final bool enabledByDefault;

  /// Enables verbose SQL logging on the worker side.
  final bool logSqlStatements;
}
