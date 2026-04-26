// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// Typed, read-only view over environment variables.
///
/// Wraps [Platform.environment] (or a custom map for testing) and adds
/// helpers for parsing ints, bools, durations, and comma-separated lists.
///
/// Example in a module:
/// ```dart
/// @override
/// void configureWithEnv(RpcContainer container, RpcEnvConfig env) {
///   final dbUrl   = env.require('DATABASE_URL');
///   final poolMax = env.getInt('DB_POOL_MAX') ?? 10;
///   final debug   = env.getBool('DEBUG');
///   final timeout = env.getDuration('REQUEST_TIMEOUT') ?? Duration(seconds: 30);
///   container.registerSingleton<DbPool>(DbPool(dbUrl, maxConnections: poolMax));
/// }
/// ```
class RpcEnvConfig {
  final Map<String, String> _env;

  /// Creates an [RpcEnvConfig] backed by [Platform.environment].
  RpcEnvConfig() : _env = Platform.environment;

  /// Creates an [RpcEnvConfig] backed by a custom map (useful in tests).
  RpcEnvConfig.from(Map<String, String> env) : _env = Map.unmodifiable(env);

  /// Returns the raw string value for [key], or null if absent.
  String? operator [](String key) => _env[key];

  /// Returns the raw string value for [key].
  ///
  /// Throws [StateError] if [key] is not set.
  String require(String key) {
    final val = _env[key];
    if (val == null || val.isEmpty) {
      throw StateError(
        'RpcEnvConfig: required environment variable "$key" is not set.',
      );
    }
    return val;
  }

  /// Parses [key] as an [int], returning null if absent or not parseable.
  int? getInt(String key) => int.tryParse(_env[key] ?? '');

  /// Parses [key] as an [int]. Throws if absent or not parseable.
  int requireInt(String key) {
    final val = require(key);
    return int.parse(val);
  }

  /// Parses [key] as a [double], returning null if absent or not parseable.
  double? getDouble(String key) => double.tryParse(_env[key] ?? '');

  /// Parses [key] as a boolean.
  ///
  /// Returns true when the value (case-insensitive) is `"true"`, `"1"`, or
  /// `"yes"`. Returns [defaultValue] when the key is absent.
  bool getBool(String key, {bool defaultValue = false}) {
    final val = _env[key]?.trim().toLowerCase();
    if (val == null) return defaultValue;
    return val == 'true' || val == '1' || val == 'yes';
  }

  /// Returns a [List<String>] by splitting the value on [separator].
  ///
  /// Returns an empty list when the key is absent or the value is blank.
  List<String> getList(String key, {String separator = ','}) {
    final val = _env[key];
    if (val == null || val.trim().isEmpty) return const [];
    return val.split(separator).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  /// Parses a human-readable [Duration] from [key].
  ///
  /// Accepted formats: `300ms`, `30s`, `5m`, `2h`.
  /// Returns null when the key is absent or the format is unrecognised.
  Duration? getDuration(String key) {
    final val = _env[key]?.trim();
    if (val == null || val.isEmpty) return null;
    final match = RegExp(r'^(\d+)(ms|s|m|h)$').firstMatch(val);
    if (match == null) return null;
    final n = int.parse(match.group(1)!);
    return switch (match.group(2)!) {
      'ms' => Duration(milliseconds: n),
      's'  => Duration(seconds: n),
      'm'  => Duration(minutes: n),
      'h'  => Duration(hours: n),
      _    => null,
    };
  }

  /// Returns all variable names present in this config.
  Iterable<String> get keys => _env.keys;

  /// Returns true when [key] is present and non-empty.
  bool has(String key) {
    final val = _env[key];
    return val != null && val.isNotEmpty;
  }
}
