// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Базовый класс для ошибок сервиса данных.
@immutable
class RpcDataError extends RpcException {
  RpcDataError(
    super.message, {
    required this.status,
    this.code,
    this.details,
    this.cause,
  });

  final int status;
  final String? code;
  final Map<String, dynamic>? details;

  /// Исходная ошибка, которую эта обёртка заменила собой.
  ///
  /// Хранится отдельно от [details], потому что у неё другая судьба: [details]
  /// едет по проводу, а [cause] — нет. Всё, что заворачивается в
  /// `internal`, пересекая границу процесса, теряет её намеренно (см.
  /// `DataServiceResponder`): удалённому вызывающему нельзя показывать
  /// внутренности бэкенда, а вот в своём же логе они и есть весь ответ.
  final Object? cause;

  /// С причиной, если она известна.
  ///
  /// Причина была и раньше — в `details['cause']`, — но её никто не видел:
  /// вызывающие пишут в лог интерполяцию `'...: $e'`, а
  /// `RpcException.toString()` печатает только `message`. Пользователь
  /// прислал отчёт с 2450 строками `Unhandled repository error` подряд, ни
  /// одна из которых не называла ни ошибку SQLite, ни оператор, на котором
  /// она случилась. Обёртка, которая знает причину и молчит о ней, хуже
  /// отсутствия обёртки.
  @override
  String toString() {
    final base = super.toString();
    return cause == null ? base : '$base: $cause';
  }

  factory RpcDataError.permissionDenied(String message) => RpcDataError(
    message,
    status: RpcStatus.permissionDenied,
    code: 'PERMISSION_DENIED',
  );

  factory RpcDataError.cancelled(String message) =>
      RpcDataError(message, status: RpcStatus.cancelled, code: 'CANCELLED');

  factory RpcDataError.invalidArgument(
    String message, {
    Map<String, dynamic>? details,
  }) => RpcDataError(
    message,
    status: RpcStatus.invalidArgument,
    code: 'INVALID_ARGUMENT',
    details: details,
  );

  factory RpcDataError.notFound(String message) =>
      RpcDataError(message, status: RpcStatus.notFound, code: 'NOT_FOUND');

  factory RpcDataError.conflict(
    String message, {
    Map<String, dynamic>? details,
  }) => RpcDataError(
    message,
    status: RpcStatus.aborted,
    code: 'VERSION_CONFLICT',
    details: details,
  );

  factory RpcDataError.unauthenticated(String message) => RpcDataError(
    message,
    status: RpcStatus.unauthenticated,
    code: 'UNAUTHENTICATED',
  );

  factory RpcDataError.internal(String message, {Object? error}) =>
      RpcDataError(
        message,
        status: RpcStatus.internal,
        code: 'INTERNAL',
        details: error != null ? {'cause': error.toString()} : null,
        cause: error,
      );

  /// Эта же ошибка без причины — для отправки по проводу.
  ///
  /// Снимает только причину: `details` несёт и то, что вызывающему полагается
  /// знать (номер версии при конфликте, какое поле не прошло валидацию), и это
  /// остаётся. Возвращает себя, когда терять нечего, поэтому звать можно на
  /// любой ошибке.
  RpcDataError withoutCause() {
    final rest = details == null
        ? null
        : {
            for (final e in details!.entries)
              if (e.key != 'cause') e.key: e.value,
          };
    if (cause == null && (rest?.length ?? 0) == (details?.length ?? 0)) {
      return this;
    }
    return RpcDataError(
      message,
      status: status,
      code: code,
      details: (rest?.isEmpty ?? true) ? null : rest,
    );
  }

  factory RpcDataError.deadlineExceeded(String message) => RpcDataError(
    message,
    status: RpcStatus.deadlineExceeded,
    code: 'DEADLINE_EXCEEDED',
  );

  /// The `google.rpc.ErrorInfo` domain a data error travels under.
  static const wireDomain = 'rpc_data';

  /// This error as it goes on the wire: its [status], its message, and an
  /// `ErrorInfo` carrying [code] and [details] (each value JSON-encoded).
  ///
  /// rpc_dart forwards the status of an [RpcStatusException] only; any other
  /// [RpcException] reaches the caller as INTERNAL. So without this a version
  /// conflict, a permission denial and a validation failure all arrived as
  /// status 13, and `on RpcDataError` caught none of them. Call
  /// [withoutCause] first: [cause] must not cross the process boundary.
  RpcStatusException toStatusException() => RpcStatusException(
    status,
    message,
    details: [
      RpcErrorInfo(
        reason: code ?? '',
        domain: wireDomain,
        metadata: {
          for (final entry in (details ?? const <String, dynamic>{}).entries)
            if (entry.key != 'cause') entry.key: _encodeDetail(entry.value),
        },
      ),
    ],
  );

  /// The data error [error] carries, or null when it was not sent by
  /// [toStatusException].
  static RpcDataError? fromStatusException(RpcStatusException error) {
    for (final detail in error.details) {
      if (detail is! RpcErrorInfo || detail.domain != wireDomain) continue;
      return RpcDataError(
        error.message,
        status: error.statusCode,
        code: detail.reason.isEmpty ? null : detail.reason,
        details: detail.metadata.isEmpty
            ? null
            : {
                for (final entry in detail.metadata.entries)
                  entry.key: _decodeDetail(entry.value),
              },
      );
    }
    return null;
  }

  static String _encodeDetail(Object? value) {
    try {
      return jsonEncode(value);
    } on Object {
      return jsonEncode(value.toString());
    }
  }

  static Object? _decodeDetail(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return value;
    }
  }
}
