// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// gRPC-style RPC context - holds call metadata, timeouts, cancellation
/// tokens, and other contextual information.
final class RpcContext {
  static final RegExp _headerNamePattern = RegExp(r'^[0-9a-z_.-]+$');

  /// Request headers/metadata.
  final Map<String, String> _headers;

  /// Deadline for the operation, a time on [clock].
  ///
  /// The default [clock] is monotonic, so a system clock that jumps (NTP, a
  /// manual change) moves neither [isExpired] nor [remainingTime]. A deadline
  /// built from [DateTime.now] directly is on the wall clock instead, and
  /// after such a jump differs from [clock] by it; [withTimeout] avoids that.
  /// On the wire the deadline travels as a duration (`grpc-timeout`), so a
  /// peer's clock does not matter.
  final DateTime? deadline;

  /// Cancellation token.
  final RpcCancellationToken? cancellationToken;

  /// Trace ID for distributed tracing.
  final String? traceId;

  /// Unique request ID.
  ///
  /// EAGER on purpose. A lazy field copies as UNSET, so every `withX` copy
  /// would generate an id of its own and the caller's context would disagree
  /// with what it sent. The cheap version is passing the id in at construction,
  /// which [RpcContext.withHeaders] allows.
  final String requestId;

  /// Logger scope for this request context.
  final LogScope log;

  /// Additional context values (analogous to gRPC Context.Value).
  final Map<Object, Object> _values;

  /// Clock used for deadline/timeout computations.
  ///
  /// Defaults to [monotonicNow]: the wall time at its first read, advanced by a
  /// monotonic stopwatch since. Inject a fake clock (via [withClock]) to make
  /// `isExpired`, `remainingTime`, and `withTimeout` testable without real
  /// time.
  final DateTime Function() clock;

  /// The default [clock]: a time that only moves forward, at the rate of real
  /// time, whatever the system clock does.
  ///
  /// The wall clock is read ONCE; a [Timer] runs on a monotonic clock, and a
  /// deadline compared on the wall clock disagrees with it across any jump —
  /// expiring a call early or stretching it by the jump.
  static DateTime monotonicNow() => _origin.add(_sinceOrigin.elapsed);

  static final DateTime _origin = DateTime.now();
  static final Stopwatch _sinceOrigin = Stopwatch()..start();

  /// Header names set as credentials under a name of the caller's choosing
  /// ([RpcContextBuilder.withApiKey]); [sanitize] and
  /// [RpcContextExtensions.forward] drop them with the built-in ones.
  final Set<String> _credentialNames;

  RpcContext._({
    Map<String, String>? headers,
    this.deadline,
    this.cancellationToken,
    this.traceId,
    String? requestId,
    LogScope? log,
    Map<Object, Object>? values,
    DateTime Function()? clock,
    Set<String>? credentialNames,
  }) : _headers = Map.from(headers ?? {}),
       requestId = requestId ?? _generateRequestId(),
       log = log ?? LogScope.noop,
       _values = Map.from(values ?? {}),
       clock = clock ?? monotonicNow,
       _credentialNames = credentialNames ?? const {};

  /// Creates a new empty context.
  factory RpcContext.empty() => RpcContext._();

  /// Creates a context with headers.
  ///
  /// A header that can never be one (an empty, pseudo or off-pattern name, or
  /// CR/LF/NUL in the name or value) is dropped here, not thrown on. Size
  /// limits are not checked here: `RpcSecurityPolicy.validateMetadata` throws
  /// on them when the call is sent.
  ///
  /// [requestId] lets a responder adopt the id the caller sent WITHOUT minting
  /// one first.
  factory RpcContext.withHeaders(
    Map<String, String> headers, {
    String? requestId,
  }) => RpcContext._(headers: _sanitizeHeaders(headers), requestId: requestId);

  /// Creates a context with a deadline.
  factory RpcContext.withDeadline(DateTime deadline) =>
      RpcContext._(deadline: deadline);

  /// Creates a context with a timeout, measured on [monotonicNow].
  factory RpcContext.withTimeout(Duration timeout) =>
      RpcContext._(deadline: monotonicNow().add(timeout));

  /// Creates a context with a cancellation token.
  factory RpcContext.withCancellation(RpcCancellationToken token) =>
      RpcContext._(cancellationToken: token);

  /// Creates a context with a trace ID.
  factory RpcContext.withTraceId(String traceId) =>
      RpcContext._(traceId: traceId);

  /// Creates a copy of the context with additional headers.
  ///
  /// An addition replaces a header of the same name. A key that can never be
  /// a header is dropped; sizes are not bounded here, since the transport's
  /// [RpcSecurityPolicy] validates them when the call is sent.
  RpcContext withAdditionalHeaders(Map<String, String> additionalHeaders) =>
      _copy(
        headers: _sanitizeHeaders(
          Map<String, String>.from(_headers)..addAll(additionalHeaders),
        ),
      );

  /// Creates a copy of the context with a new deadline.
  RpcContext withDeadline(DateTime newDeadline) => _copy(deadline: newDeadline);

  /// Creates a copy of the context with a new timeout.
  RpcContext withTimeout(Duration timeout) =>
      withDeadline(clock().add(timeout));

  /// Creates a copy of the context with a cancellation token.
  RpcContext withCancellation(RpcCancellationToken token) =>
      _copy(cancellationToken: token);

  /// Creates a copy of the context with a trace ID.
  RpcContext withTraceId(String newTraceId) => _copy(traceId: newTraceId);

  /// Creates a copy carrying [newRequestId].
  ///
  /// The mirror of [withTraceId], and it exists for the same reason: a
  /// responder adopts the id the caller sent so both sides' logs name the same
  /// call.
  RpcContext withRequestId(String newRequestId) =>
      _copy(requestId: newRequestId);

  /// Creates a copy of the context with an additional value.
  RpcContext withValue(Object key, Object value) =>
      _copy(values: Map<Object, Object>.from(_values)..[key] = value);

  /// Creates a copy of the context with the given logger.
  RpcContext withLog(LogScope log) => _copy(log: log);

  /// Creates a copy of the context with a custom [clock] (mainly for tests).
  RpcContext withClock(DateTime Function() clock) => _copy(clock: clock);

  /// This context with the given fields replaced and the rest kept.
  /// [newRequestId] mints a fresh request id instead of keeping this one.
  RpcContext _copy({
    Map<String, String>? headers,
    DateTime? deadline,
    RpcCancellationToken? cancellationToken,
    String? traceId,
    String? requestId,
    bool newRequestId = false,
    LogScope? log,
    Map<Object, Object>? values,
    DateTime Function()? clock,
    Set<String>? credentialNames,
  }) => RpcContext._(
    headers: headers ?? _headers,
    deadline: deadline ?? this.deadline,
    cancellationToken: cancellationToken ?? this.cancellationToken,
    traceId: traceId ?? this.traceId,
    requestId: newRequestId ? null : (requestId ?? this.requestId),
    log: log ?? this.log,
    values: values ?? _values,
    clock: clock ?? this.clock,
    credentialNames: credentialNames ?? _credentialNames,
  );

  /// Returns the value of a header.
  ///
  /// In a handler's context, a header the peer sent more than once is one
  /// value: its values joined with `,` in the order received.
  String? getHeader(String key) => _headers[_normalizeHeaderName(key)];

  /// Returns all headers (read-only), repeated ones joined as in [getHeader].
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

  /// Drops what can never be a header, and bounds nothing.
  ///
  /// SIZE is [RpcSecurityPolicy]'s: it owns `maxHeaders`, `maxMetadataBytes`,
  /// `maxHeaderNameBytes` and `maxHeaderValueBytes`, and `validateMetadata`
  /// THROWS on them, so a configured limit is the only one.
  ///
  /// What stays is structural: a key that is empty, pseudo-header, off-pattern
  /// or carrying CR/LF/NUL is not a header at any size, so no limit is being
  /// applied by dropping it.
  static Map<String, String> _sanitizeHeaders(Map<String, String> headers) {
    final sanitized = <String, String>{};

    for (final entry in headers.entries) {
      final key = _normalizeHeaderName(entry.key);
      if (key.isEmpty ||
          key.startsWith(':') ||
          !_headerNamePattern.hasMatch(key) ||
          _containsInvalidHeaderChars(key)) {
        continue;
      }

      final value = entry.value;
      if (_containsInvalidHeaderChars(value)) continue;

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
  /// Throws [RpcStatusException] on a client/caller or manually-built context.
  RpcCallScope requireCallScope() =>
      callScope ??
      (throw RpcStatusException(
        RpcStatus.internal,
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

  /// The strong generator, created ONCE, so the `try` stays off the hot path.
  /// It seeds the token generator, see [_tokenRng]; tokens never come from it
  /// directly.
  ///
  /// **Null on any node runtime**, not just the test runner: `Random.secure()`
  /// throws `UnknownJsTypeError` there, while the VM and Chrome both provide it.
  /// Every token on node therefore comes from an unseeded default [Random].
  ///
  /// That is acceptable for what these ids are — correlation in logs and on the
  /// wire, never secrets or capability tokens — and recorded so nobody builds
  /// something needing unpredictability on top of them. The monotonic counter in
  /// [_uniqueToken] still guarantees uniqueness there; it guarantees nothing
  /// about guessability.
  static final Random? _strongRng = () {
    try {
      return Random.secure();
    } catch (_) {
      return null;
    }
  }();

  static final Random _fallbackRng = Random();

  /// The generator tokens are drawn from: a fast [Random] that [_strongRng]
  /// reseeds every [_tokensPerSeed] tokens.
  ///
  /// `Random.secure().nextInt()` reaches the system entropy source on every
  /// call, and every call spends at least one token, so drawing tokens from it
  /// directly was most of an RPC's CPU time. These ids are correlation, not
  /// secrets (see [_strongRng]); the strong seed keeps them unguessable to a
  /// peer that sees only the ids.
  static Random _tokenRng() {
    final strong = _strongRng;
    if (strong == null) return _fallbackRng;
    var rng = _seededRng;
    if (rng == null || ++_tokensSinceSeed >= _tokensPerSeed) {
      _tokensSinceSeed = 0;
      // 53 bits: a larger seed is not exact on the web.
      final seed =
          (strong.nextInt(1 << 21) * _randomWordMax) +
          strong.nextInt(_randomWordMax);
      rng = _seededRng = Random(seed);
    }
    return rng;
  }

  static Random? _seededRng;
  static int _tokensSinceSeed = 0;
  static const int _tokensPerSeed = 1024;

  /// `1 << 32`, written as a literal ON PURPOSE: dart2js shifts are 32-bit, so
  /// `1 << 32` evaluates to 0 there and `nextInt(0)` throws.
  static const int _randomWordMax = 4294967296;

  /// A 16-byte url-safe token, unique even where [Random.secure] is missing and
  /// a default [Random] may repeat within one millisecond.
  ///
  /// The first 12 bytes are random, from [_tokenRng], and the last 4 carry a
  /// process-wide monotonic counter, so two tokens never collide whatever the
  /// generator.
  static String _uniqueToken() {
    final bytes = Uint8List(16);
    final view = ByteData.view(bytes.buffer);
    final rng = _tokenRng();

    view.setUint32(0, rng.nextInt(_randomWordMax));
    view.setUint32(4, rng.nextInt(_randomWordMax));
    view.setUint32(8, rng.nextInt(_randomWordMax));

    // The last 4 bytes carry a process-wide monotonic counter, so two tokens
    // never collide even where the random half is weak.
    view.setUint32(12, _idCounter = (_idCounter + 1) & 0xFFFFFFFF);
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

  /// Headers [sanitize] and [RpcContextExtensions.forward] drop, with any
  /// name [RpcContextBuilder.withApiKey] was given.
  static const _credentialHeaders = {
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'cookie',
  };

  bool _isCredential(String name) =>
      _credentialHeaders.contains(name) || _credentialNames.contains(name);

  /// Creates a copy of the context without sensitive data, for logging.
  ///
  /// It drops the deadline and the cancellation token too, so a call made
  /// with it outlives the incoming one; a downstream call wants
  /// [RpcContextExtensions.forward].
  static RpcContext sanitize(RpcContext context) {
    final sanitizedHeaders = Map<String, String>.from(context.headers)
      ..removeWhere((name, _) => context._isCredential(name));

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

/// Utilities for working with the context. Credentials are set through
/// [RpcContextBuilder].
abstract final class RpcContextUtils {
  /// Creates a context for tracing.
  ///
  /// ONE token for both ids. A call that starts its own trace holds exactly one
  /// request, so the two ids name the same thing, and deriving both from one
  /// [_uniqueToken] keeps every property that matters — same entropy, same
  /// source, still unique, still unpredictable — for half the cost. The two are
  /// then correlated, which costs nothing: they travel in the same request
  /// metadata anyway.
  static RpcContext withTracing({String? traceId}) {
    final headers = <String, String>{RpcHeaders.xTraceId: ?traceId};

    final token = RpcContext._uniqueToken();
    return RpcContext.withHeaders(
      headers,
      requestId: 'req_$token',
    ).withTraceId(traceId ?? 'trace_$token');
  }

  /// A trace id for a call whose context already has a request id.
  ///
  /// The same reuse as [withTracing], for the branch where the caller supplied
  /// a context (so its request id has already been paid for) but no trace id.
  /// Falls back to a fresh token when the request id is not one of ours --
  /// [RpcContext.withHeaders] lets an application pass any string.
  static String traceIdFor(String requestId) => requestId.startsWith('req_')
      ? 'trace_${requestId.substring(4)}'
      : generateTraceId();

  /// Generates a new, unique trace ID.
  ///
  /// Random bits from a strongly seeded generator plus a process-wide counter,
  /// so ids generated within the same millisecond, or concurrently, are still
  /// unique. See [_uniqueToken].
  static String generateTraceId() => 'trace_${RpcContext._uniqueToken()}';

  /// Merges several contexts (the right one takes precedence).
  static RpcContext merge(RpcContext left, RpcContext right) {
    return right._copy(
      headers: RpcContext._sanitizeHeaders(
        Map<String, String>.from(left._headers)..addAll(right._headers),
      ),
      deadline: right.deadline ?? left.deadline,
      cancellationToken: right.cancellationToken ?? left.cancellationToken,
      traceId: right.traceId ?? left.traceId,
      values: Map<Object, Object>.from(left._values)..addAll(right._values),
      credentialNames: {...left._credentialNames, ...right._credentialNames},
    );
  }
}

/// Builder for explicit creation and propagation of RPC contexts.
/// Removes boilerplate when building complex contexts with inheritance.
class RpcContextBuilder {
  RpcContext _context;

  /// Set by [RpcContextBuilder.inheritFrom]: a context derived from a parent
  /// may shorten its deadline and never extend it.
  bool _derived = false;

  /// Creates a builder with an empty context.
  RpcContextBuilder() : _context = RpcContext.empty();

  /// Creates a builder from an existing context (for propagation).
  RpcContextBuilder.from(RpcContext context) : _context = context;

  /// Creates a builder with automatic trace ID inheritance from the parent
  /// context. If parent == null or traceId == null, generates a new trace ID.
  ///
  /// [withDeadline] and [withTimeout] on the result keep the parent's
  /// deadline when it is the earlier one: the child of a call cannot outlive
  /// it.
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
    final builder = RpcContextBuilder.from(parent).withGeneratedRequestId()
      .._derived = true;
    return parent.traceId != null ? builder : builder.withGeneratedTraceId();
  }

  /// Adds [headers] to the context; one already set under the same name is
  /// replaced, and the rest are kept.
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
    _context = _context._copy(newRequestId: true);
    return this;
  }

  /// Sets the deadline; on a builder from [RpcContextBuilder.inheritFrom],
  /// only if it is earlier than the parent's.
  RpcContextBuilder withDeadline(DateTime deadline) {
    final current = _context.deadline;
    if (_derived && current != null && current.isBefore(deadline)) {
      return this;
    }
    _context = _context.withDeadline(deadline);
    return this;
  }

  /// Sets the timeout, measured on the context's clock; on a builder from
  /// [RpcContextBuilder.inheritFrom], only if it ends before the parent's
  /// deadline.
  RpcContextBuilder withTimeout(Duration timeout) =>
      withDeadline(_context.clock().add(timeout));

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

  /// Sets the API key, under [headerName]; [RpcContext.sanitize] and
  /// [RpcContextExtensions.forward] drop it whatever the name.
  RpcContextBuilder withApiKey(String key, {String headerName = 'x-api-key'}) {
    withHeader(headerName, key);
    final name = RpcContext._normalizeHeaderName(headerName);
    if (!_context._isCredential(name)) {
      _context = _context._copy(
        credentialNames: {..._context._credentialNames, name},
      );
    }
    return this;
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

  /// Creates a child context with additional headers. A [timeout] that ends
  /// after this context's deadline is ignored.
  RpcContext createChildWith({
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    var builder = RpcContextBuilder.inheritFrom(this);

    if (headers != null) builder = builder.withHeaders(headers);
    if (timeout != null) builder = builder.withTimeout(timeout);

    return builder.build();
  }

  /// The context for a downstream call made on behalf of this one.
  ///
  /// Like [createChildWith]: the trace, deadline, cancellation token, values
  /// and headers carry over, and a new request id is minted. This context's
  /// credentials (`authorization`, `proxy-authorization`, `x-api-key`,
  /// `cookie`, and a name given to [RpcContextBuilder.withApiKey]) do not;
  /// [headers] are added after they are dropped, so the downstream call's own
  /// credentials go through.
  RpcContext forward({Map<String, String>? headers, Duration? timeout}) {
    final child = createChildWith(timeout: timeout);
    final inherited = Map.of(child._headers)
      ..removeWhere((name, _) => _isCredential(name));
    return child._copy(
      headers: RpcContext._sanitizeHeaders({...inherited, ...?headers}),
      credentialNames: const {},
    );
  }
}
