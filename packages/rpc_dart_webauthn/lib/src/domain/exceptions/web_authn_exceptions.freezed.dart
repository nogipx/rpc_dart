// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'web_authn_exceptions.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$WebAuthnException {

 WebAuthnExceptionType get type; String get message;@StackTraceConverter() StackTrace? get stackTrace;
/// Create a copy of WebAuthnException
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WebAuthnExceptionCopyWith<WebAuthnException> get copyWith => _$WebAuthnExceptionCopyWithImpl<WebAuthnException>(this as WebAuthnException, _$identity);

  /// Serializes this WebAuthnException to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebAuthnException&&(identical(other.type, type) || other.type == type)&&(identical(other.message, message) || other.message == message)&&(identical(other.stackTrace, stackTrace) || other.stackTrace == stackTrace));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,message,stackTrace);

@override
String toString() {
  return 'WebAuthnException(type: $type, message: $message, stackTrace: $stackTrace)';
}


}

/// @nodoc
abstract mixin class $WebAuthnExceptionCopyWith<$Res>  {
  factory $WebAuthnExceptionCopyWith(WebAuthnException value, $Res Function(WebAuthnException) _then) = _$WebAuthnExceptionCopyWithImpl;
@useResult
$Res call({
 WebAuthnExceptionType type, String message,@StackTraceConverter() StackTrace? stackTrace
});




}
/// @nodoc
class _$WebAuthnExceptionCopyWithImpl<$Res>
    implements $WebAuthnExceptionCopyWith<$Res> {
  _$WebAuthnExceptionCopyWithImpl(this._self, this._then);

  final WebAuthnException _self;
  final $Res Function(WebAuthnException) _then;

/// Create a copy of WebAuthnException
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? type = null,Object? message = null,Object? stackTrace = freezed,}) {
  return _then(_self.copyWith(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as WebAuthnExceptionType,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,stackTrace: freezed == stackTrace ? _self.stackTrace : stackTrace // ignore: cast_nullable_to_non_nullable
as StackTrace?,
  ));
}

}


/// @nodoc
@JsonSerializable()

class _WebAuthnException extends WebAuthnException {
  const _WebAuthnException({required this.type, required this.message, @StackTraceConverter() this.stackTrace}): super._();
  factory _WebAuthnException.fromJson(Map<String, dynamic> json) => _$WebAuthnExceptionFromJson(json);

@override final  WebAuthnExceptionType type;
@override final  String message;
@override@StackTraceConverter() final  StackTrace? stackTrace;

/// Create a copy of WebAuthnException
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$WebAuthnExceptionCopyWith<_WebAuthnException> get copyWith => __$WebAuthnExceptionCopyWithImpl<_WebAuthnException>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WebAuthnExceptionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _WebAuthnException&&(identical(other.type, type) || other.type == type)&&(identical(other.message, message) || other.message == message)&&(identical(other.stackTrace, stackTrace) || other.stackTrace == stackTrace));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,type,message,stackTrace);

@override
String toString() {
  return 'WebAuthnException(type: $type, message: $message, stackTrace: $stackTrace)';
}


}

/// @nodoc
abstract mixin class _$WebAuthnExceptionCopyWith<$Res> implements $WebAuthnExceptionCopyWith<$Res> {
  factory _$WebAuthnExceptionCopyWith(_WebAuthnException value, $Res Function(_WebAuthnException) _then) = __$WebAuthnExceptionCopyWithImpl;
@override @useResult
$Res call({
 WebAuthnExceptionType type, String message,@StackTraceConverter() StackTrace? stackTrace
});




}
/// @nodoc
class __$WebAuthnExceptionCopyWithImpl<$Res>
    implements _$WebAuthnExceptionCopyWith<$Res> {
  __$WebAuthnExceptionCopyWithImpl(this._self, this._then);

  final _WebAuthnException _self;
  final $Res Function(_WebAuthnException) _then;

/// Create a copy of WebAuthnException
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? type = null,Object? message = null,Object? stackTrace = freezed,}) {
  return _then(_WebAuthnException(
type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as WebAuthnExceptionType,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,stackTrace: freezed == stackTrace ? _self.stackTrace : stackTrace // ignore: cast_nullable_to_non_nullable
as StackTrace?,
  ));
}


}

// dart format on
