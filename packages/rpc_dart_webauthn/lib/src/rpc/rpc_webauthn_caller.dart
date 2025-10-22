import 'package:rpc_dart/rpc_dart.dart';

import '../../rpc_dart_webauthn.dart';

/// WebAuthn Caller - клиентская часть для вызова RPC методов
///
/// В CORD архитектуре это клиентская часть домена, которая
/// инкапсулирует RPC вызовы и предоставляет типизированный интерфейс.
/// Используется для взаимодействия с WebAuthn доменом извне.
final class WebAuthnCaller extends RpcCallerContract
    implements IWebAuthnContract {
  WebAuthnCaller(RpcCallerEndpoint endpoint)
    : super(IWebAuthnContract.serviceNameConst, endpoint);

  @override
  String get serviceName => IWebAuthnContract.serviceNameConst;

  // ================ Основные методы WebAuthn ================

  @override
  Future<StartRegistrationResult> startRegistration(
    StartRegistrationParams params,
  ) {
    return endpoint
        .unaryRequest<StartRegistrationParams, StartRegistrationResult>(
          serviceName: serviceName,
          methodName: IWebAuthnContract.startRegistrationMethod,
          requestCodec: StartRegistrationParams.codec,
          responseCodec: StartRegistrationResult.codec,
          request: params,
        );
  }

  @override
  Future<FinishRegistrationResult> finishRegistration(
    FinishRegistrationParams params,
  ) {
    return endpoint
        .unaryRequest<FinishRegistrationParams, FinishRegistrationResult>(
          serviceName: serviceName,
          methodName: IWebAuthnContract.finishRegistrationMethod,
          requestCodec: FinishRegistrationParams.codec,
          responseCodec: FinishRegistrationResult.codec,
          request: params,
        );
  }

  @override
  Future<StartAuthenticationResult> startAuthentication(
    StartAuthenticationParams params,
  ) {
    return endpoint
        .unaryRequest<StartAuthenticationParams, StartAuthenticationResult>(
          serviceName: serviceName,
          methodName: IWebAuthnContract.startAuthenticationMethod,
          requestCodec: StartAuthenticationParams.codec,
          responseCodec: StartAuthenticationResult.codec,
          request: params,
        );
  }

  @override
  Future<FinishAuthenticationResult> finishAuthentication(
    FinishAuthenticationParams params,
  ) {
    return endpoint
        .unaryRequest<FinishAuthenticationParams, FinishAuthenticationResult>(
          serviceName: serviceName,
          methodName: IWebAuthnContract.finishAuthenticationMethod,
          requestCodec: FinishAuthenticationParams.codec,
          responseCodec: FinishAuthenticationResult.codec,
          request: params,
        );
  }

  // ================ Управление учетными данными ================

  @override
  Future<GetUserInfoResult> getUserInfo(GetUserInfoParams params) {
    return endpoint.unaryRequest<GetUserInfoParams, GetUserInfoResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.getUserInfoMethod,
      requestCodec: GetUserInfoParams.codec,
      responseCodec: GetUserInfoResult.codec,
      request: params,
    );
  }

  @override
  Future<RemoveCredentialResult> removeCredential(
    RemoveCredentialParams params,
  ) {
    return endpoint
        .unaryRequest<RemoveCredentialParams, RemoveCredentialResult>(
          serviceName: serviceName,
          methodName: IWebAuthnContract.removeCredentialMethod,
          requestCodec: RemoveCredentialParams.codec,
          responseCodec: RemoveCredentialResult.codec,
          request: params,
        );
  }

  @override
  Future<GetCredentialsResult> getCredentials(GetCredentialsParams params) {
    return endpoint.unaryRequest<GetCredentialsParams, GetCredentialsResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.getCredentialsMethod,
      requestCodec: GetCredentialsParams.codec,
      responseCodec: GetCredentialsResult.codec,
      request: params,
    );
  }

  // ================ Управление токенами и сессиями ================

  @override
  Future<ValidateTokenResult> validateToken(ValidateTokenParams params) {
    return endpoint.unaryRequest<ValidateTokenParams, ValidateTokenResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.validateTokenMethod,
      requestCodec: ValidateTokenParams.codec,
      responseCodec: ValidateTokenResult.codec,
      request: params,
    );
  }

  @override
  Future<RefreshTokenResult> refreshToken(RefreshTokenParams params) {
    return endpoint.unaryRequest<RefreshTokenParams, RefreshTokenResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.refreshTokenMethod,
      requestCodec: RefreshTokenParams.codec,
      responseCodec: RefreshTokenResult.codec,
      request: params,
    );
  }

  @override
  Future<RevokeSessionResult> revokeSession(RevokeSessionParams params) {
    return endpoint.unaryRequest<RevokeSessionParams, RevokeSessionResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.revokeSessionMethod,
      requestCodec: RevokeSessionParams.codec,
      responseCodec: RevokeSessionResult.codec,
      request: params,
    );
  }

  @override
  Future<RevokeSessionResult> revokeAllSessions(
    RevokeAllSessionsParams params,
  ) {
    return endpoint.unaryRequest<RevokeAllSessionsParams, RevokeSessionResult>(
      serviceName: serviceName,
      methodName: IWebAuthnContract.revokeAllSessionsMethod,
      requestCodec: RevokeAllSessionsParams.codec,
      responseCodec: RevokeSessionResult.codec,
      request: params,
    );
  }
}
