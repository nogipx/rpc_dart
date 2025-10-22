// Базовый класс для всех исключений WebAuthn

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:rpc_dart/rpc_dart.dart';

part 'web_authn_exceptions.freezed.dart';
part 'web_authn_exceptions.g.dart';

enum WebAuthnExceptionType {
  registration,
  authentication,
  credential,
  signatureVerification,
  timeout,
  originMismatch,
  authorization,
}

@freezed
@Implements<Exception>()
abstract class WebAuthnException with _$WebAuthnException {
  const WebAuthnException._();

  const factory WebAuthnException({
    required WebAuthnExceptionType type,
    required String message,
    @StackTraceConverter() StackTrace? stackTrace,
  }) = _WebAuthnException;

  factory WebAuthnException.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnExceptionFromJson(json);

  factory WebAuthnException.registration(
    String message, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.registration,
    message: message,
    stackTrace: stackTrace ?? StackTrace.current,
  );

  factory WebAuthnException.authentication(
    String message, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.authentication,
    message: message,
    stackTrace: stackTrace ?? StackTrace.current,
  );

  factory WebAuthnException.credential(
    String message, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.credential,
    message: message,
    stackTrace: stackTrace ?? StackTrace.current,
  );

  factory WebAuthnException.signatureVerification(
    String message, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.signatureVerification,
    message: message,
    stackTrace: stackTrace ?? StackTrace.current,
  );

  factory WebAuthnException.timeout(String message, [StackTrace? stackTrace]) =>
      WebAuthnException(
        type: WebAuthnExceptionType.timeout,
        message: message,
        stackTrace: stackTrace ?? StackTrace.current,
      );

  factory WebAuthnException.authorization(
    String message, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.authorization,
    message: message,
    stackTrace: stackTrace ?? StackTrace.current,
  );

  factory WebAuthnException.originMismatch(
    String expected,
    String actual, [
    StackTrace? stackTrace,
  ]) => WebAuthnException(
    type: WebAuthnExceptionType.originMismatch,
    message: 'Origin mismatch. Expected: $expected, actual: $actual',
    stackTrace: stackTrace ?? StackTrace.current,
  );
}

/// Специальное исключение для недействительных токенов авторизации
/// Наследуется от RpcException для точной идентификации в клиентском коде
class InvalidTokenException extends RpcException {
  InvalidTokenException(super.message);

  /// Токен отсутствует
  InvalidTokenException.missing() : super('Отсутствует токен авторизации');

  /// Токен недействителен (не валидируется)
  InvalidTokenException.invalid() : super('Недействительный токен авторизации');

  /// Токен истек
  InvalidTokenException.expired() : super('Токен авторизации истек');

  /// Недостаточно прав
  InvalidTokenException.insufficientPermissions([String? details])
    : super(details ?? 'Недостаточно прав для выполнения операции');
}

class StackTraceConverter implements JsonConverter<StackTrace?, String?> {
  const StackTraceConverter();

  @override
  StackTrace? fromJson(String? json) =>
      json != null && json.isNotEmpty ? StackTrace.fromString(json) : null;

  @override
  String? toJson(StackTrace? object) => object?.toString() ?? '';
}
