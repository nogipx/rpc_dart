// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Lightweight logging adapter used by the TURN relay implementation.
///
/// The logger simply forwards formatted messages to optional callbacks. The
/// [scope] is prepended to all emitted messages and is extended when calling
/// [child].
class TurnRelayLogger {
  const TurnRelayLogger({
    this.scope,
    this.onDebug,
    this.onInfo,
    this.onWarning,
    this.onError,
  });

  /// Current logging scope (used as prefix in formatted messages).
  final String? scope;

  /// Debug-level callback.
  final void Function(String message)? onDebug;

  /// Info-level callback.
  final void Function(String message)? onInfo;

  /// Warning-level callback.
  final void Function(String message)? onWarning;

  /// Error-level callback with optional error information.
  final void Function(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  })? onError;

  /// Emits a debug-level [message].
  void debug(String message) => onDebug?.call(_format(message));

  /// Emits an info-level [message].
  void info(String message) => onInfo?.call(_format(message));

  /// Emits a warning-level [message].
  void warning(String message) => onWarning?.call(_format(message));

  /// Emits an error-level [message].
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      onError?.call(
        _format(message),
        error: error,
        stackTrace: stackTrace,
      );

  /// Returns a child logger that reuses the same callbacks but appends [scope]
  /// to the existing scope chain for message formatting.
  TurnRelayLogger child(String scope) {
    final nextScope = this.scope != null ? '${this.scope}.$scope' : scope;
    return TurnRelayLogger(
      scope: nextScope,
      onDebug: onDebug,
      onInfo: onInfo,
      onWarning: onWarning,
      onError: onError,
    );
  }

  String _format(String message) {
    if (scope == null || scope!.isEmpty) {
      return message;
    }
    return '[$scope] $message';
  }
}
