// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'web_authn_exceptions.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_WebAuthnException _$WebAuthnExceptionFromJson(Map<String, dynamic> json) =>
    _WebAuthnException(
      type: $enumDecode(_$WebAuthnExceptionTypeEnumMap, json['type']),
      message: json['message'] as String,
      stackTrace: const StackTraceConverter().fromJson(
        json['stackTrace'] as String?,
      ),
    );

Map<String, dynamic> _$WebAuthnExceptionToJson(_WebAuthnException instance) =>
    <String, dynamic>{
      'type': _$WebAuthnExceptionTypeEnumMap[instance.type]!,
      'message': instance.message,
      'stackTrace': const StackTraceConverter().toJson(instance.stackTrace),
    };

const _$WebAuthnExceptionTypeEnumMap = {
  WebAuthnExceptionType.registration: 'registration',
  WebAuthnExceptionType.authentication: 'authentication',
  WebAuthnExceptionType.credential: 'credential',
  WebAuthnExceptionType.signatureVerification: 'signatureVerification',
  WebAuthnExceptionType.timeout: 'timeout',
  WebAuthnExceptionType.originMismatch: 'originMismatch',
  WebAuthnExceptionType.authorization: 'authorization',
};
