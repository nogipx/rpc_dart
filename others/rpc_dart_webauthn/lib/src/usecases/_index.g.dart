// GENERATED CODE - DO NOT MODIFY BY HAND

part of '_index.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_FinishAuthenticationParams _$FinishAuthenticationParamsFromJson(
  Map<String, dynamic> json,
) => _FinishAuthenticationParams(
  userId: json['userId'] as String,
  assertion: WebAuthnAssertion.fromJson(
    json['assertion'] as Map<String, dynamic>,
  ),
  origin: json['origin'] as String,
  expiresIn: (json['expiresIn'] as num).toInt(),
  scopes: (json['scopes'] as List<dynamic>).map((e) => e as String).toList(),
  platform: json['platform'] as String? ?? 'web',
);

Map<String, dynamic> _$FinishAuthenticationParamsToJson(
  _FinishAuthenticationParams instance,
) => <String, dynamic>{
  'userId': instance.userId,
  'assertion': instance.assertion,
  'origin': instance.origin,
  'expiresIn': instance.expiresIn,
  'scopes': instance.scopes,
  'platform': instance.platform,
};

_FinishAuthenticationResult _$FinishAuthenticationResultFromJson(
  Map<String, dynamic> json,
) => _FinishAuthenticationResult(
  success: json['success'] as bool,
  authResponse: json['authResponse'] == null
      ? null
      : AuthResponse.fromJson(json['authResponse'] as Map<String, dynamic>),
  error: json['error'] == null
      ? null
      : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
);

Map<String, dynamic> _$FinishAuthenticationResultToJson(
  _FinishAuthenticationResult instance,
) => <String, dynamic>{
  'success': instance.success,
  'authResponse': instance.authResponse,
  'error': instance.error,
};

_FinishRegistrationParams _$FinishRegistrationParamsFromJson(
  Map<String, dynamic> json,
) => _FinishRegistrationParams(
  userId: json['userId'] as String,
  credential: WebAuthnRegistrationCredential.fromJson(
    json['credential'] as Map<String, dynamic>,
  ),
  origin: json['origin'] as String,
  platform: json['platform'] as String? ?? 'web',
);

Map<String, dynamic> _$FinishRegistrationParamsToJson(
  _FinishRegistrationParams instance,
) => <String, dynamic>{
  'userId': instance.userId,
  'credential': instance.credential,
  'origin': instance.origin,
  'platform': instance.platform,
};

_FinishRegistrationResult _$FinishRegistrationResultFromJson(
  Map<String, dynamic> json,
) => _FinishRegistrationResult(
  success: json['success'] as bool,
  credential: json['credential'] == null
      ? null
      : WebAuthnCredentialPublic.fromJson(
          json['credential'] as Map<String, dynamic>,
        ),
  error: json['error'] == null
      ? null
      : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
);

Map<String, dynamic> _$FinishRegistrationResultToJson(
  _FinishRegistrationResult instance,
) => <String, dynamic>{
  'success': instance.success,
  'credential': instance.credential,
  'error': instance.error,
};

_RevokeSessionParams _$RevokeSessionParamsFromJson(Map<String, dynamic> json) =>
    _RevokeSessionParams(
      sessionId: json['sessionId'] as String,
      reason: json['reason'] as String?,
    );

Map<String, dynamic> _$RevokeSessionParamsToJson(
  _RevokeSessionParams instance,
) => <String, dynamic>{
  'sessionId': instance.sessionId,
  'reason': instance.reason,
};

_RevokeAllSessionsParams _$RevokeAllSessionsParamsFromJson(
  Map<String, dynamic> json,
) => _RevokeAllSessionsParams(
  userId: json['userId'] as String,
  reason: json['reason'] as String?,
);

Map<String, dynamic> _$RevokeAllSessionsParamsToJson(
  _RevokeAllSessionsParams instance,
) => <String, dynamic>{'userId': instance.userId, 'reason': instance.reason};

_RevokeSessionResult _$RevokeSessionResultFromJson(Map<String, dynamic> json) =>
    _RevokeSessionResult(
      success: json['success'] as bool,
      revokedCount: (json['revokedCount'] as num).toInt(),
      message: json['message'] as String?,
      error: json['error'] == null
          ? null
          : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$RevokeSessionResultToJson(
  _RevokeSessionResult instance,
) => <String, dynamic>{
  'success': instance.success,
  'revokedCount': instance.revokedCount,
  'message': instance.message,
  'error': instance.error,
};

_StartAuthenticationParams _$StartAuthenticationParamsFromJson(
  Map<String, dynamic> json,
) => _StartAuthenticationParams(userId: json['userId'] as String);

Map<String, dynamic> _$StartAuthenticationParamsToJson(
  _StartAuthenticationParams instance,
) => <String, dynamic>{'userId': instance.userId};

_StartAuthenticationResult _$StartAuthenticationResultFromJson(
  Map<String, dynamic> json,
) => _StartAuthenticationResult(
  options: json['options'] == null
      ? null
      : AuthenticationOptions.fromJson(json['options'] as Map<String, dynamic>),
  error: json['error'] == null
      ? null
      : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
);

Map<String, dynamic> _$StartAuthenticationResultToJson(
  _StartAuthenticationResult instance,
) => <String, dynamic>{'options': instance.options, 'error': instance.error};

_StartRegistrationParams _$StartRegistrationParamsFromJson(
  Map<String, dynamic> json,
) => _StartRegistrationParams(
  userId: json['userId'] as String,
  userHandle: (json['userHandle'] as List<dynamic>?)
      ?.map((e) => (e as num).toInt())
      .toList(),
  username: json['username'] as String?,
  displayName: json['displayName'] as String?,
);

Map<String, dynamic> _$StartRegistrationParamsToJson(
  _StartRegistrationParams instance,
) => <String, dynamic>{
  'userId': instance.userId,
  'userHandle': instance.userHandle,
  'username': instance.username,
  'displayName': instance.displayName,
};

_StartRegistrationResult _$StartRegistrationResultFromJson(
  Map<String, dynamic> json,
) => _StartRegistrationResult(
  options: json['options'] == null
      ? null
      : RegistrationOptions.fromJson(json['options'] as Map<String, dynamic>),
  error: json['error'] == null
      ? null
      : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
);

Map<String, dynamic> _$StartRegistrationResultToJson(
  _StartRegistrationResult instance,
) => <String, dynamic>{'options': instance.options, 'error': instance.error};

_ValidateTokenParams _$ValidateTokenParamsFromJson(Map<String, dynamic> json) =>
    _ValidateTokenParams(
      token: json['token'] as String,
      context: json['context'] == null
          ? null
          : WebAuthnAuthContext.fromJson(
              json['context'] as Map<String, dynamic>,
            ),
    );

Map<String, dynamic> _$ValidateTokenParamsToJson(
  _ValidateTokenParams instance,
) => <String, dynamic>{'token': instance.token, 'context': instance.context};

_ValidateTokenResult _$ValidateTokenResultFromJson(Map<String, dynamic> json) =>
    _ValidateTokenResult(
      isValid: json['isValid'] as bool,
      credential: json['credential'] == null
          ? null
          : WebAuthnCredentialPublic.fromJson(
              json['credential'] as Map<String, dynamic>,
            ),
      context: json['context'] == null
          ? null
          : WebAuthnAuthContext.fromJson(
              json['context'] as Map<String, dynamic>,
            ),
      errorMessage: json['errorMessage'] as String?,
      error: json['error'] == null
          ? null
          : WebAuthnException.fromJson(json['error'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ValidateTokenResultToJson(
  _ValidateTokenResult instance,
) => <String, dynamic>{
  'isValid': instance.isValid,
  'credential': instance.credential,
  'context': instance.context,
  'errorMessage': instance.errorMessage,
  'error': instance.error,
};
