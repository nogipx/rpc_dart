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
  });

  final int status;
  final String? code;
  final Map<String, dynamic>? details;

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
      );

  factory RpcDataError.deadlineExceeded(String message) => RpcDataError(
    message,
    status: RpcStatus.deadlineExceeded,
    code: 'DEADLINE_EXCEEDED',
  );
}
