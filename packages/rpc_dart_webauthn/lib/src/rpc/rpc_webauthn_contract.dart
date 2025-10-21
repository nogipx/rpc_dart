import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../../rpc_dart_webauthn.dart';
rt';
// Экспортируем модели из юзкейсов для контракта
export '../usecases/_index.dart'
    show
        StartRegistrationParams,
        StartRegistrationResult,
        FinishRegistrationParams,
        FinishRegistrationResult,
        StartAuthenticationParams,
        StartAuthenticationResult,
        FinishAuthenticationParams,
        FinishAuthenticationResult,
        ValidateTokenParams,
        ValidateTokenResult,
        RevokeSessionParams,
        RevokeAllSessionsParams,
        RevokeSessionResult;

part 'rpc_webauthn_contract.freezed.dart';
part 'rpc_webauthn_contract.g.dart';

// ================ Контракт домена WebAuthn ================

/// Контракт домена WebAuthn для CORD архитектуры
/// Определяет все операции, доступные в домене WebAuthn
///
/// Использует модели напрямую из юзкейсов для избежания дублирования
abstract interface class IWebAuthnContract implements IRpcContract {
  // ================ Константы сервиса и методов ================

  /// Название сервиса WebAuthn
  static const String serviceNameConst = 'WebAuthnService';

  /// Названия методов
  static const String startRegistrationMethod = 'startRegistration';
  static const String finishRegistrationMethod = 'finishRegistration';
  static const String startAuthenticationMethod = 'startAuthentication';
  static const String finishAuthenticationMethod = 'finishAuthentication';
  static const String getUserInfoMethod = 'getUserInfo';
  static const String removeCredentialMethod = 'removeCredential';
  static const String getCredentialsMethod = 'getCredentials';
  static const String validateTokenMethod = 'validateToken';
  static const String revokeSessionMethod = 'revokeSession';
  static const String revokeAllSessionsMethod = 'revokeAllSessions';

  // ================ Основные методы WebAuthn ================

  /// Начинает процесс регистрации WebAuthn
  Future<StartRegistrationResult> startRegistration(StartRegistrationParams params);

  /// Завершает процесс регистрации WebAuthn
  Future<FinishRegistrationResult> finishRegistration(FinishRegistrationParams params);

  /// Начинает процесс аутентификации WebAuthn
  Future<StartAuthenticationResult> startAuthentication(StartAuthenticationParams params);

  /// Завершает процесс аутентификации WebAuthn
  Future<FinishAuthenticationResult> finishAuthentication(FinishAuthenticationParams params);

  // ================ Управление учетными данными ================

  /// Получает информацию о пользователе и его учетных данных
  Future<GetUserInfoResult> getUserInfo(GetUserInfoParams params);

  /// Удаляет учетные данные пользователя
  Future<RemoveCredentialResult> removeCredential(RemoveCredentialParams params);

  /// Получает список всех учетных данных пользователя
  Future<GetCredentialsResult> getCredentials(GetCredentialsParams params);

  // ================ Управление токенами и сессиями ================

  /// Валидирует PASETO токен
  Future<ValidateTokenResult> validateToken(ValidateTokenParams params);

  /// Отзывает сессию пользователя
  Future<RevokeSessionResult> revokeSession(RevokeSessionParams params);

  /// Отзывает все сессии пользователя
  Future<RevokeSessionResult> revokeAllSessions(RevokeAllSessionsParams params);
}

// ================ Дополнительные модели для управления учетными данными ================

/// Параметры для получения информации о пользователе
@freezed
abstract class GetUserInfoParams with _$GetUserInfoParams implements IRpcSerializable {
  const factory GetUserInfoParams({
    required String userId,
  }) = _GetUserInfoParams;

  factory GetUserInfoParams.fromJson(Map<String, dynamic> json) =>
      _$GetUserInfoParamsFromJson(json);

  static RpcCodec<GetUserInfoParams> get codec => RpcCodec(GetUserInfoParams.fromJson);
}

/// Результат получения информации о пользователе
@freezed
abstract class GetUserInfoResult with _$GetUserInfoResult implements IRpcSerializable {
  const factory GetUserInfoResult({
    required bool success,
    WebAuthnUserInfo? userInfo,
    String? errorMessage,
  }) = _GetUserInfoResult;

  factory GetUserInfoResult.fromJson(Map<String, dynamic> json) =>
      _$GetUserInfoResultFromJson(json);

  static RpcCodec<GetUserInfoResult> get codec => RpcCodec(GetUserInfoResult.fromJson);
}

/// Параметры для удаления учетных данных
@freezed
abstract class RemoveCredentialParams with _$RemoveCredentialParams implements IRpcSerializable {
  const factory RemoveCredentialParams({
    required String userId,
    required String credentialId,
  }) = _RemoveCredentialParams;

  factory RemoveCredentialParams.fromJson(Map<String, dynamic> json) =>
      _$RemoveCredentialParamsFromJson(json);

  static RpcCodec<RemoveCredentialParams> get codec => RpcCodec(RemoveCredentialParams.fromJson);
}

/// Результат удаления учетных данных
@freezed
abstract class RemoveCredentialResult with _$RemoveCredentialResult implements IRpcSerializable {
  const factory RemoveCredentialResult({
    required bool success,
    String? message,
    String? errorMessage,
  }) = _RemoveCredentialResult;

  factory RemoveCredentialResult.fromJson(Map<String, dynamic> json) =>
      _$RemoveCredentialResultFromJson(json);

  static RpcCodec<RemoveCredentialResult> get codec => RpcCodec(RemoveCredentialResult.fromJson);
}

/// Параметры для получения списка учетных данных
@freezed
abstract class GetCredentialsParams with _$GetCredentialsParams implements IRpcSerializable {
  const factory GetCredentialsParams({
    required String userId,
  }) = _GetCredentialsParams;

  factory GetCredentialsParams.fromJson(Map<String, dynamic> json) =>
      _$GetCredentialsParamsFromJson(json);

  static RpcCodec<GetCredentialsParams> get codec => RpcCodec(GetCredentialsParams.fromJson);
}

/// Результат получения списка учетных данных
@freezed
abstract class GetCredentialsResult with _$GetCredentialsResult implements IRpcSerializable {
  const factory GetCredentialsResult({
    required bool success,
    @Default([]) List<WebAuthnCredentialPublic> credentials,
    String? errorMessage,
  }) = _GetCredentialsResult;

  factory GetCredentialsResult.fromJson(Map<String, dynamic> json) =>
      _$GetCredentialsResultFromJson(json);

  static RpcCodec<GetCredentialsResult> get codec => RpcCodec(GetCredentialsResult.fromJson);
}
