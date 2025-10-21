// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rpc_webauthn_contract.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_GetUserInfoParams _$GetUserInfoParamsFromJson(Map<String, dynamic> json) =>
    _GetUserInfoParams(userId: json['userId'] as String);

Map<String, dynamic> _$GetUserInfoParamsToJson(_GetUserInfoParams instance) =>
    <String, dynamic>{'userId': instance.userId};

_GetUserInfoResult _$GetUserInfoResultFromJson(Map<String, dynamic> json) =>
    _GetUserInfoResult(
      success: json['success'] as bool,
      userInfo: json['userInfo'] == null
          ? null
          : WebAuthnUserInfo.fromJson(json['userInfo'] as Map<String, dynamic>),
      errorMessage: json['errorMessage'] as String?,
    );

Map<String, dynamic> _$GetUserInfoResultToJson(_GetUserInfoResult instance) =>
    <String, dynamic>{
      'success': instance.success,
      'userInfo': instance.userInfo,
      'errorMessage': instance.errorMessage,
    };

_RemoveCredentialParams _$RemoveCredentialParamsFromJson(
  Map<String, dynamic> json,
) => _RemoveCredentialParams(
  userId: json['userId'] as String,
  credentialId: json['credentialId'] as String,
);

Map<String, dynamic> _$RemoveCredentialParamsToJson(
  _RemoveCredentialParams instance,
) => <String, dynamic>{
  'userId': instance.userId,
  'credentialId': instance.credentialId,
};

_RemoveCredentialResult _$RemoveCredentialResultFromJson(
  Map<String, dynamic> json,
) => _RemoveCredentialResult(
  success: json['success'] as bool,
  message: json['message'] as String?,
  errorMessage: json['errorMessage'] as String?,
);

Map<String, dynamic> _$RemoveCredentialResultToJson(
  _RemoveCredentialResult instance,
) => <String, dynamic>{
  'success': instance.success,
  'message': instance.message,
  'errorMessage': instance.errorMessage,
};

_GetCredentialsParams _$GetCredentialsParamsFromJson(
  Map<String, dynamic> json,
) => _GetCredentialsParams(userId: json['userId'] as String);

Map<String, dynamic> _$GetCredentialsParamsToJson(
  _GetCredentialsParams instance,
) => <String, dynamic>{'userId': instance.userId};

_GetCredentialsResult _$GetCredentialsResultFromJson(
  Map<String, dynamic> json,
) => _GetCredentialsResult(
  success: json['success'] as bool,
  credentials:
      (json['credentials'] as List<dynamic>?)
          ?.map(
            (e) => WebAuthnCredentialPublic.fromJson(e as Map<String, dynamic>),
          )
          .toList() ??
      const [],
  errorMessage: json['errorMessage'] as String?,
);

Map<String, dynamic> _$GetCredentialsResultToJson(
  _GetCredentialsResult instance,
) => <String, dynamic>{
  'success': instance.success,
  'credentials': instance.credentials,
  'errorMessage': instance.errorMessage,
};
