// GENERATED CODE - DO NOT MODIFY BY HAND

part of '_index.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_AuthResponse _$AuthResponseFromJson(Map<String, dynamic> json) =>
    _AuthResponse(
      accessToken: json['accessToken'] as String,
      expiresIn: (json['expiresIn'] as num).toInt(),
      userId: json['userId'] as String,
      tokenType: json['tokenType'] as String? ?? 'paseto',
      credential: json['credential'] == null
          ? null
          : WebAuthnCredentialPublic.fromJson(
              json['credential'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$AuthResponseToJson(_AuthResponse instance) =>
    <String, dynamic>{
      'accessToken': instance.accessToken,
      'expiresIn': instance.expiresIn,
      'userId': instance.userId,
      'tokenType': instance.tokenType,
      'credential': instance.credential,
    };

_PasetoTokenPayload _$PasetoTokenPayloadFromJson(Map<String, dynamic> json) =>
    _PasetoTokenPayload(
      sub: json['sub'] as String,
      exp: (json['exp'] as num).toInt(),
      iat: (json['iat'] as num).toInt(),
      jti: json['jti'] as String,
      scopes:
          (json['scopes'] as List<dynamic>).map((e) => e as String).toList(),
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$PasetoTokenPayloadToJson(_PasetoTokenPayload instance) =>
    <String, dynamic>{
      'sub': instance.sub,
      'exp': instance.exp,
      'iat': instance.iat,
      'jti': instance.jti,
      'scopes': instance.scopes,
      'extra': instance.extra,
    };

_WebAuthnAssertion _$WebAuthnAssertionFromJson(Map<String, dynamic> json) =>
    _WebAuthnAssertion(
      id: json['id'] as String,
      response: WebAuthnAssertionResponse.fromJson(
          json['response'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$WebAuthnAssertionToJson(_WebAuthnAssertion instance) =>
    <String, dynamic>{
      'id': instance.id,
      'response': instance.response,
    };

_WebAuthnAssertionResponse _$WebAuthnAssertionResponseFromJson(
        Map<String, dynamic> json) =>
    _WebAuthnAssertionResponse(
      authenticatorData: (json['authenticatorData'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      clientDataJSON: (json['clientDataJSON'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      signature: (json['signature'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      userHandle: (json['userHandle'] as List<dynamic>?)
          ?.map((e) => (e as num).toInt())
          .toList(),
    );

Map<String, dynamic> _$WebAuthnAssertionResponseToJson(
        _WebAuthnAssertionResponse instance) =>
    <String, dynamic>{
      'authenticatorData': instance.authenticatorData,
      'clientDataJSON': instance.clientDataJSON,
      'signature': instance.signature,
      'userHandle': instance.userHandle,
    };

_WebAuthnRegistrationCredential _$WebAuthnRegistrationCredentialFromJson(
        Map<String, dynamic> json) =>
    _WebAuthnRegistrationCredential(
      id: json['id'] as String,
      response: WebAuthnRegistrationResponse.fromJson(
          json['response'] as Map<String, dynamic>),
      type: json['type'] as String?,
      transports: json['transports'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$WebAuthnRegistrationCredentialToJson(
        _WebAuthnRegistrationCredential instance) =>
    <String, dynamic>{
      'id': instance.id,
      'response': instance.response,
      'type': instance.type,
      'transports': instance.transports,
    };

_WebAuthnRegistrationResponse _$WebAuthnRegistrationResponseFromJson(
        Map<String, dynamic> json) =>
    _WebAuthnRegistrationResponse(
      attestationObject: const Uint8ListConverter()
          .fromJson(json['attestationObject'] as String),
      clientDataJSON:
          const Uint8ListConverter().fromJson(json['clientDataJSON'] as String),
      extensions: json['extensions'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$WebAuthnRegistrationResponseToJson(
        _WebAuthnRegistrationResponse instance) =>
    <String, dynamic>{
      'attestationObject':
          const Uint8ListConverter().toJson(instance.attestationObject),
      'clientDataJSON':
          const Uint8ListConverter().toJson(instance.clientDataJSON),
      'extensions': instance.extensions,
    };

_WebAuthnUserInfo _$WebAuthnUserInfoFromJson(Map<String, dynamic> json) =>
    _WebAuthnUserInfo(
      credentials: (json['credentials'] as List<dynamic>)
          .map((e) =>
              WebAuthnCredentialPublic.fromJson(e as Map<String, dynamic>))
          .toList(),
      authenticatedCredential: json['authenticatedCredential'] == null
          ? null
          : WebAuthnCredentialPublic.fromJson(
              json['authenticatedCredential'] as Map<String, dynamic>),
      error: json['error'] == null
          ? null
          : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$WebAuthnUserInfoToJson(_WebAuthnUserInfo instance) =>
    <String, dynamic>{
      'credentials': instance.credentials,
      'authenticatedCredential': instance.authenticatedCredential,
      'error': instance.error,
    };

_WebAuthnRemoveResult _$WebAuthnRemoveResultFromJson(
        Map<String, dynamic> json) =>
    _WebAuthnRemoveResult(
      success: json['success'] as bool,
      error: json['error'] == null
          ? null
          : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$WebAuthnRemoveResultToJson(
        _WebAuthnRemoveResult instance) =>
    <String, dynamic>{
      'success': instance.success,
      'error': instance.error,
    };

_WebAuthnAuthContext _$WebAuthnAuthContextFromJson(Map<String, dynamic> json) =>
    _WebAuthnAuthContext(
      rpId: json['rpId'] as String,
      origin: json['origin'] as String,
      platform: json['platform'] as String,
      scopes:
          (json['scopes'] as List<dynamic>).map((e) => e as String).toList(),
      sessionId: json['sessionId'] as String?,
      isAuthenticated: json['isAuthenticated'] as bool? ?? false,
      credential: json['credential'] == null
          ? null
          : WebAuthnCredentialPublic.fromJson(
              json['credential'] as Map<String, dynamic>),
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
    );

Map<String, dynamic> _$WebAuthnAuthContextToJson(
        _WebAuthnAuthContext instance) =>
    <String, dynamic>{
      'rpId': instance.rpId,
      'origin': instance.origin,
      'platform': instance.platform,
      'scopes': instance.scopes,
      'sessionId': instance.sessionId,
      'isAuthenticated': instance.isAuthenticated,
      'credential': instance.credential,
      'metadata': instance.metadata,
    };

_AuthContextValidationResult _$AuthContextValidationResultFromJson(
        Map<String, dynamic> json) =>
    _AuthContextValidationResult(
      isValid: json['isValid'] as bool,
      errorMessage: json['errorMessage'] as String?,
      updatedContext: json['updatedContext'] == null
          ? null
          : WebAuthnAuthContext.fromJson(
              json['updatedContext'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$AuthContextValidationResultToJson(
        _AuthContextValidationResult instance) =>
    <String, dynamic>{
      'isValid': instance.isValid,
      'errorMessage': instance.errorMessage,
      'updatedContext': instance.updatedContext,
    };

_WebAuthnAuthorizationContext _$WebAuthnAuthorizationContextFromJson(
        Map<String, dynamic> json) =>
    _WebAuthnAuthorizationContext(
      currentUserId: json['currentUserId'] as String,
      permissions: (json['permissions'] as List<dynamic>)
          .map((e) => $enumDecode(_$WebAuthnPermissionEnumMap, e))
          .toList(),
      sessionId: json['sessionId'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
    );

Map<String, dynamic> _$WebAuthnAuthorizationContextToJson(
        _WebAuthnAuthorizationContext instance) =>
    <String, dynamic>{
      'currentUserId': instance.currentUserId,
      'permissions': instance.permissions
          .map((e) => _$WebAuthnPermissionEnumMap[e]!)
          .toList(),
      'sessionId': instance.sessionId,
      'metadata': instance.metadata,
    };

const _$WebAuthnPermissionEnumMap = {
  WebAuthnPermission.manageOwnCredentials: 'manageOwnCredentials',
  WebAuthnPermission.manageOwnSessions: 'manageOwnSessions',
  WebAuthnPermission.authenticateAsUser: 'authenticateAsUser',
  WebAuthnPermission.manageAnyCredentials: 'manageAnyCredentials',
  WebAuthnPermission.manageAnySessions: 'manageAnySessions',
  WebAuthnPermission.viewAnyUserInfo: 'viewAnyUserInfo',
  WebAuthnPermission.systemAdministration: 'systemAdministration',
};

_AuthorizationResult _$AuthorizationResultFromJson(Map<String, dynamic> json) =>
    _AuthorizationResult(
      isAuthorized: json['isAuthorized'] as bool,
      errorMessage: json['errorMessage'] as String?,
      errorCode: json['errorCode'] as String?,
    );

Map<String, dynamic> _$AuthorizationResultToJson(
        _AuthorizationResult instance) =>
    <String, dynamic>{
      'isAuthorized': instance.isAuthorized,
      'errorMessage': instance.errorMessage,
      'errorCode': instance.errorCode,
    };
