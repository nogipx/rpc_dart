// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// gRPC-style RPC context - holds call metadata, timeouts, cancellation
/// tokens, and other contextual information.
final class RpcContext {
  static const int _maxHeaderCount = 128;
  static const int _maxHeaderNameLength = 128;
  static const int _maxHeaderValueLength = 8 * 1024;
  static const int _maxTotalHeaderBytes = 64 * 1024;

  static final RegExp _headerNamePattern = RegExp(r'^[0-9a-z_.-]+$');

  /// Request headers/metadata.
  final Map<String, String> _headers;

  /// Deadline for the operation (absolute time).
  final DateTime? deadline;

  /// Cancellation token.
  final RpcCancellationToken? cancellationToken;

  /// Trace ID for distributed tracing.
  final String? traceId;

  /// Unique request ID.
  final String requestId;

  /// Logger scope for this request context.
  final LogScope log;

  /// Additional context values (analogous to gRPC Context.Value).
  final Map<Object, Object> _values;

  /// Clock used for deadline/timeout computations. Defaults to [DateTime.now];
  /// inject a fake clock (via [withClock]) to make `isExpired`, `remainingTime`,
  /// and `withTimeout` testable without real time. Mirrors the logger's clock.
  final DateTime Function() clock;

  RpcContext._({
    Map<String, String>? headers,
    this.deadline,
    this.cancellationToken,
    this.traceId,
    String? requestId,
    LogScope? log,
    Map<Object, Object>? values,
    DateTime Function()? clock,
  }) : _headers = Map.from(headers ?? {}),
       requestId = requestId ?? _generateRequestId(),
       log = log ?? LogScope.noop,
       _values = Map.from(values ?? {}),
       clock = clock ?? DateTime.now;

  /// Creates a new empty context.
  factory RpcContext.empty() => RpcContext._();

  /// Creates a context with headers.
  factory RpcContext.withHeaders(Map<String, String> headers) =>
      RpcContext._(headers: _sanitizeHeaders(headers));

  /// Creates a context with a deadline.
  factory RpcContext.withDeadline(DateTime deadline) =>
      RpcContext._(deadline: deadline);

  /// Creates a context with a timeout.
  factory RpcContext.withTimeout(Duration timeout) =>
      RpcContext._(deadline: DateTime.now().add(timeout));

  /// Creates a context with a cancellation token.
  factory RpcContext.withCancellation(RpcCancellationToken token) =>
      RpcContext._(cancellationToken: token);

  /// Creates a context with a trace ID.
  factory RpcContext.withTraceId(String traceId) =>
      RpcContext._(traceId: traceId);

  /// Creates a copy of the context with additional headers.
  RpcContext withAdditionalHeaders(Map<String, String> additionalHeaders) {
    final newHeaders = Map<String, String>.from(_headers);
    newHeaders.addAll(_sanitizeHeaders(additionalHeaders));

    return RpcContext._(
      headers: newHeaders,
      deadline: deadline,
      cancellationToken: cancellationToken,
      traceId: traceId,
      requestId: requestId,
      log: log,
      values: _values,
      clock: clock,
    );
  }

  /// Creates a copy of the context with a new deadline.
  RpcContext withDeadline(DateTime newDeadline) => RpcContext._(
    headers: _headers,
    deadline: newDeadline,
    cancellationToken: cancellationToken,
    traceId: traceId,
    requestId: requestId,
    log: log,
    values: _values,
    clock: clock,
  );

  /// Creates a copy of the context with a new timeout.
  RpcContext withTimeout(Duration timeout) =>
      withDeadline(clock().add(timeout));

  /// Creates a copy of the context with a cancellation token.
  RpcContext withCancellation(RpcCancellationToken token) => RpcContext._(
    headers: _headers,
    deadline: deadline,
    cancellationToken: token,
    traceId: traceId,
    requestId: requestId,
    log: log,
    values: _values,
    clock: clock,
  );

  /// Creates a copy of the context with a trace ID.
  RpcContext withTraceId(String newTraceId) => RpcContext._(
    headers: _headers,
    deadline: deadline,
    cancellationToken: cancellationToken,
    traceId: newTraceId,
    requestId: requestId,
    log: log,
    values: _values,
    clock: clock,
  );

  /// Creates a copy of the context with an additional value.
  RpcContext withValue(Object key, Object value) {
    final newValues = Map<Object, Object>.from(_values);
    newValues[key] = value;

    return RpcContext._(
      headers: _headers,
      deadline: deadline,
      cancellationToken: cancellationToken,
      traceId: traceId,
      requestId: requestId,
      log: log,
      values: newValues,
      clock: clock,
    );
  }

  /// Creates a copy of the context with the given logger.
  RpcContext withLog(LogScope log) => RpcContext._(
    headers: _headers,
    deadline: deadline,
    cancellationToken: cancellationToken,
    traceId: traceId,
    requestId: requestId,
    log: log,
    values: _values,
    clock: clock,
  );

  /// Creates a copy of the context with a custom [clock] (mainly for tests).
  RpcContext withClock(DateTime Function() clock) => RpcContext._(
    headers: _headers,
    deadline: deadline,
    cancellationToken: cancellationToken,
    traceId: traceId,
    requestId: requestId,
    log: log,
    values: _values,
    clock: clock,
  );

  /// Returns the value of a header.
  String? getHeader(String key) => _headers[_normalizeHeaderName(key)];

  /// Returns all headers (read-only).
  Map<String, String> get headers => Map.unmodifiable(_headers);

  static bool _containsInvalidHeaderChars(String value) {
    for (var i = 0; i < value.length; i++) {
      final codeUnit = value.codeUnitAt(i);
      if (codeUnit == 0x0A || codeUnit == 0x0D || codeUnit == 0x00) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeHeaderName(String key) => key.trim().toLowerCase();

  static Map<String, String> _sanitizeHeaders(Map<String, String> headers) {
    final sanitized = <String, String>{};
    var totalBytes = 0;

    for (final entry in headers.entries) {
      final key = _normalizeHeaderName(entry.key);
      if (key.isEmpty ||
          key.startsWith(':') ||
          key.length > _maxHeaderNameLength ||
          !_headerNamePattern.hasMatch(key) ||
          _containsInvalidHeaderChars(key)) {
        continue;
      }

      final value = entry.value;
      if (value.length > _maxHeaderValueLength ||
          _containsInvalidHeaderChars(value)) {
        continue;
      }

      totalBytes += key.length + value.length;
      if (sanitized.length >= _maxHeaderCount ||
          totalBytes > _maxTotalHeaderBytes) {
        break;
      }

      sanitized[key] = value;
    }

    return sanitized;
  }

  /// Returns a value from the context.
  T? getValue<T>(Object key) => _values[key] as T?;

  /// Returns all user context values (read-only).
  ///
  /// The framework's per-call [RpcCallScope] (injected server-side, keyed by its
  /// type) is internal plumbing rather than user data, so it is excluded here;
  /// retrieve it with `getValue<RpcCallScope>(RpcCallScope)`.
  Map<Object, Object> get values {
    if (!_values.containsKey(RpcCallScope)) return Map.unmodifiable(_values);
    return Map.unmodifiable({
      for (final e in _values.entries)
        if (e.key != RpcCallScope) e.key: e.value,
    });
  }

  /// The per-call [RpcCallScope] for handler resource cleanup.
  ///
  /// Non-null inside a responder handler (the server injects one scope per
  /// incoming call); null for a client/caller context or a manually-built one.
  /// Use it to register cleanup that runs when the call ends:
  /// `context.callScope?.onDispose(() => release());`
  RpcCallScope? get callScope => getValue<RpcCallScope>(RpcCallScope);

  /// The per-call [RpcCallScope], or throws if there is none.
  ///
  /// Convenience for responder handlers, where a scope is always present, so you
  /// can skip the null-check: `context!.requireCallScope().onDispose(...)`.
  /// Throws [StateError] on a client/caller or manually-built context.
  RpcCallScope requireCallScope() =>
      callScope ??
      (throw StateError(
        'requireCallScope: no RpcCallScope on this context. A scope is injected '
        'only for incoming server (responder) calls.',
      ));

  /// Returns true if the deadline has expired.
  bool get isExpired {
    if (deadline == null) return false;
    return clock().isAfter(deadline!);
  }

  /// Returns true if the request has been cancelled.
  bool get isCancelled => cancellationToken?.isCancelled ?? false;

  /// Returns the time remaining until the deadline.
  Duration? get remainingTime {
    if (deadline == null) return null;
    final remaining = deadline!.difference(clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  static int _idCounter = 0;

  /// Generates a 16-byte url-safe token that is unique even on platforms where
  /// [Random.secure] is unavailable (e.g. the bare node test runtime) and a
  /// default [Random] may repeat within the same millisecond. The first 12
  /// bytes are random (unpredictability where a strong RNG exists); the last 4
  /// carry a process-wide monotonic counter so two tokens never collide.
  static String _uniqueToken() {
    final bytes = Uint8List(16);
    Random rng;
    try {
      rng = Random.secure();
    } catch (_) {
      // No strong RNG on this platform: fall back to the default Random
      // (the monotonic counter below still guarantees uniqueness).
      rng = Random();
    }
    for (var i = 0; i < 12; i++) {
      bytes[i] = rng.nextInt(256);
    }
    final c = _idCounter = (_idCounter + 1) & 0xFFFFFFFF;
    bytes[12] = (c >> 24) & 0xFF;
    bytes[13] = (c >> 16) & 0xFF;
    bytes[14] = (c >> 8) & 0xFF;
    bytes[15] = c & 0xFF;
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Generates a unique request ID.
  static String _generateRequestId() => 'req_${_uniqueToken()}';

  @override
  String toString() {
    final parts = <String>[
      'requestId: $requestId',
      if (traceId != null) 'traceId: $traceId',
      if (deadline != null) 'deadline: $deadline',
      if (_headers.isNotEmpty) 'headers: ${_headers.length}',
      if (_values.isNotEmpty) 'values: ${_values.length}',
      if (isCancelled) 'CANCELLED',
      if (isExpired) 'EXPIRED',
    ];

    return 'RpcContext(${parts.join(', ')})';
  }

  /// Returns true if the context is neither expired nor cancelled.
  static bool isContextValid(RpcContext? context) {
    if (context == null) return false;
    return !context.isExpired && !context.isCancelled;
  }

  /// Creates a "safe" copy of the context without sensitive data.
  static RpcContext sanitize(RpcContext context) {
    final sanitizedHeaders = Map<String, String>.from(context.headers);

    // Remove sensitive headers.
    sanitizedHeaders.remove('authorization');
    sanitizedHeaders.remove('x-api-key');
    sanitizedHeaders.remove('cookie');

    return RpcContextBuilder()
        .withHeaders(sanitizedHeaders)
        .withTraceId(context.traceId ?? 'sanitized-trace')
        .build();
  }
}

/// Operation cancellation token (analogous to context.CancelFunc in Go).
final class RpcCancellationToken {
  final Completer<void> _completer = Completer<void>();
  String? _reason;

  /// Creates a new cancellation token.
  RpcCancellationToken();

  /// Creates an already-cancelled token.
  RpcCancellationToken.cancelled([String? reason]) {
    _reason = reason;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  /// Returns true if the token has been cancelled.
  bool get isCancelled => _completer.isCompleted;

  /// Cancellation reason, if provided.
  String? get reason => _reason;

  /// Future that completes when cancellation occurs.
  Future<void> get cancelled => _completer.future;

  /// Cancels the operation.
  void cancel([String? reason]) {
    if (!_completer.isCompleted) {
      _reason = reason;
      _completer.complete();
    }
  }

  /// Checks for cancellation and throws an exception if cancelled.
  void throwIfCancelled() {
    if (isCancelled) {
      throw RpcCancelledException(reason ?? 'Operation was cancelled');
    }
  }
}

/// Operation cancellation exception.
final class RpcCancelledException implements Exception {
  /// Reason the operation was cancelled.
  final String message;

  /// Creates an [RpcCancelledException] with the given [message].
  const RpcCancelledException(this.message);

  @override
  String toString() => 'RpcCancelledException: $message';
}

/// Deadline-exceeded exception.
final class RpcDeadlineExceededException implements Exception {
  /// The deadline that was exceeded.
  final DateTime deadline;

  /// The timeout duration that was configured.
  final Duration timeout;

  /// Creates an [RpcDeadlineExceededException] with [deadline] and [timeout].
  const RpcDeadlineExceededException(this.deadline, this.timeout);

  @override
  String toString() =>
      'RpcDeadlineExceededException: Deadline $deadline exceeded (timeout: $timeout)';
}

/// Utilities for working with the context.
abstract final class RpcContextUtils {
  /// Creates a context with basic authentication.
  static RpcContext withBasicAuth(String username, String password) {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return RpcContext.withHeaders({'authorization': 'Basic $credentials'});
  }

  /// Creates a context with a Bearer token.
  static RpcContext withBearerToken(String token) =>
      RpcContext.withHeaders({'authorization': 'Bearer $token'});

  /// Creates a context with an API key.
  static RpcContext withApiKey(String key, {String headerName = 'x-api-key'}) =>
      RpcContext.withHeaders({headerName: key});

  /// Creates a context for tracing.
  static RpcContext withTracing({
    String? traceId,
    String? spanId,
    String? parentSpanId,
  }) {
    final headers = <String, String>{};

    if (traceId != null) headers['x-trace-id'] = traceId;
    if (spanId != null) headers['x-span-id'] = spanId;
    if (parentSpanId != null) headers['x-parent-span-id'] = parentSpanId;

    return RpcContext.withHeaders(
      headers,
    ).withTraceId(traceId ?? generateTraceId());
  }

  /// Generates a new, unique trace ID.
  ///
  /// Uses cryptographically strong randomness (with a seeded fallback for
  /// platforms where [Random.secure] is unavailable) so that ids generated
  /// within the same millisecond are still unique. The previous deterministic
  /// `timestamp * 31 + 17` derivation produced identical ids under concurrency,
  /// corrupting distributed-trace correlation.
  static String generateTraceId() => 'trace_${RpcContext._uniqueToken()}';

  /// Merges several contexts (the right one takes precedence).
  static RpcContext merge(RpcContext left, RpcContext right) {
    final mergedHeaders = Map<String, String>.from(left._headers);
    mergedHeaders.addAll(right._headers);

    final mergedValues = Map<Object, Object>.from(left._values);
    mergedValues.addAll(right._values);

    return RpcContext._(
      headers: mergedHeaders,
      deadline: right.deadline ?? left.deadline,
      cancellationToken: right.cancellationToken ?? left.cancellationToken,
      traceId: right.traceId ?? left.traceId,
      requestId: right.requestId,
      log: right.log,
      values: mergedValues,
      clock: right.clock,
    );
  }
}

/// Builder for explicit creation and propagation of RPC contexts.
/// Removes boilerplate when building complex contexts with inheritance.
class RpcContextBuilder {
  RpcContext _context;

  /// Creates a builder with an empty context.
  RpcContextBuilder() : _context = RpcContext.empty();

  /// Creates a builder from an existing context (for propagation).
  RpcContextBuilder.from(RpcContext context) : _context = context;

  /// Creates a builder with automatic trace ID inheritance from the parent
  /// context. If parent == null or traceId == null, generates a new trace ID.
  factory RpcContextBuilder.inheritFrom(RpcContext? parent) {
    // No parent: brand-new context with fresh trace + request IDs.
    if (parent == null) {
      return RpcContextBuilder()
          .withGeneratedTraceId()
          .withGeneratedRequestId();
    }

    // Inherit the parent's state (cancellation token, deadline, headers,
    // values) regardless of whether it carries a trace ID. Always generate a
    // new request ID for the new call; only generate a trace ID when the parent
    // lacks one.
    final builder = RpcContextBuilder.from(parent).withGeneratedRequestId();
    return parent.traceId != null ? builder : builder.withGeneratedTraceId();
  }

  /// Sets the headers.
  RpcContextBuilder withHeaders(Map<String, String> headers) {
    _context = _context.withAdditionalHeaders(headers);
    return this;
  }

  /// Adds a single header.
  RpcContextBuilder withHeader(String key, String value) {
    _context = _context.withAdditionalHeaders({key: value});
    return this;
  }

  /// Sets the trace ID.
  RpcContextBuilder withTraceId(String traceId) {
    _context = _context.withTraceId(traceId);
    return this;
  }

  /// Generates a new trace ID.
  RpcContextBuilder withGeneratedTraceId() {
    _context = _context.withTraceId(RpcContextUtils.generateTraceId());
    return this;
  }

  /// Generates a new request ID (for chained calls).
  RpcContextBuilder withGeneratedRequestId() {
    _context = RpcContext._(
      headers: _context._headers,
      deadline: _context.deadline,
      cancellationToken: _context.cancellationToken,
      traceId: _context.traceId,
      requestId: null,
      log: _context.log,
      values: _context._values,
      clock: _context.clock,
    );
    return this;
  }

  /// Sets the deadline.
  RpcContextBuilder withDeadline(DateTime deadline) {
    _context = _context.withDeadline(deadline);
    return this;
  }

  /// Sets the timeout.
  RpcContextBuilder withTimeout(Duration timeout) {
    _context = _context.withTimeout(timeout);
    return this;
  }

  /// Sets the cancellation token.
  RpcContextBuilder withCancellation(RpcCancellationToken token) {
    _context = _context.withCancellation(token);
    return this;
  }

  /// Sets a custom clock for deadline/timeout computations (mainly for tests).
  RpcContextBuilder withClock(DateTime Function() clock) {
    _context = _context.withClock(clock);
    return this;
  }

  /// Adds a value to the context.
  RpcContextBuilder withValue(Object key, Object value) {
    _context = _context.withValue(key, value);
    return this;
  }

  /// Sets Bearer authentication.
  RpcContextBuilder withBearerAuth(String token) {
    return withHeader('authorization', 'Bearer $token');
  }

  /// Sets Basic authentication.
  RpcContextBuilder withBasicAuth(String username, String password) {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return withHeader('authorization', 'Basic $credentials');
  }

  /// Sets the API key.
  RpcContextBuilder withApiKey(String key, {String headerName = 'x-api-key'}) {
    return withHeader(headerName, key);
  }

  /// Returns the built context.
  RpcContext build() => _context;
}

/// Extension for convenient propagation handling.
extension RpcContextExtensions on RpcContext {
  /// Creates a child context for a new call (inherits trace ID, new request ID).
  RpcContext createChild() {
    return RpcContextBuilder.inheritFrom(this).build();
  }

  /// Creates a child context with additional headers.
  RpcContext createChildWith({
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    var builder = RpcContextBuilder.inheritFrom(this);

    if (headers != null) builder = builder.withHeaders(headers);
    if (timeout != null) builder = builder.withTimeout(timeout);

    return builder.build();
  }
}
