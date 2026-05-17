// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '_index.dart';

/// RPC Context в стиле gRPC - содержит метаданные вызова,
/// таймауты, токены отмены и другую контекстную информацию
final class RpcContext {
  static const int _maxHeaderCount = 128;
  static const int _maxHeaderNameLength = 128;
  static const int _maxHeaderValueLength = 8 * 1024;
  static const int _maxTotalHeaderBytes = 64 * 1024;

  static final RegExp _headerNamePattern = RegExp(r'^[0-9a-z_.-]+$');

  /// Заголовки/метаданные запроса
  final Map<String, String> _headers;

  /// Deadline для операции (абсолютное время)
  final DateTime? deadline;

  /// Токен отмены
  final RpcCancellationToken? cancellationToken;

  /// Trace ID для распределенной трассировки
  final String? traceId;

  /// Уникальный ID запроса
  final String requestId;

  /// Logger scope for this request context.
  final LogScope log;

  /// Дополнительные значения контекста (аналог gRPC Context.Value)
  final Map<Object, Object> _values;

  RpcContext._({
    Map<String, String>? headers,
    this.deadline,
    this.cancellationToken,
    this.traceId,
    String? requestId,
    LogScope? log,
    Map<Object, Object>? values,
  })  : _headers = Map.from(headers ?? {}),
        requestId = requestId ?? _generateRequestId(),
        log = log ?? LogScope.noop,
        _values = Map.from(values ?? {});

  /// Создает новый пустой контекст
  factory RpcContext.empty() => RpcContext._();

  /// Создает контекст с заголовками
  factory RpcContext.withHeaders(Map<String, String> headers) =>
      RpcContext._(headers: _sanitizeHeaders(headers));

  /// Создает контекст с deadline
  factory RpcContext.withDeadline(DateTime deadline) =>
      RpcContext._(deadline: deadline);

  /// Создает контекст с timeout
  factory RpcContext.withTimeout(Duration timeout) =>
      RpcContext._(deadline: DateTime.now().add(timeout));

  /// Создает контекст с токеном отмены
  factory RpcContext.withCancellation(RpcCancellationToken token) =>
      RpcContext._(cancellationToken: token);

  /// Создает контекст с trace ID
  factory RpcContext.withTraceId(String traceId) =>
      RpcContext._(traceId: traceId);

  /// Создает копию контекста с дополнительными заголовками
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
    );
  }

  /// Создает копию контекста с новым deadline
  RpcContext withDeadline(DateTime newDeadline) => RpcContext._(
        headers: _headers,
        deadline: newDeadline,
        cancellationToken: cancellationToken,
        traceId: traceId,
        requestId: requestId,
        log: log,
        values: _values,
      );

  /// Создает копию контекста с новым timeout
  RpcContext withTimeout(Duration timeout) =>
      withDeadline(DateTime.now().add(timeout));

  /// Создает копию контекста с токеном отмены
  RpcContext withCancellation(RpcCancellationToken token) => RpcContext._(
        headers: _headers,
        deadline: deadline,
        cancellationToken: token,
        traceId: traceId,
        requestId: requestId,
        log: log,
        values: _values,
      );

  /// Создает копию контекста с trace ID
  RpcContext withTraceId(String newTraceId) => RpcContext._(
        headers: _headers,
        deadline: deadline,
        cancellationToken: cancellationToken,
        traceId: newTraceId,
        requestId: requestId,
        log: log,
        values: _values,
      );

  /// Создает копию контекста с дополнительным значением
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
    );
  }

  /// Создает копию контекста с указанным логгером.
  RpcContext withLog(LogScope log) => RpcContext._(
        headers: _headers,
        deadline: deadline,
        cancellationToken: cancellationToken,
        traceId: traceId,
        requestId: requestId,
        log: log,
        values: _values,
      );

  /// Получает значение заголовка
  String? getHeader(String key) => _headers[_normalizeHeaderName(key)];

  /// Получает все заголовки (только для чтения)
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

  /// Получает значение из контекста
  T? getValue<T>(Object key) => _values[key] as T?;

  /// Получает все значения контекста (только для чтения)
  Map<Object, Object> get values => Map.unmodifiable(_values);

  /// Проверяет, истек ли deadline
  bool get isExpired {
    if (deadline == null) return false;
    return DateTime.now().isAfter(deadline!);
  }

  /// Проверяет, был ли запрос отменен
  bool get isCancelled => cancellationToken?.isCancelled ?? false;

  /// Получает оставшееся время до deadline
  Duration? get remainingTime {
    if (deadline == null) return null;
    final remaining = deadline!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Генерирует уникальный ID запроса
  static String _generateRequestId() {
    final bytes = Uint8List(16);
    try {
      final secure = Random.secure();
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = secure.nextInt(256);
      }
    } catch (_) {
      final fallback = Random(DateTime.now().microsecondsSinceEpoch);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = fallback.nextInt(256);
      }
    }

    final token = base64UrlEncode(bytes).replaceAll('=', '');
    return 'req_$token';
  }

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

  /// Проверяет, является ли контекст истекшим или отмененным
  static bool isContextValid(RpcContext? context) {
    if (context == null) return false;
    return !context.isExpired && !context.isCancelled;
  }

  /// Создает "безопасную" копию контекста без чувствительных данных
  static RpcContext sanitize(RpcContext context) {
    final sanitizedHeaders = Map<String, String>.from(context.headers);

    // Удаляем чувствительные заголовки
    sanitizedHeaders.remove('authorization');
    sanitizedHeaders.remove('x-api-key');
    sanitizedHeaders.remove('cookie');

    return RpcContextBuilder()
        .withHeaders(sanitizedHeaders)
        .withTraceId(context.traceId ?? 'sanitized-trace')
        .build();
  }
}

/// Токен отмены операции (аналог context.CancelFunc в Go)
final class RpcCancellationToken {
  final Completer<void> _completer = Completer<void>();
  String? _reason;

  /// Создает новый токен отмены
  RpcCancellationToken();

  /// Создает уже отмененный токен
  RpcCancellationToken.cancelled([String? reason]) {
    _reason = reason;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  /// Проверяет, был ли токен отменен
  bool get isCancelled => _completer.isCompleted;

  /// Причина отмены (если указана)
  String? get reason => _reason;

  /// Future, который завершается при отмене
  Future<void> get cancelled => _completer.future;

  /// Отменяет операцию
  void cancel([String? reason]) {
    if (!_completer.isCompleted) {
      _reason = reason;
      _completer.complete();
    }
  }

  /// Проверяет отмену и выбрасывает исключение если отменено
  void throwIfCancelled() {
    if (isCancelled) {
      throw RpcCancelledException(reason ?? 'Operation was cancelled');
    }
  }
}

/// Исключение отмены операции
final class RpcCancelledException implements Exception {
  /// Reason the operation was cancelled.
  final String message;

  /// Creates an [RpcCancelledException] with the given [message].
  const RpcCancelledException(this.message);

  @override
  String toString() => 'RpcCancelledException: $message';
}

/// Исключение превышения deadline
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

/// Утилиты для работы с контекстом
abstract final class RpcContextUtils {
  /// Создает контекст с базовой аутентификацией
  static RpcContext withBasicAuth(String username, String password) {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return RpcContext.withHeaders({'authorization': 'Basic $credentials'});
  }

  /// Создает контекст с Bearer токеном
  static RpcContext withBearerToken(String token) =>
      RpcContext.withHeaders({'authorization': 'Bearer $token'});

  /// Создает контекст с API ключом
  static RpcContext withApiKey(String key, {String headerName = 'x-api-key'}) =>
      RpcContext.withHeaders({headerName: key});

  /// Создает контекст для трассировки
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

  /// Generates a new trace ID.
  static String generateTraceId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp * 31 + 17) % 100000;
    return 'trace_${timestamp}_$random';
  }

  /// Объединяет несколько контекстов (правый имеет приоритет)
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
    );
  }
}

/// Builder для explicit создания и propagation RPC контекстов
/// Убирает boilerplate при создании сложных контекстов с наследованием
class RpcContextBuilder {
  RpcContext _context;

  /// Создает builder с пустым контекстом
  RpcContextBuilder() : _context = RpcContext.empty();

  /// Создает builder на основе существующего контекста (для propagation)
  RpcContextBuilder.from(RpcContext context) : _context = context;

  /// Создает builder с auto-наследованием trace ID от родительского контекста
  /// Если parent == null или traceId == null, генерирует новый trace ID
  factory RpcContextBuilder.inheritFrom(RpcContext? parent) {
    if (parent?.traceId != null) {
      // Наследуем trace ID и базовые заголовки
      return RpcContextBuilder.from(
        parent!,
      ).withGeneratedRequestId(); // Генерируем новый request ID для нового вызова
    }

    // Создаем новый контекст с новым trace ID
    return RpcContextBuilder().withGeneratedTraceId().withGeneratedRequestId();
  }

  /// Устанавливает заголовки
  RpcContextBuilder withHeaders(Map<String, String> headers) {
    _context = _context.withAdditionalHeaders(headers);
    return this;
  }

  /// Добавляет один заголовок
  RpcContextBuilder withHeader(String key, String value) {
    _context = _context.withAdditionalHeaders({key: value});
    return this;
  }

  /// Устанавливает trace ID
  RpcContextBuilder withTraceId(String traceId) {
    _context = _context.withTraceId(traceId);
    return this;
  }

  /// Генерирует новый trace ID
  RpcContextBuilder withGeneratedTraceId() {
    _context = _context.withTraceId(RpcContextUtils.generateTraceId());
    return this;
  }

  /// Генерирует новый request ID (для chain вызовов)
  RpcContextBuilder withGeneratedRequestId() {
    _context = RpcContext._(
      headers: _context._headers,
      deadline: _context.deadline,
      cancellationToken: _context.cancellationToken,
      traceId: _context.traceId,
      requestId: null,
      log: _context.log,
      values: _context._values,
    );
    return this;
  }

  /// Устанавливает deadline
  RpcContextBuilder withDeadline(DateTime deadline) {
    _context = _context.withDeadline(deadline);
    return this;
  }

  /// Устанавливает timeout
  RpcContextBuilder withTimeout(Duration timeout) {
    _context = _context.withTimeout(timeout);
    return this;
  }

  /// Устанавливает cancellation token
  RpcContextBuilder withCancellation(RpcCancellationToken token) {
    _context = _context.withCancellation(token);
    return this;
  }

  /// Добавляет значение в контекст
  RpcContextBuilder withValue(Object key, Object value) {
    _context = _context.withValue(key, value);
    return this;
  }

  /// Устанавливает Bearer аутентификацию
  RpcContextBuilder withBearerAuth(String token) {
    return withHeader('authorization', 'Bearer $token');
  }

  /// Устанавливает Basic аутентификацию
  RpcContextBuilder withBasicAuth(String username, String password) {
    final credentials = base64Encode(utf8.encode('$username:$password'));
    return withHeader('authorization', 'Basic $credentials');
  }

  /// Устанавливает API ключ
  RpcContextBuilder withApiKey(String key, {String headerName = 'x-api-key'}) {
    return withHeader(headerName, key);
  }

  /// Возвращает готовый контекст
  RpcContext build() => _context;
}

/// Extension для удобной работы с propagation
extension RpcContextExtensions on RpcContext {
  /// Создает дочерний контекст для нового вызова (наследует trace ID, новый request ID)
  RpcContext createChild() {
    return RpcContextBuilder.inheritFrom(this).build();
  }

  /// Создает дочерний контекст с дополнительными заголовками
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
