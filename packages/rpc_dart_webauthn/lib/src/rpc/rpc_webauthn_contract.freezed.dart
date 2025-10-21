// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'rpc_webauthn_contract.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$GetUserInfoParams {
  String get userId;

  /// Create a copy of GetUserInfoParams
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $GetUserInfoParamsCopyWith<GetUserInfoParams> get copyWith =>
      _$GetUserInfoParamsCopyWithImpl<GetUserInfoParams>(
          this as GetUserInfoParams, _$identity);

  /// Serializes this GetUserInfoParams to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is GetUserInfoParams &&
            (identical(other.userId, userId) || other.userId == userId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId);

  @override
  String toString() {
    return 'GetUserInfoParams(userId: $userId)';
  }
}

/// @nodoc
abstract mixin class $GetUserInfoParamsCopyWith<$Res> {
  factory $GetUserInfoParamsCopyWith(
          GetUserInfoParams value, $Res Function(GetUserInfoParams) _then) =
      _$GetUserInfoParamsCopyWithImpl;
  @useResult
  $Res call({String userId});
}

/// @nodoc
class _$GetUserInfoParamsCopyWithImpl<$Res>
    implements $GetUserInfoParamsCopyWith<$Res> {
  _$GetUserInfoParamsCopyWithImpl(this._self, this._then);

  final GetUserInfoParams _self;
  final $Res Function(GetUserInfoParams) _then;

  /// Create a copy of GetUserInfoParams
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? userId = null,
  }) {
    return _then(_self.copyWith(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _GetUserInfoParams implements GetUserInfoParams {
  const _GetUserInfoParams({required this.userId});
  factory _GetUserInfoParams.fromJson(Map<String, dynamic> json) =>
      _$GetUserInfoParamsFromJson(json);

  @override
  final String userId;

  /// Create a copy of GetUserInfoParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$GetUserInfoParamsCopyWith<_GetUserInfoParams> get copyWith =>
      __$GetUserInfoParamsCopyWithImpl<_GetUserInfoParams>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$GetUserInfoParamsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _GetUserInfoParams &&
            (identical(other.userId, userId) || other.userId == userId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId);

  @override
  String toString() {
    return 'GetUserInfoParams(userId: $userId)';
  }
}

/// @nodoc
abstract mixin class _$GetUserInfoParamsCopyWith<$Res>
    implements $GetUserInfoParamsCopyWith<$Res> {
  factory _$GetUserInfoParamsCopyWith(
          _GetUserInfoParams value, $Res Function(_GetUserInfoParams) _then) =
      __$GetUserInfoParamsCopyWithImpl;
  @override
  @useResult
  $Res call({String userId});
}

/// @nodoc
class __$GetUserInfoParamsCopyWithImpl<$Res>
    implements _$GetUserInfoParamsCopyWith<$Res> {
  __$GetUserInfoParamsCopyWithImpl(this._self, this._then);

  final _GetUserInfoParams _self;
  final $Res Function(_GetUserInfoParams) _then;

  /// Create a copy of GetUserInfoParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? userId = null,
  }) {
    return _then(_GetUserInfoParams(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
mixin _$GetUserInfoResult {
  bool get success;
  WebAuthnUserInfo? get userInfo;
  String? get errorMessage;

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $GetUserInfoResultCopyWith<GetUserInfoResult> get copyWith =>
      _$GetUserInfoResultCopyWithImpl<GetUserInfoResult>(
          this as GetUserInfoResult, _$identity);

  /// Serializes this GetUserInfoResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is GetUserInfoResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.userInfo, userInfo) ||
                other.userInfo == userInfo) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, userInfo, errorMessage);

  @override
  String toString() {
    return 'GetUserInfoResult(success: $success, userInfo: $userInfo, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class $GetUserInfoResultCopyWith<$Res> {
  factory $GetUserInfoResultCopyWith(
          GetUserInfoResult value, $Res Function(GetUserInfoResult) _then) =
      _$GetUserInfoResultCopyWithImpl;
  @useResult
  $Res call({bool success, WebAuthnUserInfo? userInfo, String? errorMessage});

  $WebAuthnUserInfoCopyWith<$Res>? get userInfo;
}

/// @nodoc
class _$GetUserInfoResultCopyWithImpl<$Res>
    implements $GetUserInfoResultCopyWith<$Res> {
  _$GetUserInfoResultCopyWithImpl(this._self, this._then);

  final GetUserInfoResult _self;
  final $Res Function(GetUserInfoResult) _then;

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? success = null,
    Object? userInfo = freezed,
    Object? errorMessage = freezed,
  }) {
    return _then(_self.copyWith(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      userInfo: freezed == userInfo
          ? _self.userInfo
          : userInfo // ignore: cast_nullable_to_non_nullable
              as WebAuthnUserInfo?,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnUserInfoCopyWith<$Res>? get userInfo {
    if (_self.userInfo == null) {
      return null;
    }

    return $WebAuthnUserInfoCopyWith<$Res>(_self.userInfo!, (value) {
      return _then(_self.copyWith(userInfo: value));
    });
  }
}

/// @nodoc
@JsonSerializable()
class _GetUserInfoResult implements GetUserInfoResult {
  const _GetUserInfoResult(
      {required this.success, this.userInfo, this.errorMessage});
  factory _GetUserInfoResult.fromJson(Map<String, dynamic> json) =>
      _$GetUserInfoResultFromJson(json);

  @override
  final bool success;
  @override
  final WebAuthnUserInfo? userInfo;
  @override
  final String? errorMessage;

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$GetUserInfoResultCopyWith<_GetUserInfoResult> get copyWith =>
      __$GetUserInfoResultCopyWithImpl<_GetUserInfoResult>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$GetUserInfoResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _GetUserInfoResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.userInfo, userInfo) ||
                other.userInfo == userInfo) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, userInfo, errorMessage);

  @override
  String toString() {
    return 'GetUserInfoResult(success: $success, userInfo: $userInfo, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class _$GetUserInfoResultCopyWith<$Res>
    implements $GetUserInfoResultCopyWith<$Res> {
  factory _$GetUserInfoResultCopyWith(
          _GetUserInfoResult value, $Res Function(_GetUserInfoResult) _then) =
      __$GetUserInfoResultCopyWithImpl;
  @override
  @useResult
  $Res call({bool success, WebAuthnUserInfo? userInfo, String? errorMessage});

  @override
  $WebAuthnUserInfoCopyWith<$Res>? get userInfo;
}

/// @nodoc
class __$GetUserInfoResultCopyWithImpl<$Res>
    implements _$GetUserInfoResultCopyWith<$Res> {
  __$GetUserInfoResultCopyWithImpl(this._self, this._then);

  final _GetUserInfoResult _self;
  final $Res Function(_GetUserInfoResult) _then;

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? success = null,
    Object? userInfo = freezed,
    Object? errorMessage = freezed,
  }) {
    return _then(_GetUserInfoResult(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      userInfo: freezed == userInfo
          ? _self.userInfo
          : userInfo // ignore: cast_nullable_to_non_nullable
              as WebAuthnUserInfo?,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }

  /// Create a copy of GetUserInfoResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnUserInfoCopyWith<$Res>? get userInfo {
    if (_self.userInfo == null) {
      return null;
    }

    return $WebAuthnUserInfoCopyWith<$Res>(_self.userInfo!, (value) {
      return _then(_self.copyWith(userInfo: value));
    });
  }
}

/// @nodoc
mixin _$RemoveCredentialParams {
  String get userId;
  String get credentialId;

  /// Create a copy of RemoveCredentialParams
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RemoveCredentialParamsCopyWith<RemoveCredentialParams> get copyWith =>
      _$RemoveCredentialParamsCopyWithImpl<RemoveCredentialParams>(
          this as RemoveCredentialParams, _$identity);

  /// Serializes this RemoveCredentialParams to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RemoveCredentialParams &&
            (identical(other.userId, userId) || other.userId == userId) &&
            (identical(other.credentialId, credentialId) ||
                other.credentialId == credentialId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId, credentialId);

  @override
  String toString() {
    return 'RemoveCredentialParams(userId: $userId, credentialId: $credentialId)';
  }
}

/// @nodoc
abstract mixin class $RemoveCredentialParamsCopyWith<$Res> {
  factory $RemoveCredentialParamsCopyWith(RemoveCredentialParams value,
          $Res Function(RemoveCredentialParams) _then) =
      _$RemoveCredentialParamsCopyWithImpl;
  @useResult
  $Res call({String userId, String credentialId});
}

/// @nodoc
class _$RemoveCredentialParamsCopyWithImpl<$Res>
    implements $RemoveCredentialParamsCopyWith<$Res> {
  _$RemoveCredentialParamsCopyWithImpl(this._self, this._then);

  final RemoveCredentialParams _self;
  final $Res Function(RemoveCredentialParams) _then;

  /// Create a copy of RemoveCredentialParams
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? userId = null,
    Object? credentialId = null,
  }) {
    return _then(_self.copyWith(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
      credentialId: null == credentialId
          ? _self.credentialId
          : credentialId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _RemoveCredentialParams implements RemoveCredentialParams {
  const _RemoveCredentialParams(
      {required this.userId, required this.credentialId});
  factory _RemoveCredentialParams.fromJson(Map<String, dynamic> json) =>
      _$RemoveCredentialParamsFromJson(json);

  @override
  final String userId;
  @override
  final String credentialId;

  /// Create a copy of RemoveCredentialParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$RemoveCredentialParamsCopyWith<_RemoveCredentialParams> get copyWith =>
      __$RemoveCredentialParamsCopyWithImpl<_RemoveCredentialParams>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$RemoveCredentialParamsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _RemoveCredentialParams &&
            (identical(other.userId, userId) || other.userId == userId) &&
            (identical(other.credentialId, credentialId) ||
                other.credentialId == credentialId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId, credentialId);

  @override
  String toString() {
    return 'RemoveCredentialParams(userId: $userId, credentialId: $credentialId)';
  }
}

/// @nodoc
abstract mixin class _$RemoveCredentialParamsCopyWith<$Res>
    implements $RemoveCredentialParamsCopyWith<$Res> {
  factory _$RemoveCredentialParamsCopyWith(_RemoveCredentialParams value,
          $Res Function(_RemoveCredentialParams) _then) =
      __$RemoveCredentialParamsCopyWithImpl;
  @override
  @useResult
  $Res call({String userId, String credentialId});
}

/// @nodoc
class __$RemoveCredentialParamsCopyWithImpl<$Res>
    implements _$RemoveCredentialParamsCopyWith<$Res> {
  __$RemoveCredentialParamsCopyWithImpl(this._self, this._then);

  final _RemoveCredentialParams _self;
  final $Res Function(_RemoveCredentialParams) _then;

  /// Create a copy of RemoveCredentialParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? userId = null,
    Object? credentialId = null,
  }) {
    return _then(_RemoveCredentialParams(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
      credentialId: null == credentialId
          ? _self.credentialId
          : credentialId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
mixin _$RemoveCredentialResult {
  bool get success;
  String? get message;
  String? get errorMessage;

  /// Create a copy of RemoveCredentialResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $RemoveCredentialResultCopyWith<RemoveCredentialResult> get copyWith =>
      _$RemoveCredentialResultCopyWithImpl<RemoveCredentialResult>(
          this as RemoveCredentialResult, _$identity);

  /// Serializes this RemoveCredentialResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is RemoveCredentialResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.message, message) || other.message == message) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, message, errorMessage);

  @override
  String toString() {
    return 'RemoveCredentialResult(success: $success, message: $message, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class $RemoveCredentialResultCopyWith<$Res> {
  factory $RemoveCredentialResultCopyWith(RemoveCredentialResult value,
          $Res Function(RemoveCredentialResult) _then) =
      _$RemoveCredentialResultCopyWithImpl;
  @useResult
  $Res call({bool success, String? message, String? errorMessage});
}

/// @nodoc
class _$RemoveCredentialResultCopyWithImpl<$Res>
    implements $RemoveCredentialResultCopyWith<$Res> {
  _$RemoveCredentialResultCopyWithImpl(this._self, this._then);

  final RemoveCredentialResult _self;
  final $Res Function(RemoveCredentialResult) _then;

  /// Create a copy of RemoveCredentialResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? success = null,
    Object? message = freezed,
    Object? errorMessage = freezed,
  }) {
    return _then(_self.copyWith(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      message: freezed == message
          ? _self.message
          : message // ignore: cast_nullable_to_non_nullable
              as String?,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _RemoveCredentialResult implements RemoveCredentialResult {
  const _RemoveCredentialResult(
      {required this.success, this.message, this.errorMessage});
  factory _RemoveCredentialResult.fromJson(Map<String, dynamic> json) =>
      _$RemoveCredentialResultFromJson(json);

  @override
  final bool success;
  @override
  final String? message;
  @override
  final String? errorMessage;

  /// Create a copy of RemoveCredentialResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$RemoveCredentialResultCopyWith<_RemoveCredentialResult> get copyWith =>
      __$RemoveCredentialResultCopyWithImpl<_RemoveCredentialResult>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$RemoveCredentialResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _RemoveCredentialResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.message, message) || other.message == message) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, message, errorMessage);

  @override
  String toString() {
    return 'RemoveCredentialResult(success: $success, message: $message, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class _$RemoveCredentialResultCopyWith<$Res>
    implements $RemoveCredentialResultCopyWith<$Res> {
  factory _$RemoveCredentialResultCopyWith(_RemoveCredentialResult value,
          $Res Function(_RemoveCredentialResult) _then) =
      __$RemoveCredentialResultCopyWithImpl;
  @override
  @useResult
  $Res call({bool success, String? message, String? errorMessage});
}

/// @nodoc
class __$RemoveCredentialResultCopyWithImpl<$Res>
    implements _$RemoveCredentialResultCopyWith<$Res> {
  __$RemoveCredentialResultCopyWithImpl(this._self, this._then);

  final _RemoveCredentialResult _self;
  final $Res Function(_RemoveCredentialResult) _then;

  /// Create a copy of RemoveCredentialResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? success = null,
    Object? message = freezed,
    Object? errorMessage = freezed,
  }) {
    return _then(_RemoveCredentialResult(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      message: freezed == message
          ? _self.message
          : message // ignore: cast_nullable_to_non_nullable
              as String?,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc
mixin _$GetCredentialsParams {
  String get userId;

  /// Create a copy of GetCredentialsParams
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $GetCredentialsParamsCopyWith<GetCredentialsParams> get copyWith =>
      _$GetCredentialsParamsCopyWithImpl<GetCredentialsParams>(
          this as GetCredentialsParams, _$identity);

  /// Serializes this GetCredentialsParams to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is GetCredentialsParams &&
            (identical(other.userId, userId) || other.userId == userId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId);

  @override
  String toString() {
    return 'GetCredentialsParams(userId: $userId)';
  }
}

/// @nodoc
abstract mixin class $GetCredentialsParamsCopyWith<$Res> {
  factory $GetCredentialsParamsCopyWith(GetCredentialsParams value,
          $Res Function(GetCredentialsParams) _then) =
      _$GetCredentialsParamsCopyWithImpl;
  @useResult
  $Res call({String userId});
}

/// @nodoc
class _$GetCredentialsParamsCopyWithImpl<$Res>
    implements $GetCredentialsParamsCopyWith<$Res> {
  _$GetCredentialsParamsCopyWithImpl(this._self, this._then);

  final GetCredentialsParams _self;
  final $Res Function(GetCredentialsParams) _then;

  /// Create a copy of GetCredentialsParams
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? userId = null,
  }) {
    return _then(_self.copyWith(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _GetCredentialsParams implements GetCredentialsParams {
  const _GetCredentialsParams({required this.userId});
  factory _GetCredentialsParams.fromJson(Map<String, dynamic> json) =>
      _$GetCredentialsParamsFromJson(json);

  @override
  final String userId;

  /// Create a copy of GetCredentialsParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$GetCredentialsParamsCopyWith<_GetCredentialsParams> get copyWith =>
      __$GetCredentialsParamsCopyWithImpl<_GetCredentialsParams>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$GetCredentialsParamsToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _GetCredentialsParams &&
            (identical(other.userId, userId) || other.userId == userId));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, userId);

  @override
  String toString() {
    return 'GetCredentialsParams(userId: $userId)';
  }
}

/// @nodoc
abstract mixin class _$GetCredentialsParamsCopyWith<$Res>
    implements $GetCredentialsParamsCopyWith<$Res> {
  factory _$GetCredentialsParamsCopyWith(_GetCredentialsParams value,
          $Res Function(_GetCredentialsParams) _then) =
      __$GetCredentialsParamsCopyWithImpl;
  @override
  @useResult
  $Res call({String userId});
}

/// @nodoc
class __$GetCredentialsParamsCopyWithImpl<$Res>
    implements _$GetCredentialsParamsCopyWith<$Res> {
  __$GetCredentialsParamsCopyWithImpl(this._self, this._then);

  final _GetCredentialsParams _self;
  final $Res Function(_GetCredentialsParams) _then;

  /// Create a copy of GetCredentialsParams
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? userId = null,
  }) {
    return _then(_GetCredentialsParams(
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc
mixin _$GetCredentialsResult {
  bool get success;
  List<WebAuthnCredentialPublic> get credentials;
  String? get errorMessage;

  /// Create a copy of GetCredentialsResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $GetCredentialsResultCopyWith<GetCredentialsResult> get copyWith =>
      _$GetCredentialsResultCopyWithImpl<GetCredentialsResult>(
          this as GetCredentialsResult, _$identity);

  /// Serializes this GetCredentialsResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is GetCredentialsResult &&
            (identical(other.success, success) || other.success == success) &&
            const DeepCollectionEquality()
                .equals(other.credentials, credentials) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success,
      const DeepCollectionEquality().hash(credentials), errorMessage);

  @override
  String toString() {
    return 'GetCredentialsResult(success: $success, credentials: $credentials, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class $GetCredentialsResultCopyWith<$Res> {
  factory $GetCredentialsResultCopyWith(GetCredentialsResult value,
          $Res Function(GetCredentialsResult) _then) =
      _$GetCredentialsResultCopyWithImpl;
  @useResult
  $Res call(
      {bool success,
      List<WebAuthnCredentialPublic> credentials,
      String? errorMessage});
}

/// @nodoc
class _$GetCredentialsResultCopyWithImpl<$Res>
    implements $GetCredentialsResultCopyWith<$Res> {
  _$GetCredentialsResultCopyWithImpl(this._self, this._then);

  final GetCredentialsResult _self;
  final $Res Function(GetCredentialsResult) _then;

  /// Create a copy of GetCredentialsResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? success = null,
    Object? credentials = null,
    Object? errorMessage = freezed,
  }) {
    return _then(_self.copyWith(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      credentials: null == credentials
          ? _self.credentials
          : credentials // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnCredentialPublic>,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _GetCredentialsResult implements GetCredentialsResult {
  const _GetCredentialsResult(
      {required this.success,
      final List<WebAuthnCredentialPublic> credentials = const [],
      this.errorMessage})
      : _credentials = credentials;
  factory _GetCredentialsResult.fromJson(Map<String, dynamic> json) =>
      _$GetCredentialsResultFromJson(json);

  @override
  final bool success;
  final List<WebAuthnCredentialPublic> _credentials;
  @override
  @JsonKey()
  List<WebAuthnCredentialPublic> get credentials {
    if (_credentials is EqualUnmodifiableListView) return _credentials;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_credentials);
  }

  @override
  final String? errorMessage;

  /// Create a copy of GetCredentialsResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$GetCredentialsResultCopyWith<_GetCredentialsResult> get copyWith =>
      __$GetCredentialsResultCopyWithImpl<_GetCredentialsResult>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$GetCredentialsResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _GetCredentialsResult &&
            (identical(other.success, success) || other.success == success) &&
            const DeepCollectionEquality()
                .equals(other._credentials, _credentials) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success,
      const DeepCollectionEquality().hash(_credentials), errorMessage);

  @override
  String toString() {
    return 'GetCredentialsResult(success: $success, credentials: $credentials, errorMessage: $errorMessage)';
  }
}

/// @nodoc
abstract mixin class _$GetCredentialsResultCopyWith<$Res>
    implements $GetCredentialsResultCopyWith<$Res> {
  factory _$GetCredentialsResultCopyWith(_GetCredentialsResult value,
          $Res Function(_GetCredentialsResult) _then) =
      __$GetCredentialsResultCopyWithImpl;
  @override
  @useResult
  $Res call(
      {bool success,
      List<WebAuthnCredentialPublic> credentials,
      String? errorMessage});
}

/// @nodoc
class __$GetCredentialsResultCopyWithImpl<$Res>
    implements _$GetCredentialsResultCopyWith<$Res> {
  __$GetCredentialsResultCopyWithImpl(this._self, this._then);

  final _GetCredentialsResult _self;
  final $Res Function(_GetCredentialsResult) _then;

  /// Create a copy of GetCredentialsResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? success = null,
    Object? credentials = null,
    Object? errorMessage = freezed,
  }) {
    return _then(_GetCredentialsResult(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      credentials: null == credentials
          ? _self._credentials
          : credentials // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnCredentialPublic>,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

// dart format on
