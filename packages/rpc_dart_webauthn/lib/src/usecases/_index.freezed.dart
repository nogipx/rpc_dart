// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '_index.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$FinishAuthenticationParams {

 String get userId; WebAuthnAssertion get assertion; String get origin; int get expiresIn; List<String> get scopes; String get platform;
/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FinishAuthenticationParamsCopyWith<FinishAuthenticationParams> get copyWith => _$FinishAuthenticationParamsCopyWithImpl<FinishAuthenticationParams>(this as FinishAuthenticationParams, _$identity);

  /// Serializes this FinishAuthenticationParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FinishAuthenticationParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.assertion, assertion) || other.assertion == assertion)&&(identical(other.origin, origin) || other.origin == origin)&&(identical(other.expiresIn, expiresIn) || other.expiresIn == expiresIn)&&const DeepCollectionEquality().equals(other.scopes, scopes)&&(identical(other.platform, platform) || other.platform == platform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,assertion,origin,expiresIn,const DeepCollectionEquality().hash(scopes),platform);

@override
String toString() {
  return 'FinishAuthenticationParams(userId: $userId, assertion: $assertion, origin: $origin, expiresIn: $expiresIn, scopes: $scopes, platform: $platform)';
}


}

/// @nodoc
abstract mixin class $FinishAuthenticationParamsCopyWith<$Res>  {
  factory $FinishAuthenticationParamsCopyWith(FinishAuthenticationParams value, $Res Function(FinishAuthenticationParams) _then) = _$FinishAuthenticationParamsCopyWithImpl;
@useResult
$Res call({
 String userId, WebAuthnAssertion assertion, String origin, int expiresIn, List<String> scopes, String platform
});


$WebAuthnAssertionCopyWith<$Res> get assertion;

}
/// @nodoc
class _$FinishAuthenticationParamsCopyWithImpl<$Res>
    implements $FinishAuthenticationParamsCopyWith<$Res> {
  _$FinishAuthenticationParamsCopyWithImpl(this._self, this._then);

  final FinishAuthenticationParams _self;
  final $Res Function(FinishAuthenticationParams) _then;

/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,Object? assertion = null,Object? origin = null,Object? expiresIn = null,Object? scopes = null,Object? platform = null,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,assertion: null == assertion ? _self.assertion : assertion // ignore: cast_nullable_to_non_nullable
as WebAuthnAssertion,origin: null == origin ? _self.origin : origin // ignore: cast_nullable_to_non_nullable
as String,expiresIn: null == expiresIn ? _self.expiresIn : expiresIn // ignore: cast_nullable_to_non_nullable
as int,scopes: null == scopes ? _self.scopes : scopes // ignore: cast_nullable_to_non_nullable
as List<String>,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,
  ));
}
/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAssertionCopyWith<$Res> get assertion {
  
  return $WebAuthnAssertionCopyWith<$Res>(_self.assertion, (value) {
    return _then(_self.copyWith(assertion: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _FinishAuthenticationParams implements FinishAuthenticationParams {
  const _FinishAuthenticationParams({required this.userId, required this.assertion, required this.origin, required this.expiresIn, required final  List<String> scopes, this.platform = 'web'}): _scopes = scopes;
  factory _FinishAuthenticationParams.fromJson(Map<String, dynamic> json) => _$FinishAuthenticationParamsFromJson(json);

@override final  String userId;
@override final  WebAuthnAssertion assertion;
@override final  String origin;
@override final  int expiresIn;
 final  List<String> _scopes;
@override List<String> get scopes {
  if (_scopes is EqualUnmodifiableListView) return _scopes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_scopes);
}

@override@JsonKey() final  String platform;

/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FinishAuthenticationParamsCopyWith<_FinishAuthenticationParams> get copyWith => __$FinishAuthenticationParamsCopyWithImpl<_FinishAuthenticationParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FinishAuthenticationParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FinishAuthenticationParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.assertion, assertion) || other.assertion == assertion)&&(identical(other.origin, origin) || other.origin == origin)&&(identical(other.expiresIn, expiresIn) || other.expiresIn == expiresIn)&&const DeepCollectionEquality().equals(other._scopes, _scopes)&&(identical(other.platform, platform) || other.platform == platform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,assertion,origin,expiresIn,const DeepCollectionEquality().hash(_scopes),platform);

@override
String toString() {
  return 'FinishAuthenticationParams(userId: $userId, assertion: $assertion, origin: $origin, expiresIn: $expiresIn, scopes: $scopes, platform: $platform)';
}


}

/// @nodoc
abstract mixin class _$FinishAuthenticationParamsCopyWith<$Res> implements $FinishAuthenticationParamsCopyWith<$Res> {
  factory _$FinishAuthenticationParamsCopyWith(_FinishAuthenticationParams value, $Res Function(_FinishAuthenticationParams) _then) = __$FinishAuthenticationParamsCopyWithImpl;
@override @useResult
$Res call({
 String userId, WebAuthnAssertion assertion, String origin, int expiresIn, List<String> scopes, String platform
});


@override $WebAuthnAssertionCopyWith<$Res> get assertion;

}
/// @nodoc
class __$FinishAuthenticationParamsCopyWithImpl<$Res>
    implements _$FinishAuthenticationParamsCopyWith<$Res> {
  __$FinishAuthenticationParamsCopyWithImpl(this._self, this._then);

  final _FinishAuthenticationParams _self;
  final $Res Function(_FinishAuthenticationParams) _then;

/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,Object? assertion = null,Object? origin = null,Object? expiresIn = null,Object? scopes = null,Object? platform = null,}) {
  return _then(_FinishAuthenticationParams(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,assertion: null == assertion ? _self.assertion : assertion // ignore: cast_nullable_to_non_nullable
as WebAuthnAssertion,origin: null == origin ? _self.origin : origin // ignore: cast_nullable_to_non_nullable
as String,expiresIn: null == expiresIn ? _self.expiresIn : expiresIn // ignore: cast_nullable_to_non_nullable
as int,scopes: null == scopes ? _self._scopes : scopes // ignore: cast_nullable_to_non_nullable
as List<String>,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

/// Create a copy of FinishAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAssertionCopyWith<$Res> get assertion {
  
  return $WebAuthnAssertionCopyWith<$Res>(_self.assertion, (value) {
    return _then(_self.copyWith(assertion: value));
  });
}
}


/// @nodoc
mixin _$FinishAuthenticationResult {

 bool get success; AuthResponse? get authResponse; WebAuthnException? get error;
/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FinishAuthenticationResultCopyWith<FinishAuthenticationResult> get copyWith => _$FinishAuthenticationResultCopyWithImpl<FinishAuthenticationResult>(this as FinishAuthenticationResult, _$identity);

  /// Serializes this FinishAuthenticationResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FinishAuthenticationResult&&(identical(other.success, success) || other.success == success)&&(identical(other.authResponse, authResponse) || other.authResponse == authResponse)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,authResponse,error);

@override
String toString() {
  return 'FinishAuthenticationResult(success: $success, authResponse: $authResponse, error: $error)';
}


}

/// @nodoc
abstract mixin class $FinishAuthenticationResultCopyWith<$Res>  {
  factory $FinishAuthenticationResultCopyWith(FinishAuthenticationResult value, $Res Function(FinishAuthenticationResult) _then) = _$FinishAuthenticationResultCopyWithImpl;
@useResult
$Res call({
 bool success, AuthResponse? authResponse, WebAuthnException? error
});


$AuthResponseCopyWith<$Res>? get authResponse;$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$FinishAuthenticationResultCopyWithImpl<$Res>
    implements $FinishAuthenticationResultCopyWith<$Res> {
  _$FinishAuthenticationResultCopyWithImpl(this._self, this._then);

  final FinishAuthenticationResult _self;
  final $Res Function(FinishAuthenticationResult) _then;

/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? success = null,Object? authResponse = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,authResponse: freezed == authResponse ? _self.authResponse : authResponse // ignore: cast_nullable_to_non_nullable
as AuthResponse?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AuthResponseCopyWith<$Res>? get authResponse {
    if (_self.authResponse == null) {
    return null;
  }

  return $AuthResponseCopyWith<$Res>(_self.authResponse!, (value) {
    return _then(_self.copyWith(authResponse: value));
  });
}/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _FinishAuthenticationResult extends FinishAuthenticationResult {
  const _FinishAuthenticationResult({required this.success, this.authResponse, this.error}): super._();
  factory _FinishAuthenticationResult.fromJson(Map<String, dynamic> json) => _$FinishAuthenticationResultFromJson(json);

@override final  bool success;
@override final  AuthResponse? authResponse;
@override final  WebAuthnException? error;

/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FinishAuthenticationResultCopyWith<_FinishAuthenticationResult> get copyWith => __$FinishAuthenticationResultCopyWithImpl<_FinishAuthenticationResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FinishAuthenticationResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FinishAuthenticationResult&&(identical(other.success, success) || other.success == success)&&(identical(other.authResponse, authResponse) || other.authResponse == authResponse)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,authResponse,error);

@override
String toString() {
  return 'FinishAuthenticationResult(success: $success, authResponse: $authResponse, error: $error)';
}


}

/// @nodoc
abstract mixin class _$FinishAuthenticationResultCopyWith<$Res> implements $FinishAuthenticationResultCopyWith<$Res> {
  factory _$FinishAuthenticationResultCopyWith(_FinishAuthenticationResult value, $Res Function(_FinishAuthenticationResult) _then) = __$FinishAuthenticationResultCopyWithImpl;
@override @useResult
$Res call({
 bool success, AuthResponse? authResponse, WebAuthnException? error
});


@override $AuthResponseCopyWith<$Res>? get authResponse;@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$FinishAuthenticationResultCopyWithImpl<$Res>
    implements _$FinishAuthenticationResultCopyWith<$Res> {
  __$FinishAuthenticationResultCopyWithImpl(this._self, this._then);

  final _FinishAuthenticationResult _self;
  final $Res Function(_FinishAuthenticationResult) _then;

/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? success = null,Object? authResponse = freezed,Object? error = freezed,}) {
  return _then(_FinishAuthenticationResult(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,authResponse: freezed == authResponse ? _self.authResponse : authResponse // ignore: cast_nullable_to_non_nullable
as AuthResponse?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AuthResponseCopyWith<$Res>? get authResponse {
    if (_self.authResponse == null) {
    return null;
  }

  return $AuthResponseCopyWith<$Res>(_self.authResponse!, (value) {
    return _then(_self.copyWith(authResponse: value));
  });
}/// Create a copy of FinishAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
mixin _$FinishRegistrationParams {

 String get userId; WebAuthnRegistrationCredential get credential; String get origin; String get platform;
/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FinishRegistrationParamsCopyWith<FinishRegistrationParams> get copyWith => _$FinishRegistrationParamsCopyWithImpl<FinishRegistrationParams>(this as FinishRegistrationParams, _$identity);

  /// Serializes this FinishRegistrationParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FinishRegistrationParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.origin, origin) || other.origin == origin)&&(identical(other.platform, platform) || other.platform == platform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,credential,origin,platform);

@override
String toString() {
  return 'FinishRegistrationParams(userId: $userId, credential: $credential, origin: $origin, platform: $platform)';
}


}

/// @nodoc
abstract mixin class $FinishRegistrationParamsCopyWith<$Res>  {
  factory $FinishRegistrationParamsCopyWith(FinishRegistrationParams value, $Res Function(FinishRegistrationParams) _then) = _$FinishRegistrationParamsCopyWithImpl;
@useResult
$Res call({
 String userId, WebAuthnRegistrationCredential credential, String origin, String platform
});


$WebAuthnRegistrationCredentialCopyWith<$Res> get credential;

}
/// @nodoc
class _$FinishRegistrationParamsCopyWithImpl<$Res>
    implements $FinishRegistrationParamsCopyWith<$Res> {
  _$FinishRegistrationParamsCopyWithImpl(this._self, this._then);

  final FinishRegistrationParams _self;
  final $Res Function(FinishRegistrationParams) _then;

/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,Object? credential = null,Object? origin = null,Object? platform = null,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,credential: null == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnRegistrationCredential,origin: null == origin ? _self.origin : origin // ignore: cast_nullable_to_non_nullable
as String,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,
  ));
}
/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnRegistrationCredentialCopyWith<$Res> get credential {
  
  return $WebAuthnRegistrationCredentialCopyWith<$Res>(_self.credential, (value) {
    return _then(_self.copyWith(credential: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _FinishRegistrationParams implements FinishRegistrationParams {
  const _FinishRegistrationParams({required this.userId, required this.credential, required this.origin, this.platform = 'web'});
  factory _FinishRegistrationParams.fromJson(Map<String, dynamic> json) => _$FinishRegistrationParamsFromJson(json);

@override final  String userId;
@override final  WebAuthnRegistrationCredential credential;
@override final  String origin;
@override@JsonKey() final  String platform;

/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FinishRegistrationParamsCopyWith<_FinishRegistrationParams> get copyWith => __$FinishRegistrationParamsCopyWithImpl<_FinishRegistrationParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FinishRegistrationParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FinishRegistrationParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.origin, origin) || other.origin == origin)&&(identical(other.platform, platform) || other.platform == platform));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,credential,origin,platform);

@override
String toString() {
  return 'FinishRegistrationParams(userId: $userId, credential: $credential, origin: $origin, platform: $platform)';
}


}

/// @nodoc
abstract mixin class _$FinishRegistrationParamsCopyWith<$Res> implements $FinishRegistrationParamsCopyWith<$Res> {
  factory _$FinishRegistrationParamsCopyWith(_FinishRegistrationParams value, $Res Function(_FinishRegistrationParams) _then) = __$FinishRegistrationParamsCopyWithImpl;
@override @useResult
$Res call({
 String userId, WebAuthnRegistrationCredential credential, String origin, String platform
});


@override $WebAuthnRegistrationCredentialCopyWith<$Res> get credential;

}
/// @nodoc
class __$FinishRegistrationParamsCopyWithImpl<$Res>
    implements _$FinishRegistrationParamsCopyWith<$Res> {
  __$FinishRegistrationParamsCopyWithImpl(this._self, this._then);

  final _FinishRegistrationParams _self;
  final $Res Function(_FinishRegistrationParams) _then;

/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,Object? credential = null,Object? origin = null,Object? platform = null,}) {
  return _then(_FinishRegistrationParams(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,credential: null == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnRegistrationCredential,origin: null == origin ? _self.origin : origin // ignore: cast_nullable_to_non_nullable
as String,platform: null == platform ? _self.platform : platform // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

/// Create a copy of FinishRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnRegistrationCredentialCopyWith<$Res> get credential {
  
  return $WebAuthnRegistrationCredentialCopyWith<$Res>(_self.credential, (value) {
    return _then(_self.copyWith(credential: value));
  });
}
}


/// @nodoc
mixin _$FinishRegistrationResult {

 bool get success; WebAuthnCredentialPublic? get credential; WebAuthnException? get error;
/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FinishRegistrationResultCopyWith<FinishRegistrationResult> get copyWith => _$FinishRegistrationResultCopyWithImpl<FinishRegistrationResult>(this as FinishRegistrationResult, _$identity);

  /// Serializes this FinishRegistrationResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FinishRegistrationResult&&(identical(other.success, success) || other.success == success)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,credential,error);

@override
String toString() {
  return 'FinishRegistrationResult(success: $success, credential: $credential, error: $error)';
}


}

/// @nodoc
abstract mixin class $FinishRegistrationResultCopyWith<$Res>  {
  factory $FinishRegistrationResultCopyWith(FinishRegistrationResult value, $Res Function(FinishRegistrationResult) _then) = _$FinishRegistrationResultCopyWithImpl;
@useResult
$Res call({
 bool success, WebAuthnCredentialPublic? credential, WebAuthnException? error
});


$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$FinishRegistrationResultCopyWithImpl<$Res>
    implements $FinishRegistrationResultCopyWith<$Res> {
  _$FinishRegistrationResultCopyWithImpl(this._self, this._then);

  final FinishRegistrationResult _self;
  final $Res Function(FinishRegistrationResult) _then;

/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? success = null,Object? credential = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,credential: freezed == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnCredentialPublic?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _FinishRegistrationResult extends FinishRegistrationResult {
  const _FinishRegistrationResult({required this.success, this.credential, this.error}): super._();
  factory _FinishRegistrationResult.fromJson(Map<String, dynamic> json) => _$FinishRegistrationResultFromJson(json);

@override final  bool success;
@override final  WebAuthnCredentialPublic? credential;
@override final  WebAuthnException? error;

/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FinishRegistrationResultCopyWith<_FinishRegistrationResult> get copyWith => __$FinishRegistrationResultCopyWithImpl<_FinishRegistrationResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FinishRegistrationResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _FinishRegistrationResult&&(identical(other.success, success) || other.success == success)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,credential,error);

@override
String toString() {
  return 'FinishRegistrationResult(success: $success, credential: $credential, error: $error)';
}


}

/// @nodoc
abstract mixin class _$FinishRegistrationResultCopyWith<$Res> implements $FinishRegistrationResultCopyWith<$Res> {
  factory _$FinishRegistrationResultCopyWith(_FinishRegistrationResult value, $Res Function(_FinishRegistrationResult) _then) = __$FinishRegistrationResultCopyWithImpl;
@override @useResult
$Res call({
 bool success, WebAuthnCredentialPublic? credential, WebAuthnException? error
});


@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$FinishRegistrationResultCopyWithImpl<$Res>
    implements _$FinishRegistrationResultCopyWith<$Res> {
  __$FinishRegistrationResultCopyWithImpl(this._self, this._then);

  final _FinishRegistrationResult _self;
  final $Res Function(_FinishRegistrationResult) _then;

/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? success = null,Object? credential = freezed,Object? error = freezed,}) {
  return _then(_FinishRegistrationResult(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,credential: freezed == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnCredentialPublic?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of FinishRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
mixin _$RevokeSessionParams {

 String get sessionId; String? get reason;
/// Create a copy of RevokeSessionParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RevokeSessionParamsCopyWith<RevokeSessionParams> get copyWith => _$RevokeSessionParamsCopyWithImpl<RevokeSessionParams>(this as RevokeSessionParams, _$identity);

  /// Serializes this RevokeSessionParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RevokeSessionParams&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sessionId,reason);

@override
String toString() {
  return 'RevokeSessionParams(sessionId: $sessionId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $RevokeSessionParamsCopyWith<$Res>  {
  factory $RevokeSessionParamsCopyWith(RevokeSessionParams value, $Res Function(RevokeSessionParams) _then) = _$RevokeSessionParamsCopyWithImpl;
@useResult
$Res call({
 String sessionId, String? reason
});




}
/// @nodoc
class _$RevokeSessionParamsCopyWithImpl<$Res>
    implements $RevokeSessionParamsCopyWith<$Res> {
  _$RevokeSessionParamsCopyWithImpl(this._self, this._then);

  final RevokeSessionParams _self;
  final $Res Function(RevokeSessionParams) _then;

/// Create a copy of RevokeSessionParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sessionId = null,Object? reason = freezed,}) {
  return _then(_self.copyWith(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// @nodoc
@JsonSerializable()

class _RevokeSessionParams implements RevokeSessionParams {
  const _RevokeSessionParams({required this.sessionId, this.reason});
  factory _RevokeSessionParams.fromJson(Map<String, dynamic> json) => _$RevokeSessionParamsFromJson(json);

@override final  String sessionId;
@override final  String? reason;

/// Create a copy of RevokeSessionParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RevokeSessionParamsCopyWith<_RevokeSessionParams> get copyWith => __$RevokeSessionParamsCopyWithImpl<_RevokeSessionParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RevokeSessionParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RevokeSessionParams&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,sessionId,reason);

@override
String toString() {
  return 'RevokeSessionParams(sessionId: $sessionId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class _$RevokeSessionParamsCopyWith<$Res> implements $RevokeSessionParamsCopyWith<$Res> {
  factory _$RevokeSessionParamsCopyWith(_RevokeSessionParams value, $Res Function(_RevokeSessionParams) _then) = __$RevokeSessionParamsCopyWithImpl;
@override @useResult
$Res call({
 String sessionId, String? reason
});




}
/// @nodoc
class __$RevokeSessionParamsCopyWithImpl<$Res>
    implements _$RevokeSessionParamsCopyWith<$Res> {
  __$RevokeSessionParamsCopyWithImpl(this._self, this._then);

  final _RevokeSessionParams _self;
  final $Res Function(_RevokeSessionParams) _then;

/// Create a copy of RevokeSessionParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? reason = freezed,}) {
  return _then(_RevokeSessionParams(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$RevokeAllSessionsParams {

 String get userId; String? get reason;
/// Create a copy of RevokeAllSessionsParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RevokeAllSessionsParamsCopyWith<RevokeAllSessionsParams> get copyWith => _$RevokeAllSessionsParamsCopyWithImpl<RevokeAllSessionsParams>(this as RevokeAllSessionsParams, _$identity);

  /// Serializes this RevokeAllSessionsParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RevokeAllSessionsParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,reason);

@override
String toString() {
  return 'RevokeAllSessionsParams(userId: $userId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $RevokeAllSessionsParamsCopyWith<$Res>  {
  factory $RevokeAllSessionsParamsCopyWith(RevokeAllSessionsParams value, $Res Function(RevokeAllSessionsParams) _then) = _$RevokeAllSessionsParamsCopyWithImpl;
@useResult
$Res call({
 String userId, String? reason
});




}
/// @nodoc
class _$RevokeAllSessionsParamsCopyWithImpl<$Res>
    implements $RevokeAllSessionsParamsCopyWith<$Res> {
  _$RevokeAllSessionsParamsCopyWithImpl(this._self, this._then);

  final RevokeAllSessionsParams _self;
  final $Res Function(RevokeAllSessionsParams) _then;

/// Create a copy of RevokeAllSessionsParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,Object? reason = freezed,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// @nodoc
@JsonSerializable()

class _RevokeAllSessionsParams implements RevokeAllSessionsParams {
  const _RevokeAllSessionsParams({required this.userId, this.reason});
  factory _RevokeAllSessionsParams.fromJson(Map<String, dynamic> json) => _$RevokeAllSessionsParamsFromJson(json);

@override final  String userId;
@override final  String? reason;

/// Create a copy of RevokeAllSessionsParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RevokeAllSessionsParamsCopyWith<_RevokeAllSessionsParams> get copyWith => __$RevokeAllSessionsParamsCopyWithImpl<_RevokeAllSessionsParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RevokeAllSessionsParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RevokeAllSessionsParams&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,reason);

@override
String toString() {
  return 'RevokeAllSessionsParams(userId: $userId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class _$RevokeAllSessionsParamsCopyWith<$Res> implements $RevokeAllSessionsParamsCopyWith<$Res> {
  factory _$RevokeAllSessionsParamsCopyWith(_RevokeAllSessionsParams value, $Res Function(_RevokeAllSessionsParams) _then) = __$RevokeAllSessionsParamsCopyWithImpl;
@override @useResult
$Res call({
 String userId, String? reason
});




}
/// @nodoc
class __$RevokeAllSessionsParamsCopyWithImpl<$Res>
    implements _$RevokeAllSessionsParamsCopyWith<$Res> {
  __$RevokeAllSessionsParamsCopyWithImpl(this._self, this._then);

  final _RevokeAllSessionsParams _self;
  final $Res Function(_RevokeAllSessionsParams) _then;

/// Create a copy of RevokeAllSessionsParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,Object? reason = freezed,}) {
  return _then(_RevokeAllSessionsParams(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$RevokeSessionResult {

 bool get success; int get revokedCount; String? get message; WebAuthnException? get error;
/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RevokeSessionResultCopyWith<RevokeSessionResult> get copyWith => _$RevokeSessionResultCopyWithImpl<RevokeSessionResult>(this as RevokeSessionResult, _$identity);

  /// Serializes this RevokeSessionResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RevokeSessionResult&&(identical(other.success, success) || other.success == success)&&(identical(other.revokedCount, revokedCount) || other.revokedCount == revokedCount)&&(identical(other.message, message) || other.message == message)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,revokedCount,message,error);

@override
String toString() {
  return 'RevokeSessionResult(success: $success, revokedCount: $revokedCount, message: $message, error: $error)';
}


}

/// @nodoc
abstract mixin class $RevokeSessionResultCopyWith<$Res>  {
  factory $RevokeSessionResultCopyWith(RevokeSessionResult value, $Res Function(RevokeSessionResult) _then) = _$RevokeSessionResultCopyWithImpl;
@useResult
$Res call({
 bool success, int revokedCount, String? message, WebAuthnException? error
});


$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$RevokeSessionResultCopyWithImpl<$Res>
    implements $RevokeSessionResultCopyWith<$Res> {
  _$RevokeSessionResultCopyWithImpl(this._self, this._then);

  final RevokeSessionResult _self;
  final $Res Function(RevokeSessionResult) _then;

/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? success = null,Object? revokedCount = null,Object? message = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,revokedCount: null == revokedCount ? _self.revokedCount : revokedCount // ignore: cast_nullable_to_non_nullable
as int,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _RevokeSessionResult implements RevokeSessionResult {
   _RevokeSessionResult({required this.success, required this.revokedCount, this.message, this.error});
  factory _RevokeSessionResult.fromJson(Map<String, dynamic> json) => _$RevokeSessionResultFromJson(json);

@override final  bool success;
@override final  int revokedCount;
@override final  String? message;
@override final  WebAuthnException? error;

/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$RevokeSessionResultCopyWith<_RevokeSessionResult> get copyWith => __$RevokeSessionResultCopyWithImpl<_RevokeSessionResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RevokeSessionResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _RevokeSessionResult&&(identical(other.success, success) || other.success == success)&&(identical(other.revokedCount, revokedCount) || other.revokedCount == revokedCount)&&(identical(other.message, message) || other.message == message)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,success,revokedCount,message,error);

@override
String toString() {
  return 'RevokeSessionResult._(success: $success, revokedCount: $revokedCount, message: $message, error: $error)';
}


}

/// @nodoc
abstract mixin class _$RevokeSessionResultCopyWith<$Res> implements $RevokeSessionResultCopyWith<$Res> {
  factory _$RevokeSessionResultCopyWith(_RevokeSessionResult value, $Res Function(_RevokeSessionResult) _then) = __$RevokeSessionResultCopyWithImpl;
@override @useResult
$Res call({
 bool success, int revokedCount, String? message, WebAuthnException? error
});


@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$RevokeSessionResultCopyWithImpl<$Res>
    implements _$RevokeSessionResultCopyWith<$Res> {
  __$RevokeSessionResultCopyWithImpl(this._self, this._then);

  final _RevokeSessionResult _self;
  final $Res Function(_RevokeSessionResult) _then;

/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? success = null,Object? revokedCount = null,Object? message = freezed,Object? error = freezed,}) {
  return _then(_RevokeSessionResult(
success: null == success ? _self.success : success // ignore: cast_nullable_to_non_nullable
as bool,revokedCount: null == revokedCount ? _self.revokedCount : revokedCount // ignore: cast_nullable_to_non_nullable
as int,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of RevokeSessionResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
mixin _$StartAuthenticationParams {

 String get userId;
/// Create a copy of StartAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StartAuthenticationParamsCopyWith<StartAuthenticationParams> get copyWith => _$StartAuthenticationParamsCopyWithImpl<StartAuthenticationParams>(this as StartAuthenticationParams, _$identity);

  /// Serializes this StartAuthenticationParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StartAuthenticationParams&&(identical(other.userId, userId) || other.userId == userId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId);

@override
String toString() {
  return 'StartAuthenticationParams(userId: $userId)';
}


}

/// @nodoc
abstract mixin class $StartAuthenticationParamsCopyWith<$Res>  {
  factory $StartAuthenticationParamsCopyWith(StartAuthenticationParams value, $Res Function(StartAuthenticationParams) _then) = _$StartAuthenticationParamsCopyWithImpl;
@useResult
$Res call({
 String userId
});




}
/// @nodoc
class _$StartAuthenticationParamsCopyWithImpl<$Res>
    implements $StartAuthenticationParamsCopyWith<$Res> {
  _$StartAuthenticationParamsCopyWithImpl(this._self, this._then);

  final StartAuthenticationParams _self;
  final $Res Function(StartAuthenticationParams) _then;

/// Create a copy of StartAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// @nodoc
@JsonSerializable()

class _StartAuthenticationParams implements StartAuthenticationParams {
  const _StartAuthenticationParams({required this.userId});
  factory _StartAuthenticationParams.fromJson(Map<String, dynamic> json) => _$StartAuthenticationParamsFromJson(json);

@override final  String userId;

/// Create a copy of StartAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StartAuthenticationParamsCopyWith<_StartAuthenticationParams> get copyWith => __$StartAuthenticationParamsCopyWithImpl<_StartAuthenticationParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StartAuthenticationParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StartAuthenticationParams&&(identical(other.userId, userId) || other.userId == userId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId);

@override
String toString() {
  return 'StartAuthenticationParams(userId: $userId)';
}


}

/// @nodoc
abstract mixin class _$StartAuthenticationParamsCopyWith<$Res> implements $StartAuthenticationParamsCopyWith<$Res> {
  factory _$StartAuthenticationParamsCopyWith(_StartAuthenticationParams value, $Res Function(_StartAuthenticationParams) _then) = __$StartAuthenticationParamsCopyWithImpl;
@override @useResult
$Res call({
 String userId
});




}
/// @nodoc
class __$StartAuthenticationParamsCopyWithImpl<$Res>
    implements _$StartAuthenticationParamsCopyWith<$Res> {
  __$StartAuthenticationParamsCopyWithImpl(this._self, this._then);

  final _StartAuthenticationParams _self;
  final $Res Function(_StartAuthenticationParams) _then;

/// Create a copy of StartAuthenticationParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,}) {
  return _then(_StartAuthenticationParams(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$StartAuthenticationResult {

 AuthenticationOptions? get options; WebAuthnException? get error;
/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StartAuthenticationResultCopyWith<StartAuthenticationResult> get copyWith => _$StartAuthenticationResultCopyWithImpl<StartAuthenticationResult>(this as StartAuthenticationResult, _$identity);

  /// Serializes this StartAuthenticationResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StartAuthenticationResult&&(identical(other.options, options) || other.options == options)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,options,error);

@override
String toString() {
  return 'StartAuthenticationResult(options: $options, error: $error)';
}


}

/// @nodoc
abstract mixin class $StartAuthenticationResultCopyWith<$Res>  {
  factory $StartAuthenticationResultCopyWith(StartAuthenticationResult value, $Res Function(StartAuthenticationResult) _then) = _$StartAuthenticationResultCopyWithImpl;
@useResult
$Res call({
 AuthenticationOptions? options, WebAuthnException? error
});


$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$StartAuthenticationResultCopyWithImpl<$Res>
    implements $StartAuthenticationResultCopyWith<$Res> {
  _$StartAuthenticationResultCopyWithImpl(this._self, this._then);

  final StartAuthenticationResult _self;
  final $Res Function(StartAuthenticationResult) _then;

/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? options = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
options: freezed == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as AuthenticationOptions?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _StartAuthenticationResult extends StartAuthenticationResult {
  const _StartAuthenticationResult({this.options, this.error}): super._();
  factory _StartAuthenticationResult.fromJson(Map<String, dynamic> json) => _$StartAuthenticationResultFromJson(json);

@override final  AuthenticationOptions? options;
@override final  WebAuthnException? error;

/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StartAuthenticationResultCopyWith<_StartAuthenticationResult> get copyWith => __$StartAuthenticationResultCopyWithImpl<_StartAuthenticationResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StartAuthenticationResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StartAuthenticationResult&&(identical(other.options, options) || other.options == options)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,options,error);

@override
String toString() {
  return 'StartAuthenticationResult(options: $options, error: $error)';
}


}

/// @nodoc
abstract mixin class _$StartAuthenticationResultCopyWith<$Res> implements $StartAuthenticationResultCopyWith<$Res> {
  factory _$StartAuthenticationResultCopyWith(_StartAuthenticationResult value, $Res Function(_StartAuthenticationResult) _then) = __$StartAuthenticationResultCopyWithImpl;
@override @useResult
$Res call({
 AuthenticationOptions? options, WebAuthnException? error
});


@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$StartAuthenticationResultCopyWithImpl<$Res>
    implements _$StartAuthenticationResultCopyWith<$Res> {
  __$StartAuthenticationResultCopyWithImpl(this._self, this._then);

  final _StartAuthenticationResult _self;
  final $Res Function(_StartAuthenticationResult) _then;

/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? options = freezed,Object? error = freezed,}) {
  return _then(_StartAuthenticationResult(
options: freezed == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as AuthenticationOptions?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of StartAuthenticationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
mixin _$StartRegistrationParams {

 String get userId; List<int>? get userHandle; String? get username; String? get displayName;
/// Create a copy of StartRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StartRegistrationParamsCopyWith<StartRegistrationParams> get copyWith => _$StartRegistrationParamsCopyWithImpl<StartRegistrationParams>(this as StartRegistrationParams, _$identity);

  /// Serializes this StartRegistrationParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StartRegistrationParams&&(identical(other.userId, userId) || other.userId == userId)&&const DeepCollectionEquality().equals(other.userHandle, userHandle)&&(identical(other.username, username) || other.username == username)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,const DeepCollectionEquality().hash(userHandle),username,displayName);

@override
String toString() {
  return 'StartRegistrationParams(userId: $userId, userHandle: $userHandle, username: $username, displayName: $displayName)';
}


}

/// @nodoc
abstract mixin class $StartRegistrationParamsCopyWith<$Res>  {
  factory $StartRegistrationParamsCopyWith(StartRegistrationParams value, $Res Function(StartRegistrationParams) _then) = _$StartRegistrationParamsCopyWithImpl;
@useResult
$Res call({
 String userId, List<int>? userHandle, String? username, String? displayName
});




}
/// @nodoc
class _$StartRegistrationParamsCopyWithImpl<$Res>
    implements $StartRegistrationParamsCopyWith<$Res> {
  _$StartRegistrationParamsCopyWithImpl(this._self, this._then);

  final StartRegistrationParams _self;
  final $Res Function(StartRegistrationParams) _then;

/// Create a copy of StartRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userId = null,Object? userHandle = freezed,Object? username = freezed,Object? displayName = freezed,}) {
  return _then(_self.copyWith(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,userHandle: freezed == userHandle ? _self.userHandle : userHandle // ignore: cast_nullable_to_non_nullable
as List<int>?,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,displayName: freezed == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// @nodoc
@JsonSerializable()

class _StartRegistrationParams implements StartRegistrationParams {
  const _StartRegistrationParams({required this.userId, final  List<int>? userHandle, this.username, this.displayName}): _userHandle = userHandle;
  factory _StartRegistrationParams.fromJson(Map<String, dynamic> json) => _$StartRegistrationParamsFromJson(json);

@override final  String userId;
 final  List<int>? _userHandle;
@override List<int>? get userHandle {
  final value = _userHandle;
  if (value == null) return null;
  if (_userHandle is EqualUnmodifiableListView) return _userHandle;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(value);
}

@override final  String? username;
@override final  String? displayName;

/// Create a copy of StartRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StartRegistrationParamsCopyWith<_StartRegistrationParams> get copyWith => __$StartRegistrationParamsCopyWithImpl<_StartRegistrationParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StartRegistrationParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StartRegistrationParams&&(identical(other.userId, userId) || other.userId == userId)&&const DeepCollectionEquality().equals(other._userHandle, _userHandle)&&(identical(other.username, username) || other.username == username)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,userId,const DeepCollectionEquality().hash(_userHandle),username,displayName);

@override
String toString() {
  return 'StartRegistrationParams(userId: $userId, userHandle: $userHandle, username: $username, displayName: $displayName)';
}


}

/// @nodoc
abstract mixin class _$StartRegistrationParamsCopyWith<$Res> implements $StartRegistrationParamsCopyWith<$Res> {
  factory _$StartRegistrationParamsCopyWith(_StartRegistrationParams value, $Res Function(_StartRegistrationParams) _then) = __$StartRegistrationParamsCopyWithImpl;
@override @useResult
$Res call({
 String userId, List<int>? userHandle, String? username, String? displayName
});




}
/// @nodoc
class __$StartRegistrationParamsCopyWithImpl<$Res>
    implements _$StartRegistrationParamsCopyWith<$Res> {
  __$StartRegistrationParamsCopyWithImpl(this._self, this._then);

  final _StartRegistrationParams _self;
  final $Res Function(_StartRegistrationParams) _then;

/// Create a copy of StartRegistrationParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userId = null,Object? userHandle = freezed,Object? username = freezed,Object? displayName = freezed,}) {
  return _then(_StartRegistrationParams(
userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,userHandle: freezed == userHandle ? _self._userHandle : userHandle // ignore: cast_nullable_to_non_nullable
as List<int>?,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,displayName: freezed == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$StartRegistrationResult {

 RegistrationOptions? get options; WebAuthnException? get error;
/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StartRegistrationResultCopyWith<StartRegistrationResult> get copyWith => _$StartRegistrationResultCopyWithImpl<StartRegistrationResult>(this as StartRegistrationResult, _$identity);

  /// Serializes this StartRegistrationResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StartRegistrationResult&&(identical(other.options, options) || other.options == options)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,options,error);

@override
String toString() {
  return 'StartRegistrationResult(options: $options, error: $error)';
}


}

/// @nodoc
abstract mixin class $StartRegistrationResultCopyWith<$Res>  {
  factory $StartRegistrationResultCopyWith(StartRegistrationResult value, $Res Function(StartRegistrationResult) _then) = _$StartRegistrationResultCopyWithImpl;
@useResult
$Res call({
 RegistrationOptions? options, WebAuthnException? error
});


$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$StartRegistrationResultCopyWithImpl<$Res>
    implements $StartRegistrationResultCopyWith<$Res> {
  _$StartRegistrationResultCopyWithImpl(this._self, this._then);

  final StartRegistrationResult _self;
  final $Res Function(StartRegistrationResult) _then;

/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? options = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
options: freezed == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as RegistrationOptions?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _StartRegistrationResult extends StartRegistrationResult {
  const _StartRegistrationResult({this.options, this.error}): super._();
  factory _StartRegistrationResult.fromJson(Map<String, dynamic> json) => _$StartRegistrationResultFromJson(json);

@override final  RegistrationOptions? options;
@override final  WebAuthnException? error;

/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$StartRegistrationResultCopyWith<_StartRegistrationResult> get copyWith => __$StartRegistrationResultCopyWithImpl<_StartRegistrationResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$StartRegistrationResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _StartRegistrationResult&&(identical(other.options, options) || other.options == options)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,options,error);

@override
String toString() {
  return 'StartRegistrationResult(options: $options, error: $error)';
}


}

/// @nodoc
abstract mixin class _$StartRegistrationResultCopyWith<$Res> implements $StartRegistrationResultCopyWith<$Res> {
  factory _$StartRegistrationResultCopyWith(_StartRegistrationResult value, $Res Function(_StartRegistrationResult) _then) = __$StartRegistrationResultCopyWithImpl;
@override @useResult
$Res call({
 RegistrationOptions? options, WebAuthnException? error
});


@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$StartRegistrationResultCopyWithImpl<$Res>
    implements _$StartRegistrationResultCopyWith<$Res> {
  __$StartRegistrationResultCopyWithImpl(this._self, this._then);

  final _StartRegistrationResult _self;
  final $Res Function(_StartRegistrationResult) _then;

/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? options = freezed,Object? error = freezed,}) {
  return _then(_StartRegistrationResult(
options: freezed == options ? _self.options : options // ignore: cast_nullable_to_non_nullable
as RegistrationOptions?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of StartRegistrationResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
mixin _$ValidateTokenParams {

 String get token; WebAuthnAuthContext? get context;
/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ValidateTokenParamsCopyWith<ValidateTokenParams> get copyWith => _$ValidateTokenParamsCopyWithImpl<ValidateTokenParams>(this as ValidateTokenParams, _$identity);

  /// Serializes this ValidateTokenParams to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ValidateTokenParams&&(identical(other.token, token) || other.token == token)&&(identical(other.context, context) || other.context == context));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,token,context);

@override
String toString() {
  return 'ValidateTokenParams(token: $token, context: $context)';
}


}

/// @nodoc
abstract mixin class $ValidateTokenParamsCopyWith<$Res>  {
  factory $ValidateTokenParamsCopyWith(ValidateTokenParams value, $Res Function(ValidateTokenParams) _then) = _$ValidateTokenParamsCopyWithImpl;
@useResult
$Res call({
 String token, WebAuthnAuthContext? context
});


$WebAuthnAuthContextCopyWith<$Res>? get context;

}
/// @nodoc
class _$ValidateTokenParamsCopyWithImpl<$Res>
    implements $ValidateTokenParamsCopyWith<$Res> {
  _$ValidateTokenParamsCopyWithImpl(this._self, this._then);

  final ValidateTokenParams _self;
  final $Res Function(ValidateTokenParams) _then;

/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? token = null,Object? context = freezed,}) {
  return _then(_self.copyWith(
token: null == token ? _self.token : token // ignore: cast_nullable_to_non_nullable
as String,context: freezed == context ? _self.context : context // ignore: cast_nullable_to_non_nullable
as WebAuthnAuthContext?,
  ));
}
/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAuthContextCopyWith<$Res>? get context {
    if (_self.context == null) {
    return null;
  }

  return $WebAuthnAuthContextCopyWith<$Res>(_self.context!, (value) {
    return _then(_self.copyWith(context: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _ValidateTokenParams implements ValidateTokenParams {
   _ValidateTokenParams({required this.token, this.context});
  factory _ValidateTokenParams.fromJson(Map<String, dynamic> json) => _$ValidateTokenParamsFromJson(json);

@override final  String token;
@override final  WebAuthnAuthContext? context;

/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ValidateTokenParamsCopyWith<_ValidateTokenParams> get copyWith => __$ValidateTokenParamsCopyWithImpl<_ValidateTokenParams>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ValidateTokenParamsToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ValidateTokenParams&&(identical(other.token, token) || other.token == token)&&(identical(other.context, context) || other.context == context));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,token,context);

@override
String toString() {
  return 'ValidateTokenParams(token: $token, context: $context)';
}


}

/// @nodoc
abstract mixin class _$ValidateTokenParamsCopyWith<$Res> implements $ValidateTokenParamsCopyWith<$Res> {
  factory _$ValidateTokenParamsCopyWith(_ValidateTokenParams value, $Res Function(_ValidateTokenParams) _then) = __$ValidateTokenParamsCopyWithImpl;
@override @useResult
$Res call({
 String token, WebAuthnAuthContext? context
});


@override $WebAuthnAuthContextCopyWith<$Res>? get context;

}
/// @nodoc
class __$ValidateTokenParamsCopyWithImpl<$Res>
    implements _$ValidateTokenParamsCopyWith<$Res> {
  __$ValidateTokenParamsCopyWithImpl(this._self, this._then);

  final _ValidateTokenParams _self;
  final $Res Function(_ValidateTokenParams) _then;

/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? token = null,Object? context = freezed,}) {
  return _then(_ValidateTokenParams(
token: null == token ? _self.token : token // ignore: cast_nullable_to_non_nullable
as String,context: freezed == context ? _self.context : context // ignore: cast_nullable_to_non_nullable
as WebAuthnAuthContext?,
  ));
}

/// Create a copy of ValidateTokenParams
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAuthContextCopyWith<$Res>? get context {
    if (_self.context == null) {
    return null;
  }

  return $WebAuthnAuthContextCopyWith<$Res>(_self.context!, (value) {
    return _then(_self.copyWith(context: value));
  });
}
}


/// @nodoc
mixin _$ValidateTokenResult {

 bool get isValid; WebAuthnCredentialPublic? get credential; WebAuthnAuthContext? get context; String? get errorMessage; WebAuthnException? get error;
/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ValidateTokenResultCopyWith<ValidateTokenResult> get copyWith => _$ValidateTokenResultCopyWithImpl<ValidateTokenResult>(this as ValidateTokenResult, _$identity);

  /// Serializes this ValidateTokenResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ValidateTokenResult&&(identical(other.isValid, isValid) || other.isValid == isValid)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.context, context) || other.context == context)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,isValid,credential,context,errorMessage,error);

@override
String toString() {
  return 'ValidateTokenResult(isValid: $isValid, credential: $credential, context: $context, errorMessage: $errorMessage, error: $error)';
}


}

/// @nodoc
abstract mixin class $ValidateTokenResultCopyWith<$Res>  {
  factory $ValidateTokenResultCopyWith(ValidateTokenResult value, $Res Function(ValidateTokenResult) _then) = _$ValidateTokenResultCopyWithImpl;
@useResult
$Res call({
 bool isValid, WebAuthnCredentialPublic? credential, WebAuthnAuthContext? context, String? errorMessage, WebAuthnException? error
});


$WebAuthnAuthContextCopyWith<$Res>? get context;$WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class _$ValidateTokenResultCopyWithImpl<$Res>
    implements $ValidateTokenResultCopyWith<$Res> {
  _$ValidateTokenResultCopyWithImpl(this._self, this._then);

  final ValidateTokenResult _self;
  final $Res Function(ValidateTokenResult) _then;

/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? isValid = null,Object? credential = freezed,Object? context = freezed,Object? errorMessage = freezed,Object? error = freezed,}) {
  return _then(_self.copyWith(
isValid: null == isValid ? _self.isValid : isValid // ignore: cast_nullable_to_non_nullable
as bool,credential: freezed == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnCredentialPublic?,context: freezed == context ? _self.context : context // ignore: cast_nullable_to_non_nullable
as WebAuthnAuthContext?,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}
/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAuthContextCopyWith<$Res>? get context {
    if (_self.context == null) {
    return null;
  }

  return $WebAuthnAuthContextCopyWith<$Res>(_self.context!, (value) {
    return _then(_self.copyWith(context: value));
  });
}/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}


/// @nodoc
@JsonSerializable()

class _ValidateTokenResult implements ValidateTokenResult {
   _ValidateTokenResult({required this.isValid, this.credential, this.context, this.errorMessage, this.error});
  factory _ValidateTokenResult.fromJson(Map<String, dynamic> json) => _$ValidateTokenResultFromJson(json);

@override final  bool isValid;
@override final  WebAuthnCredentialPublic? credential;
@override final  WebAuthnAuthContext? context;
@override final  String? errorMessage;
@override final  WebAuthnException? error;

/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ValidateTokenResultCopyWith<_ValidateTokenResult> get copyWith => __$ValidateTokenResultCopyWithImpl<_ValidateTokenResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ValidateTokenResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ValidateTokenResult&&(identical(other.isValid, isValid) || other.isValid == isValid)&&(identical(other.credential, credential) || other.credential == credential)&&(identical(other.context, context) || other.context == context)&&(identical(other.errorMessage, errorMessage) || other.errorMessage == errorMessage)&&(identical(other.error, error) || other.error == error));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,isValid,credential,context,errorMessage,error);

@override
String toString() {
  return 'ValidateTokenResult._(isValid: $isValid, credential: $credential, context: $context, errorMessage: $errorMessage, error: $error)';
}


}

/// @nodoc
abstract mixin class _$ValidateTokenResultCopyWith<$Res> implements $ValidateTokenResultCopyWith<$Res> {
  factory _$ValidateTokenResultCopyWith(_ValidateTokenResult value, $Res Function(_ValidateTokenResult) _then) = __$ValidateTokenResultCopyWithImpl;
@override @useResult
$Res call({
 bool isValid, WebAuthnCredentialPublic? credential, WebAuthnAuthContext? context, String? errorMessage, WebAuthnException? error
});


@override $WebAuthnAuthContextCopyWith<$Res>? get context;@override $WebAuthnExceptionCopyWith<$Res>? get error;

}
/// @nodoc
class __$ValidateTokenResultCopyWithImpl<$Res>
    implements _$ValidateTokenResultCopyWith<$Res> {
  __$ValidateTokenResultCopyWithImpl(this._self, this._then);

  final _ValidateTokenResult _self;
  final $Res Function(_ValidateTokenResult) _then;

/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? isValid = null,Object? credential = freezed,Object? context = freezed,Object? errorMessage = freezed,Object? error = freezed,}) {
  return _then(_ValidateTokenResult(
isValid: null == isValid ? _self.isValid : isValid // ignore: cast_nullable_to_non_nullable
as bool,credential: freezed == credential ? _self.credential : credential // ignore: cast_nullable_to_non_nullable
as WebAuthnCredentialPublic?,context: freezed == context ? _self.context : context // ignore: cast_nullable_to_non_nullable
as WebAuthnAuthContext?,errorMessage: freezed == errorMessage ? _self.errorMessage : errorMessage // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as WebAuthnException?,
  ));
}

/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnAuthContextCopyWith<$Res>? get context {
    if (_self.context == null) {
    return null;
  }

  return $WebAuthnAuthContextCopyWith<$Res>(_self.context!, (value) {
    return _then(_self.copyWith(context: value));
  });
}/// Create a copy of ValidateTokenResult
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<$Res>? get error {
    if (_self.error == null) {
    return null;
  }

  return $WebAuthnExceptionCopyWith<$Res>(_self.error!, (value) {
    return _then(_self.copyWith(error: value));
  });
}
}

// dart format on
