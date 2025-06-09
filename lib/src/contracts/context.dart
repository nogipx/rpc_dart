// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

part of '_index.dart';

/// RPC Context в стиле gRPC - содержит метаданные вызова,
/// таймауты, токены отмены и другую контекстную информацию
final class RpcContext {
  /// Заголовки/метаданные запроса
  final Map<String, String> _headers;

  /// Deadline для операции (абсолютное время)
  final DateTime? deadline;

  /// Токен отмены
  final CancellationToken? cancellationToken;

  /// Trace ID для распределенной трассировки
  final String? traceId;

  /// Уникальный ID запроса
  final String requestId;

  /// Дополнительные значения контекста (аналог gRPC Context.Value)
  final Map<Object, Object> _values;

  RpcContext._({
    Map<String, String>? headers,
    this.deadline,
    this.cancellationToken,
    this.traceId,
    String? requestId,
    Map<Object, Object>? values,
  })  : _headers = Map.from(headers ?? {}),
        requestId = requestId ?? _generateRequestId(),
        _values = Map.from(values ?? {});

  /// Создает новый пустой контекст
  factory RpcContext.empty() => RpcContext._();

  /// Создает контекст с заголовками
  factory RpcContext.withHeaders(Map<String, String> headers) =>
      RpcContext._(headers: headers);

  /// Создает контекст с deadline
  factory RpcContext.withDeadline(DateTime deadline) =>
      RpcContext._(deadline: deadline);

  /// Создает контекст с timeout
  factory RpcContext.withTimeout(Duration timeout) =>
      RpcContext._(deadline: DateTime.now().add(timeout));

  /// Создает контекст с токеном отмены
  factory RpcContext.withCancellation(CancellationToken token) =>
      RpcContext._(cancellationToken: token);

  /// Создает контекст с trace ID
  factory RpcContext.withTraceId(String traceId) =>
      RpcContext._(traceId: traceId);

  /// Создает копию контекста с дополнительными заголовками
  RpcContext withAdditionalHeaders(Map<String, String> additionalHeaders) {
    final newHeaders = Map<String, String>.from(_headers);
    newHeaders.addAll(additionalHeaders);

    return RpcContext._(
      headers: newHeaders,
      deadline: deadline,
      cancellationToken: cancellationToken,
      traceId: traceId,
      requestId: requestId,
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
        values: _values,
      );

  /// Создает копию контекста с новым timeout
  RpcContext withTimeout(Duration timeout) =>
      withDeadline(DateTime.now().add(timeout));

  /// Создает копию контекста с токеном отмены
  RpcContext withCancellation(CancellationToken token) => RpcContext._(
        headers: _headers,
        deadline: deadline,
        cancellationToken: token,
        traceId: traceId,
        requestId: requestId,
        values: _values,
      );

  /// Создает копию контекста с trace ID
  RpcContext withTraceId(String newTraceId) => RpcContext._(
        headers: _headers,
        deadline: deadline,
        cancellationToken: cancellationToken,
        traceId: newTraceId,
        requestId: requestId,
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
      values: newValues,
    );
  }

  /// Получает значение заголовка
  String? getHeader(String key) => _headers[key];

  /// Получает все заголовки (только для чтения)
  Map<String, String> get headers => Map.unmodifiable(_headers);

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
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp * 31) % 10000;
    return 'req_${timestamp}_$random';
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
}

/// Токен отмены операции (аналог context.CancelFunc в Go)
final class CancellationToken {
  final Completer<void> _completer = Completer<void>();
  String? _reason;

  /// Создает новый токен отмены
  CancellationToken();

  /// Создает уже отмененный токен
  CancellationToken.cancelled([String? reason]) {
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
  final String message;

  const RpcCancelledException(this.message);

  @override
  String toString() => 'RpcCancelledException: $message';
}

/// Исключение превышения deadline
final class RpcDeadlineExceededException implements Exception {
  final DateTime deadline;
  final Duration timeout;

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

    return RpcContext.withHeaders(headers)
        .withTraceId(traceId ?? _generateTraceId());
  }

  /// Генерирует новый trace ID
  static String _generateTraceId() {
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
      requestId: right.requestId, // Берем ID из правого контекста
      values: mergedValues,
    );
  }
}
