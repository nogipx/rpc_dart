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
mixin _$AuthResponse {
  /// Токен доступа (PASETO)
  String get accessToken;

  /// Время истечения в секундах от текущего момента
  int get expiresIn;

  /// Идентификатор пользователя
  String get userId;

  /// Тип токена (всегда paseto)
  String get tokenType;

  /// Дополнительная информация о пользователе (опционально)
  WebAuthnCredentialPublic? get credential;

  /// Create a copy of AuthResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $AuthResponseCopyWith<AuthResponse> get copyWith =>
      _$AuthResponseCopyWithImpl<AuthResponse>(
          this as AuthResponse, _$identity);

  /// Serializes this AuthResponse to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is AuthResponse &&
            (identical(other.accessToken, accessToken) ||
                other.accessToken == accessToken) &&
            (identical(other.expiresIn, expiresIn) ||
                other.expiresIn == expiresIn) &&
            (identical(other.userId, userId) || other.userId == userId) &&
            (identical(other.tokenType, tokenType) ||
                other.tokenType == tokenType) &&
            (identical(other.credential, credential) ||
                other.credential == credential));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, accessToken, expiresIn, userId, tokenType, credential);

  @override
  String toString() {
    return 'AuthResponse(accessToken: $accessToken, expiresIn: $expiresIn, userId: $userId, tokenType: $tokenType, credential: $credential)';
  }
}

/// @nodoc
abstract mixin class $AuthResponseCopyWith<$Res> {
  factory $AuthResponseCopyWith(
          AuthResponse value, $Res Function(AuthResponse) _then) =
      _$AuthResponseCopyWithImpl;
  @useResult
  $Res call(
      {String accessToken,
      int expiresIn,
      String userId,
      String tokenType,
      WebAuthnCredentialPublic? credential});
}

/// @nodoc
class _$AuthResponseCopyWithImpl<$Res> implements $AuthResponseCopyWith<$Res> {
  _$AuthResponseCopyWithImpl(this._self, this._then);

  final AuthResponse _self;
  final $Res Function(AuthResponse) _then;

  /// Create a copy of AuthResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? accessToken = null,
    Object? expiresIn = null,
    Object? userId = null,
    Object? tokenType = null,
    Object? credential = freezed,
  }) {
    return _then(_self.copyWith(
      accessToken: null == accessToken
          ? _self.accessToken
          : accessToken // ignore: cast_nullable_to_non_nullable
              as String,
      expiresIn: null == expiresIn
          ? _self.expiresIn
          : expiresIn // ignore: cast_nullable_to_non_nullable
              as int,
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
      tokenType: null == tokenType
          ? _self.tokenType
          : tokenType // ignore: cast_nullable_to_non_nullable
              as String,
      credential: freezed == credential
          ? _self.credential
          : credential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _AuthResponse implements AuthResponse {
  const _AuthResponse(
      {required this.accessToken,
      required this.expiresIn,
      required this.userId,
      this.tokenType = 'paseto',
      this.credential});
  factory _AuthResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthResponseFromJson(json);

  /// Токен доступа (PASETO)
  @override
  final String accessToken;

  /// Время истечения в секундах от текущего момента
  @override
  final int expiresIn;

  /// Идентификатор пользователя
  @override
  final String userId;

  /// Тип токена (всегда paseto)
  @override
  @JsonKey()
  final String tokenType;

  /// Дополнительная информация о пользователе (опционально)
  @override
  final WebAuthnCredentialPublic? credential;

  /// Create a copy of AuthResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$AuthResponseCopyWith<_AuthResponse> get copyWith =>
      __$AuthResponseCopyWithImpl<_AuthResponse>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$AuthResponseToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _AuthResponse &&
            (identical(other.accessToken, accessToken) ||
                other.accessToken == accessToken) &&
            (identical(other.expiresIn, expiresIn) ||
                other.expiresIn == expiresIn) &&
            (identical(other.userId, userId) || other.userId == userId) &&
            (identical(other.tokenType, tokenType) ||
                other.tokenType == tokenType) &&
            (identical(other.credential, credential) ||
                other.credential == credential));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType, accessToken, expiresIn, userId, tokenType, credential);

  @override
  String toString() {
    return 'AuthResponse(accessToken: $accessToken, expiresIn: $expiresIn, userId: $userId, tokenType: $tokenType, credential: $credential)';
  }
}

/// @nodoc
abstract mixin class _$AuthResponseCopyWith<$Res>
    implements $AuthResponseCopyWith<$Res> {
  factory _$AuthResponseCopyWith(
          _AuthResponse value, $Res Function(_AuthResponse) _then) =
      __$AuthResponseCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String accessToken,
      int expiresIn,
      String userId,
      String tokenType,
      WebAuthnCredentialPublic? credential});
}

/// @nodoc
class __$AuthResponseCopyWithImpl<$Res>
    implements _$AuthResponseCopyWith<$Res> {
  __$AuthResponseCopyWithImpl(this._self, this._then);

  final _AuthResponse _self;
  final $Res Function(_AuthResponse) _then;

  /// Create a copy of AuthResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? accessToken = null,
    Object? expiresIn = null,
    Object? userId = null,
    Object? tokenType = null,
    Object? credential = freezed,
  }) {
    return _then(_AuthResponse(
      accessToken: null == accessToken
          ? _self.accessToken
          : accessToken // ignore: cast_nullable_to_non_nullable
              as String,
      expiresIn: null == expiresIn
          ? _self.expiresIn
          : expiresIn // ignore: cast_nullable_to_non_nullable
              as int,
      userId: null == userId
          ? _self.userId
          : userId // ignore: cast_nullable_to_non_nullable
              as String,
      tokenType: null == tokenType
          ? _self.tokenType
          : tokenType // ignore: cast_nullable_to_non_nullable
              as String,
      credential: freezed == credential
          ? _self.credential
          : credential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
    ));
  }
}

/// @nodoc
mixin _$PasetoTokenPayload {
  /// Идентификатор пользователя
  String get sub;

  /// Время истечения срока действия токена (unix timestamp)
  int get exp;

  /// Время создания токена (unix timestamp)
  int get iat;

  /// Уникальный идентификатор токена
  String get jti;

  /// Список скопов пользователя
  List<String> get scopes;

  /// Дополнительные данные
  Map<String, dynamic>? get extra;

  /// Create a copy of PasetoTokenPayload
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $PasetoTokenPayloadCopyWith<PasetoTokenPayload> get copyWith =>
      _$PasetoTokenPayloadCopyWithImpl<PasetoTokenPayload>(
          this as PasetoTokenPayload, _$identity);

  /// Serializes this PasetoTokenPayload to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is PasetoTokenPayload &&
            (identical(other.sub, sub) || other.sub == sub) &&
            (identical(other.exp, exp) || other.exp == exp) &&
            (identical(other.iat, iat) || other.iat == iat) &&
            (identical(other.jti, jti) || other.jti == jti) &&
            const DeepCollectionEquality().equals(other.scopes, scopes) &&
            const DeepCollectionEquality().equals(other.extra, extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      sub,
      exp,
      iat,
      jti,
      const DeepCollectionEquality().hash(scopes),
      const DeepCollectionEquality().hash(extra));

  @override
  String toString() {
    return 'PasetoTokenPayload(sub: $sub, exp: $exp, iat: $iat, jti: $jti, scopes: $scopes, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class $PasetoTokenPayloadCopyWith<$Res> {
  factory $PasetoTokenPayloadCopyWith(
          PasetoTokenPayload value, $Res Function(PasetoTokenPayload) _then) =
      _$PasetoTokenPayloadCopyWithImpl;
  @useResult
  $Res call(
      {String sub,
      int exp,
      int iat,
      String jti,
      List<String> scopes,
      Map<String, dynamic>? extra});
}

/// @nodoc
class _$PasetoTokenPayloadCopyWithImpl<$Res>
    implements $PasetoTokenPayloadCopyWith<$Res> {
  _$PasetoTokenPayloadCopyWithImpl(this._self, this._then);

  final PasetoTokenPayload _self;
  final $Res Function(PasetoTokenPayload) _then;

  /// Create a copy of PasetoTokenPayload
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sub = null,
    Object? exp = null,
    Object? iat = null,
    Object? jti = null,
    Object? scopes = null,
    Object? extra = freezed,
  }) {
    return _then(_self.copyWith(
      sub: null == sub
          ? _self.sub
          : sub // ignore: cast_nullable_to_non_nullable
              as String,
      exp: null == exp
          ? _self.exp
          : exp // ignore: cast_nullable_to_non_nullable
              as int,
      iat: null == iat
          ? _self.iat
          : iat // ignore: cast_nullable_to_non_nullable
              as int,
      jti: null == jti
          ? _self.jti
          : jti // ignore: cast_nullable_to_non_nullable
              as String,
      scopes: null == scopes
          ? _self.scopes
          : scopes // ignore: cast_nullable_to_non_nullable
              as List<String>,
      extra: freezed == extra
          ? _self.extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _PasetoTokenPayload implements PasetoTokenPayload {
  const _PasetoTokenPayload(
      {required this.sub,
      required this.exp,
      required this.iat,
      required this.jti,
      required final List<String> scopes,
      final Map<String, dynamic>? extra})
      : _scopes = scopes,
        _extra = extra;
  factory _PasetoTokenPayload.fromJson(Map<String, dynamic> json) =>
      _$PasetoTokenPayloadFromJson(json);

  /// Идентификатор пользователя
  @override
  final String sub;

  /// Время истечения срока действия токена (unix timestamp)
  @override
  final int exp;

  /// Время создания токена (unix timestamp)
  @override
  final int iat;

  /// Уникальный идентификатор токена
  @override
  final String jti;

  /// Список скопов пользователя
  final List<String> _scopes;

  /// Список скопов пользователя
  @override
  List<String> get scopes {
    if (_scopes is EqualUnmodifiableListView) return _scopes;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_scopes);
  }

  /// Дополнительные данные
  final Map<String, dynamic>? _extra;

  /// Дополнительные данные
  @override
  Map<String, dynamic>? get extra {
    final value = _extra;
    if (value == null) return null;
    if (_extra is EqualUnmodifiableMapView) return _extra;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of PasetoTokenPayload
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$PasetoTokenPayloadCopyWith<_PasetoTokenPayload> get copyWith =>
      __$PasetoTokenPayloadCopyWithImpl<_PasetoTokenPayload>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$PasetoTokenPayloadToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _PasetoTokenPayload &&
            (identical(other.sub, sub) || other.sub == sub) &&
            (identical(other.exp, exp) || other.exp == exp) &&
            (identical(other.iat, iat) || other.iat == iat) &&
            (identical(other.jti, jti) || other.jti == jti) &&
            const DeepCollectionEquality().equals(other._scopes, _scopes) &&
            const DeepCollectionEquality().equals(other._extra, _extra));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      sub,
      exp,
      iat,
      jti,
      const DeepCollectionEquality().hash(_scopes),
      const DeepCollectionEquality().hash(_extra));

  @override
  String toString() {
    return 'PasetoTokenPayload(sub: $sub, exp: $exp, iat: $iat, jti: $jti, scopes: $scopes, extra: $extra)';
  }
}

/// @nodoc
abstract mixin class _$PasetoTokenPayloadCopyWith<$Res>
    implements $PasetoTokenPayloadCopyWith<$Res> {
  factory _$PasetoTokenPayloadCopyWith(
          _PasetoTokenPayload value, $Res Function(_PasetoTokenPayload) _then) =
      __$PasetoTokenPayloadCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String sub,
      int exp,
      int iat,
      String jti,
      List<String> scopes,
      Map<String, dynamic>? extra});
}

/// @nodoc
class __$PasetoTokenPayloadCopyWithImpl<$Res>
    implements _$PasetoTokenPayloadCopyWith<$Res> {
  __$PasetoTokenPayloadCopyWithImpl(this._self, this._then);

  final _PasetoTokenPayload _self;
  final $Res Function(_PasetoTokenPayload) _then;

  /// Create a copy of PasetoTokenPayload
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? sub = null,
    Object? exp = null,
    Object? iat = null,
    Object? jti = null,
    Object? scopes = null,
    Object? extra = freezed,
  }) {
    return _then(_PasetoTokenPayload(
      sub: null == sub
          ? _self.sub
          : sub // ignore: cast_nullable_to_non_nullable
              as String,
      exp: null == exp
          ? _self.exp
          : exp // ignore: cast_nullable_to_non_nullable
              as int,
      iat: null == iat
          ? _self.iat
          : iat // ignore: cast_nullable_to_non_nullable
              as int,
      jti: null == jti
          ? _self.jti
          : jti // ignore: cast_nullable_to_non_nullable
              as String,
      scopes: null == scopes
          ? _self._scopes
          : scopes // ignore: cast_nullable_to_non_nullable
              as List<String>,
      extra: freezed == extra
          ? _self._extra
          : extra // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
mixin _$WebAuthnAssertion {
  String get id;
  WebAuthnAssertionResponse get response;

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnAssertionCopyWith<WebAuthnAssertion> get copyWith =>
      _$WebAuthnAssertionCopyWithImpl<WebAuthnAssertion>(
          this as WebAuthnAssertion, _$identity);

  /// Serializes this WebAuthnAssertion to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnAssertion &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.response, response) ||
                other.response == response));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, response);

  @override
  String toString() {
    return 'WebAuthnAssertion(id: $id, response: $response)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnAssertionCopyWith<$Res> {
  factory $WebAuthnAssertionCopyWith(
          WebAuthnAssertion value, $Res Function(WebAuthnAssertion) _then) =
      _$WebAuthnAssertionCopyWithImpl;
  @useResult
  $Res call({String id, WebAuthnAssertionResponse response});

  $WebAuthnAssertionResponseCopyWith<$Res> get response;
}

/// @nodoc
class _$WebAuthnAssertionCopyWithImpl<$Res>
    implements $WebAuthnAssertionCopyWith<$Res> {
  _$WebAuthnAssertionCopyWithImpl(this._self, this._then);

  final WebAuthnAssertion _self;
  final $Res Function(WebAuthnAssertion) _then;

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? response = null,
  }) {
    return _then(_self.copyWith(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      response: null == response
          ? _self.response
          : response // ignore: cast_nullable_to_non_nullable
              as WebAuthnAssertionResponse,
    ));
  }

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnAssertionResponseCopyWith<$Res> get response {
    return $WebAuthnAssertionResponseCopyWith<$Res>(_self.response, (value) {
      return _then(_self.copyWith(response: value));
    });
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnAssertion extends WebAuthnAssertion {
  const _WebAuthnAssertion({required this.id, required this.response})
      : super._();
  factory _WebAuthnAssertion.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAssertionFromJson(json);

  @override
  final String id;
  @override
  final WebAuthnAssertionResponse response;

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnAssertionCopyWith<_WebAuthnAssertion> get copyWith =>
      __$WebAuthnAssertionCopyWithImpl<_WebAuthnAssertion>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnAssertionToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnAssertion &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.response, response) ||
                other.response == response));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, response);

  @override
  String toString() {
    return 'WebAuthnAssertion(id: $id, response: $response)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnAssertionCopyWith<$Res>
    implements $WebAuthnAssertionCopyWith<$Res> {
  factory _$WebAuthnAssertionCopyWith(
          _WebAuthnAssertion value, $Res Function(_WebAuthnAssertion) _then) =
      __$WebAuthnAssertionCopyWithImpl;
  @override
  @useResult
  $Res call({String id, WebAuthnAssertionResponse response});

  @override
  $WebAuthnAssertionResponseCopyWith<$Res> get response;
}

/// @nodoc
class __$WebAuthnAssertionCopyWithImpl<$Res>
    implements _$WebAuthnAssertionCopyWith<$Res> {
  __$WebAuthnAssertionCopyWithImpl(this._self, this._then);

  final _WebAuthnAssertion _self;
  final $Res Function(_WebAuthnAssertion) _then;

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? response = null,
  }) {
    return _then(_WebAuthnAssertion(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      response: null == response
          ? _self.response
          : response // ignore: cast_nullable_to_non_nullable
              as WebAuthnAssertionResponse,
    ));
  }

  /// Create a copy of WebAuthnAssertion
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnAssertionResponseCopyWith<$Res> get response {
    return $WebAuthnAssertionResponseCopyWith<$Res>(_self.response, (value) {
      return _then(_self.copyWith(response: value));
    });
  }
}

/// @nodoc
mixin _$WebAuthnAssertionResponse {
  List<int> get authenticatorData;
  List<int> get clientDataJSON;
  List<int> get signature;
  List<int>? get userHandle;

  /// Create a copy of WebAuthnAssertionResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnAssertionResponseCopyWith<WebAuthnAssertionResponse> get copyWith =>
      _$WebAuthnAssertionResponseCopyWithImpl<WebAuthnAssertionResponse>(
          this as WebAuthnAssertionResponse, _$identity);

  /// Serializes this WebAuthnAssertionResponse to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnAssertionResponse &&
            const DeepCollectionEquality()
                .equals(other.authenticatorData, authenticatorData) &&
            const DeepCollectionEquality()
                .equals(other.clientDataJSON, clientDataJSON) &&
            const DeepCollectionEquality().equals(other.signature, signature) &&
            const DeepCollectionEquality()
                .equals(other.userHandle, userHandle));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(authenticatorData),
      const DeepCollectionEquality().hash(clientDataJSON),
      const DeepCollectionEquality().hash(signature),
      const DeepCollectionEquality().hash(userHandle));

  @override
  String toString() {
    return 'WebAuthnAssertionResponse(authenticatorData: $authenticatorData, clientDataJSON: $clientDataJSON, signature: $signature, userHandle: $userHandle)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnAssertionResponseCopyWith<$Res> {
  factory $WebAuthnAssertionResponseCopyWith(WebAuthnAssertionResponse value,
          $Res Function(WebAuthnAssertionResponse) _then) =
      _$WebAuthnAssertionResponseCopyWithImpl;
  @useResult
  $Res call(
      {List<int> authenticatorData,
      List<int> clientDataJSON,
      List<int> signature,
      List<int>? userHandle});
}

/// @nodoc
class _$WebAuthnAssertionResponseCopyWithImpl<$Res>
    implements $WebAuthnAssertionResponseCopyWith<$Res> {
  _$WebAuthnAssertionResponseCopyWithImpl(this._self, this._then);

  final WebAuthnAssertionResponse _self;
  final $Res Function(WebAuthnAssertionResponse) _then;

  /// Create a copy of WebAuthnAssertionResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? authenticatorData = null,
    Object? clientDataJSON = null,
    Object? signature = null,
    Object? userHandle = freezed,
  }) {
    return _then(_self.copyWith(
      authenticatorData: null == authenticatorData
          ? _self.authenticatorData
          : authenticatorData // ignore: cast_nullable_to_non_nullable
              as List<int>,
      clientDataJSON: null == clientDataJSON
          ? _self.clientDataJSON
          : clientDataJSON // ignore: cast_nullable_to_non_nullable
              as List<int>,
      signature: null == signature
          ? _self.signature
          : signature // ignore: cast_nullable_to_non_nullable
              as List<int>,
      userHandle: freezed == userHandle
          ? _self.userHandle
          : userHandle // ignore: cast_nullable_to_non_nullable
              as List<int>?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnAssertionResponse extends WebAuthnAssertionResponse {
  const _WebAuthnAssertionResponse(
      {required final List<int> authenticatorData,
      required final List<int> clientDataJSON,
      required final List<int> signature,
      final List<int>? userHandle})
      : _authenticatorData = authenticatorData,
        _clientDataJSON = clientDataJSON,
        _signature = signature,
        _userHandle = userHandle,
        super._();
  factory _WebAuthnAssertionResponse.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAssertionResponseFromJson(json);

  final List<int> _authenticatorData;
  @override
  List<int> get authenticatorData {
    if (_authenticatorData is EqualUnmodifiableListView)
      return _authenticatorData;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_authenticatorData);
  }

  final List<int> _clientDataJSON;
  @override
  List<int> get clientDataJSON {
    if (_clientDataJSON is EqualUnmodifiableListView) return _clientDataJSON;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_clientDataJSON);
  }

  final List<int> _signature;
  @override
  List<int> get signature {
    if (_signature is EqualUnmodifiableListView) return _signature;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_signature);
  }

  final List<int>? _userHandle;
  @override
  List<int>? get userHandle {
    final value = _userHandle;
    if (value == null) return null;
    if (_userHandle is EqualUnmodifiableListView) return _userHandle;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  /// Create a copy of WebAuthnAssertionResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnAssertionResponseCopyWith<_WebAuthnAssertionResponse>
      get copyWith =>
          __$WebAuthnAssertionResponseCopyWithImpl<_WebAuthnAssertionResponse>(
              this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnAssertionResponseToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnAssertionResponse &&
            const DeepCollectionEquality()
                .equals(other._authenticatorData, _authenticatorData) &&
            const DeepCollectionEquality()
                .equals(other._clientDataJSON, _clientDataJSON) &&
            const DeepCollectionEquality()
                .equals(other._signature, _signature) &&
            const DeepCollectionEquality()
                .equals(other._userHandle, _userHandle));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_authenticatorData),
      const DeepCollectionEquality().hash(_clientDataJSON),
      const DeepCollectionEquality().hash(_signature),
      const DeepCollectionEquality().hash(_userHandle));

  @override
  String toString() {
    return 'WebAuthnAssertionResponse(authenticatorData: $authenticatorData, clientDataJSON: $clientDataJSON, signature: $signature, userHandle: $userHandle)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnAssertionResponseCopyWith<$Res>
    implements $WebAuthnAssertionResponseCopyWith<$Res> {
  factory _$WebAuthnAssertionResponseCopyWith(_WebAuthnAssertionResponse value,
          $Res Function(_WebAuthnAssertionResponse) _then) =
      __$WebAuthnAssertionResponseCopyWithImpl;
  @override
  @useResult
  $Res call(
      {List<int> authenticatorData,
      List<int> clientDataJSON,
      List<int> signature,
      List<int>? userHandle});
}

/// @nodoc
class __$WebAuthnAssertionResponseCopyWithImpl<$Res>
    implements _$WebAuthnAssertionResponseCopyWith<$Res> {
  __$WebAuthnAssertionResponseCopyWithImpl(this._self, this._then);

  final _WebAuthnAssertionResponse _self;
  final $Res Function(_WebAuthnAssertionResponse) _then;

  /// Create a copy of WebAuthnAssertionResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? authenticatorData = null,
    Object? clientDataJSON = null,
    Object? signature = null,
    Object? userHandle = freezed,
  }) {
    return _then(_WebAuthnAssertionResponse(
      authenticatorData: null == authenticatorData
          ? _self._authenticatorData
          : authenticatorData // ignore: cast_nullable_to_non_nullable
              as List<int>,
      clientDataJSON: null == clientDataJSON
          ? _self._clientDataJSON
          : clientDataJSON // ignore: cast_nullable_to_non_nullable
              as List<int>,
      signature: null == signature
          ? _self._signature
          : signature // ignore: cast_nullable_to_non_nullable
              as List<int>,
      userHandle: freezed == userHandle
          ? _self._userHandle
          : userHandle // ignore: cast_nullable_to_non_nullable
              as List<int>?,
    ));
  }
}

/// @nodoc
mixin _$WebAuthnRegistrationCredential {
  String get id;
  WebAuthnRegistrationResponse get response;
  String? get type;
  Map<String, dynamic>? get transports;

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnRegistrationCredentialCopyWith<WebAuthnRegistrationCredential>
      get copyWith => _$WebAuthnRegistrationCredentialCopyWithImpl<
              WebAuthnRegistrationCredential>(
          this as WebAuthnRegistrationCredential, _$identity);

  /// Serializes this WebAuthnRegistrationCredential to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnRegistrationCredential &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.response, response) ||
                other.response == response) &&
            (identical(other.type, type) || other.type == type) &&
            const DeepCollectionEquality()
                .equals(other.transports, transports));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, response, type,
      const DeepCollectionEquality().hash(transports));

  @override
  String toString() {
    return 'WebAuthnRegistrationCredential(id: $id, response: $response, type: $type, transports: $transports)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnRegistrationCredentialCopyWith<$Res> {
  factory $WebAuthnRegistrationCredentialCopyWith(
          WebAuthnRegistrationCredential value,
          $Res Function(WebAuthnRegistrationCredential) _then) =
      _$WebAuthnRegistrationCredentialCopyWithImpl;
  @useResult
  $Res call(
      {String id,
      WebAuthnRegistrationResponse response,
      String? type,
      Map<String, dynamic>? transports});

  $WebAuthnRegistrationResponseCopyWith<$Res> get response;
}

/// @nodoc
class _$WebAuthnRegistrationCredentialCopyWithImpl<$Res>
    implements $WebAuthnRegistrationCredentialCopyWith<$Res> {
  _$WebAuthnRegistrationCredentialCopyWithImpl(this._self, this._then);

  final WebAuthnRegistrationCredential _self;
  final $Res Function(WebAuthnRegistrationCredential) _then;

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? response = null,
    Object? type = freezed,
    Object? transports = freezed,
  }) {
    return _then(_self.copyWith(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      response: null == response
          ? _self.response
          : response // ignore: cast_nullable_to_non_nullable
              as WebAuthnRegistrationResponse,
      type: freezed == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as String?,
      transports: freezed == transports
          ? _self.transports
          : transports // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnRegistrationResponseCopyWith<$Res> get response {
    return $WebAuthnRegistrationResponseCopyWith<$Res>(_self.response, (value) {
      return _then(_self.copyWith(response: value));
    });
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnRegistrationCredential extends WebAuthnRegistrationCredential {
  const _WebAuthnRegistrationCredential(
      {required this.id,
      required this.response,
      this.type,
      final Map<String, dynamic>? transports})
      : _transports = transports,
        super._();
  factory _WebAuthnRegistrationCredential.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRegistrationCredentialFromJson(json);

  @override
  final String id;
  @override
  final WebAuthnRegistrationResponse response;
  @override
  final String? type;
  final Map<String, dynamic>? _transports;
  @override
  Map<String, dynamic>? get transports {
    final value = _transports;
    if (value == null) return null;
    if (_transports is EqualUnmodifiableMapView) return _transports;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnRegistrationCredentialCopyWith<_WebAuthnRegistrationCredential>
      get copyWith => __$WebAuthnRegistrationCredentialCopyWithImpl<
          _WebAuthnRegistrationCredential>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnRegistrationCredentialToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnRegistrationCredential &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.response, response) ||
                other.response == response) &&
            (identical(other.type, type) || other.type == type) &&
            const DeepCollectionEquality()
                .equals(other._transports, _transports));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, id, response, type,
      const DeepCollectionEquality().hash(_transports));

  @override
  String toString() {
    return 'WebAuthnRegistrationCredential(id: $id, response: $response, type: $type, transports: $transports)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnRegistrationCredentialCopyWith<$Res>
    implements $WebAuthnRegistrationCredentialCopyWith<$Res> {
  factory _$WebAuthnRegistrationCredentialCopyWith(
          _WebAuthnRegistrationCredential value,
          $Res Function(_WebAuthnRegistrationCredential) _then) =
      __$WebAuthnRegistrationCredentialCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String id,
      WebAuthnRegistrationResponse response,
      String? type,
      Map<String, dynamic>? transports});

  @override
  $WebAuthnRegistrationResponseCopyWith<$Res> get response;
}

/// @nodoc
class __$WebAuthnRegistrationCredentialCopyWithImpl<$Res>
    implements _$WebAuthnRegistrationCredentialCopyWith<$Res> {
  __$WebAuthnRegistrationCredentialCopyWithImpl(this._self, this._then);

  final _WebAuthnRegistrationCredential _self;
  final $Res Function(_WebAuthnRegistrationCredential) _then;

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? id = null,
    Object? response = null,
    Object? type = freezed,
    Object? transports = freezed,
  }) {
    return _then(_WebAuthnRegistrationCredential(
      id: null == id
          ? _self.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      response: null == response
          ? _self.response
          : response // ignore: cast_nullable_to_non_nullable
              as WebAuthnRegistrationResponse,
      type: freezed == type
          ? _self.type
          : type // ignore: cast_nullable_to_non_nullable
              as String?,
      transports: freezed == transports
          ? _self._transports
          : transports // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }

  /// Create a copy of WebAuthnRegistrationCredential
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnRegistrationResponseCopyWith<$Res> get response {
    return $WebAuthnRegistrationResponseCopyWith<$Res>(_self.response, (value) {
      return _then(_self.copyWith(response: value));
    });
  }
}

/// @nodoc
mixin _$WebAuthnRegistrationResponse {
  @Uint8ListConverter()
  Uint8List get attestationObject;
  @Uint8ListConverter()
  Uint8List get clientDataJSON; // Опциональные поля для дополнительных данных
  Map<String, dynamic>? get extensions;

  /// Create a copy of WebAuthnRegistrationResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnRegistrationResponseCopyWith<WebAuthnRegistrationResponse>
      get copyWith => _$WebAuthnRegistrationResponseCopyWithImpl<
              WebAuthnRegistrationResponse>(
          this as WebAuthnRegistrationResponse, _$identity);

  /// Serializes this WebAuthnRegistrationResponse to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnRegistrationResponse &&
            const DeepCollectionEquality()
                .equals(other.attestationObject, attestationObject) &&
            const DeepCollectionEquality()
                .equals(other.clientDataJSON, clientDataJSON) &&
            const DeepCollectionEquality()
                .equals(other.extensions, extensions));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(attestationObject),
      const DeepCollectionEquality().hash(clientDataJSON),
      const DeepCollectionEquality().hash(extensions));

  @override
  String toString() {
    return 'WebAuthnRegistrationResponse(attestationObject: $attestationObject, clientDataJSON: $clientDataJSON, extensions: $extensions)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnRegistrationResponseCopyWith<$Res> {
  factory $WebAuthnRegistrationResponseCopyWith(
          WebAuthnRegistrationResponse value,
          $Res Function(WebAuthnRegistrationResponse) _then) =
      _$WebAuthnRegistrationResponseCopyWithImpl;
  @useResult
  $Res call(
      {@Uint8ListConverter() Uint8List attestationObject,
      @Uint8ListConverter() Uint8List clientDataJSON,
      Map<String, dynamic>? extensions});
}

/// @nodoc
class _$WebAuthnRegistrationResponseCopyWithImpl<$Res>
    implements $WebAuthnRegistrationResponseCopyWith<$Res> {
  _$WebAuthnRegistrationResponseCopyWithImpl(this._self, this._then);

  final WebAuthnRegistrationResponse _self;
  final $Res Function(WebAuthnRegistrationResponse) _then;

  /// Create a copy of WebAuthnRegistrationResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? attestationObject = null,
    Object? clientDataJSON = null,
    Object? extensions = freezed,
  }) {
    return _then(_self.copyWith(
      attestationObject: null == attestationObject
          ? _self.attestationObject
          : attestationObject // ignore: cast_nullable_to_non_nullable
              as Uint8List,
      clientDataJSON: null == clientDataJSON
          ? _self.clientDataJSON
          : clientDataJSON // ignore: cast_nullable_to_non_nullable
              as Uint8List,
      extensions: freezed == extensions
          ? _self.extensions
          : extensions // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnRegistrationResponse extends WebAuthnRegistrationResponse {
  const _WebAuthnRegistrationResponse(
      {@Uint8ListConverter() required this.attestationObject,
      @Uint8ListConverter() required this.clientDataJSON,
      final Map<String, dynamic>? extensions})
      : _extensions = extensions,
        super._();
  factory _WebAuthnRegistrationResponse.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRegistrationResponseFromJson(json);

  @override
  @Uint8ListConverter()
  final Uint8List attestationObject;
  @override
  @Uint8ListConverter()
  final Uint8List clientDataJSON;
// Опциональные поля для дополнительных данных
  final Map<String, dynamic>? _extensions;
// Опциональные поля для дополнительных данных
  @override
  Map<String, dynamic>? get extensions {
    final value = _extensions;
    if (value == null) return null;
    if (_extensions is EqualUnmodifiableMapView) return _extensions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(value);
  }

  /// Create a copy of WebAuthnRegistrationResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnRegistrationResponseCopyWith<_WebAuthnRegistrationResponse>
      get copyWith => __$WebAuthnRegistrationResponseCopyWithImpl<
          _WebAuthnRegistrationResponse>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnRegistrationResponseToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnRegistrationResponse &&
            const DeepCollectionEquality()
                .equals(other.attestationObject, attestationObject) &&
            const DeepCollectionEquality()
                .equals(other.clientDataJSON, clientDataJSON) &&
            const DeepCollectionEquality()
                .equals(other._extensions, _extensions));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(attestationObject),
      const DeepCollectionEquality().hash(clientDataJSON),
      const DeepCollectionEquality().hash(_extensions));

  @override
  String toString() {
    return 'WebAuthnRegistrationResponse(attestationObject: $attestationObject, clientDataJSON: $clientDataJSON, extensions: $extensions)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnRegistrationResponseCopyWith<$Res>
    implements $WebAuthnRegistrationResponseCopyWith<$Res> {
  factory _$WebAuthnRegistrationResponseCopyWith(
          _WebAuthnRegistrationResponse value,
          $Res Function(_WebAuthnRegistrationResponse) _then) =
      __$WebAuthnRegistrationResponseCopyWithImpl;
  @override
  @useResult
  $Res call(
      {@Uint8ListConverter() Uint8List attestationObject,
      @Uint8ListConverter() Uint8List clientDataJSON,
      Map<String, dynamic>? extensions});
}

/// @nodoc
class __$WebAuthnRegistrationResponseCopyWithImpl<$Res>
    implements _$WebAuthnRegistrationResponseCopyWith<$Res> {
  __$WebAuthnRegistrationResponseCopyWithImpl(this._self, this._then);

  final _WebAuthnRegistrationResponse _self;
  final $Res Function(_WebAuthnRegistrationResponse) _then;

  /// Create a copy of WebAuthnRegistrationResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? attestationObject = null,
    Object? clientDataJSON = null,
    Object? extensions = freezed,
  }) {
    return _then(_WebAuthnRegistrationResponse(
      attestationObject: null == attestationObject
          ? _self.attestationObject
          : attestationObject // ignore: cast_nullable_to_non_nullable
              as Uint8List,
      clientDataJSON: null == clientDataJSON
          ? _self.clientDataJSON
          : clientDataJSON // ignore: cast_nullable_to_non_nullable
              as Uint8List,
      extensions: freezed == extensions
          ? _self._extensions
          : extensions // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>?,
    ));
  }
}

/// @nodoc
mixin _$WebAuthnUserInfo {
  List<WebAuthnCredentialPublic> get credentials;
  WebAuthnCredentialPublic? get authenticatedCredential;
  WebAuthnException? get error;

  /// Create a copy of WebAuthnUserInfo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnUserInfoCopyWith<WebAuthnUserInfo> get copyWith =>
      _$WebAuthnUserInfoCopyWithImpl<WebAuthnUserInfo>(
          this as WebAuthnUserInfo, _$identity);

  /// Serializes this WebAuthnUserInfo to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnUserInfo &&
            const DeepCollectionEquality()
                .equals(other.credentials, credentials) &&
            (identical(
                    other.authenticatedCredential, authenticatedCredential) ||
                other.authenticatedCredential == authenticatedCredential) &&
            (identical(other.error, error) || other.error == error));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(credentials),
      authenticatedCredential,
      error);

  @override
  String toString() {
    return 'WebAuthnUserInfo(credentials: $credentials, authenticatedCredential: $authenticatedCredential, error: $error)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnUserInfoCopyWith<$Res> {
  factory $WebAuthnUserInfoCopyWith(
          WebAuthnUserInfo value, $Res Function(WebAuthnUserInfo) _then) =
      _$WebAuthnUserInfoCopyWithImpl;
  @useResult
  $Res call(
      {List<WebAuthnCredentialPublic> credentials,
      WebAuthnCredentialPublic? authenticatedCredential,
      WebAuthnException? error});

  $WebAuthnExceptionCopyWith<$Res>? get error;
}

/// @nodoc
class _$WebAuthnUserInfoCopyWithImpl<$Res>
    implements $WebAuthnUserInfoCopyWith<$Res> {
  _$WebAuthnUserInfoCopyWithImpl(this._self, this._then);

  final WebAuthnUserInfo _self;
  final $Res Function(WebAuthnUserInfo) _then;

  /// Create a copy of WebAuthnUserInfo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? credentials = null,
    Object? authenticatedCredential = freezed,
    Object? error = freezed,
  }) {
    return _then(_self.copyWith(
      credentials: null == credentials
          ? _self.credentials
          : credentials // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnCredentialPublic>,
      authenticatedCredential: freezed == authenticatedCredential
          ? _self.authenticatedCredential
          : authenticatedCredential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
      error: freezed == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as WebAuthnException?,
    ));
  }

  /// Create a copy of WebAuthnUserInfo
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
class _WebAuthnUserInfo extends WebAuthnUserInfo {
  const _WebAuthnUserInfo(
      {required final List<WebAuthnCredentialPublic> credentials,
      required this.authenticatedCredential,
      required this.error})
      : _credentials = credentials,
        super._();
  factory _WebAuthnUserInfo.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnUserInfoFromJson(json);

  final List<WebAuthnCredentialPublic> _credentials;
  @override
  List<WebAuthnCredentialPublic> get credentials {
    if (_credentials is EqualUnmodifiableListView) return _credentials;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_credentials);
  }

  @override
  final WebAuthnCredentialPublic? authenticatedCredential;
  @override
  final WebAuthnException? error;

  /// Create a copy of WebAuthnUserInfo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnUserInfoCopyWith<_WebAuthnUserInfo> get copyWith =>
      __$WebAuthnUserInfoCopyWithImpl<_WebAuthnUserInfo>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnUserInfoToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnUserInfo &&
            const DeepCollectionEquality()
                .equals(other._credentials, _credentials) &&
            (identical(
                    other.authenticatedCredential, authenticatedCredential) ||
                other.authenticatedCredential == authenticatedCredential) &&
            (identical(other.error, error) || other.error == error));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_credentials),
      authenticatedCredential,
      error);

  @override
  String toString() {
    return 'WebAuthnUserInfo(credentials: $credentials, authenticatedCredential: $authenticatedCredential, error: $error)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnUserInfoCopyWith<$Res>
    implements $WebAuthnUserInfoCopyWith<$Res> {
  factory _$WebAuthnUserInfoCopyWith(
          _WebAuthnUserInfo value, $Res Function(_WebAuthnUserInfo) _then) =
      __$WebAuthnUserInfoCopyWithImpl;
  @override
  @useResult
  $Res call(
      {List<WebAuthnCredentialPublic> credentials,
      WebAuthnCredentialPublic? authenticatedCredential,
      WebAuthnException? error});

  @override
  $WebAuthnExceptionCopyWith<$Res>? get error;
}

/// @nodoc
class __$WebAuthnUserInfoCopyWithImpl<$Res>
    implements _$WebAuthnUserInfoCopyWith<$Res> {
  __$WebAuthnUserInfoCopyWithImpl(this._self, this._then);

  final _WebAuthnUserInfo _self;
  final $Res Function(_WebAuthnUserInfo) _then;

  /// Create a copy of WebAuthnUserInfo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? credentials = null,
    Object? authenticatedCredential = freezed,
    Object? error = freezed,
  }) {
    return _then(_WebAuthnUserInfo(
      credentials: null == credentials
          ? _self._credentials
          : credentials // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnCredentialPublic>,
      authenticatedCredential: freezed == authenticatedCredential
          ? _self.authenticatedCredential
          : authenticatedCredential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
      error: freezed == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as WebAuthnException?,
    ));
  }

  /// Create a copy of WebAuthnUserInfo
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
mixin _$WebAuthnRemoveResult {
  bool get success;
  WebAuthnException? get error;

  /// Create a copy of WebAuthnRemoveResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnRemoveResultCopyWith<WebAuthnRemoveResult> get copyWith =>
      _$WebAuthnRemoveResultCopyWithImpl<WebAuthnRemoveResult>(
          this as WebAuthnRemoveResult, _$identity);

  /// Serializes this WebAuthnRemoveResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnRemoveResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.error, error) || other.error == error));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, error);

  @override
  String toString() {
    return 'WebAuthnRemoveResult(success: $success, error: $error)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnRemoveResultCopyWith<$Res> {
  factory $WebAuthnRemoveResultCopyWith(WebAuthnRemoveResult value,
          $Res Function(WebAuthnRemoveResult) _then) =
      _$WebAuthnRemoveResultCopyWithImpl;
  @useResult
  $Res call({bool success, WebAuthnException? error});

  $WebAuthnExceptionCopyWith<$Res>? get error;
}

/// @nodoc
class _$WebAuthnRemoveResultCopyWithImpl<$Res>
    implements $WebAuthnRemoveResultCopyWith<$Res> {
  _$WebAuthnRemoveResultCopyWithImpl(this._self, this._then);

  final WebAuthnRemoveResult _self;
  final $Res Function(WebAuthnRemoveResult) _then;

  /// Create a copy of WebAuthnRemoveResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? success = null,
    Object? error = freezed,
  }) {
    return _then(_self.copyWith(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as WebAuthnException?,
    ));
  }

  /// Create a copy of WebAuthnRemoveResult
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
class _WebAuthnRemoveResult extends WebAuthnRemoveResult {
  const _WebAuthnRemoveResult({required this.success, required this.error})
      : super._();
  factory _WebAuthnRemoveResult.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRemoveResultFromJson(json);

  @override
  final bool success;
  @override
  final WebAuthnException? error;

  /// Create a copy of WebAuthnRemoveResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnRemoveResultCopyWith<_WebAuthnRemoveResult> get copyWith =>
      __$WebAuthnRemoveResultCopyWithImpl<_WebAuthnRemoveResult>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnRemoveResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnRemoveResult &&
            (identical(other.success, success) || other.success == success) &&
            (identical(other.error, error) || other.error == error));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, success, error);

  @override
  String toString() {
    return 'WebAuthnRemoveResult(success: $success, error: $error)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnRemoveResultCopyWith<$Res>
    implements $WebAuthnRemoveResultCopyWith<$Res> {
  factory _$WebAuthnRemoveResultCopyWith(_WebAuthnRemoveResult value,
          $Res Function(_WebAuthnRemoveResult) _then) =
      __$WebAuthnRemoveResultCopyWithImpl;
  @override
  @useResult
  $Res call({bool success, WebAuthnException? error});

  @override
  $WebAuthnExceptionCopyWith<$Res>? get error;
}

/// @nodoc
class __$WebAuthnRemoveResultCopyWithImpl<$Res>
    implements _$WebAuthnRemoveResultCopyWith<$Res> {
  __$WebAuthnRemoveResultCopyWithImpl(this._self, this._then);

  final _WebAuthnRemoveResult _self;
  final $Res Function(_WebAuthnRemoveResult) _then;

  /// Create a copy of WebAuthnRemoveResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? success = null,
    Object? error = freezed,
  }) {
    return _then(_WebAuthnRemoveResult(
      success: null == success
          ? _self.success
          : success // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _self.error
          : error // ignore: cast_nullable_to_non_nullable
              as WebAuthnException?,
    ));
  }

  /// Create a copy of WebAuthnRemoveResult
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
mixin _$WebAuthnAuthContext {
  /// Идентификатор RP (Relying Party)
  String get rpId;

  /// Origin запроса
  String get origin;

  /// Платформа клиента
  String get platform;

  /// Скопы пользователя
  List<String> get scopes;

  /// Идентификатор сессии
  String? get sessionId;

  /// Аутентифицирован ли пользователь
  bool get isAuthenticated;

  /// Учетные данные пользователя (если аутентифицирован)
  WebAuthnCredentialPublic? get credential;

  /// Дополнительные метаданные
  Map<String, dynamic> get metadata;

  /// Create a copy of WebAuthnAuthContext
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnAuthContextCopyWith<WebAuthnAuthContext> get copyWith =>
      _$WebAuthnAuthContextCopyWithImpl<WebAuthnAuthContext>(
          this as WebAuthnAuthContext, _$identity);

  /// Serializes this WebAuthnAuthContext to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnAuthContext &&
            (identical(other.rpId, rpId) || other.rpId == rpId) &&
            (identical(other.origin, origin) || other.origin == origin) &&
            (identical(other.platform, platform) ||
                other.platform == platform) &&
            const DeepCollectionEquality().equals(other.scopes, scopes) &&
            (identical(other.sessionId, sessionId) ||
                other.sessionId == sessionId) &&
            (identical(other.isAuthenticated, isAuthenticated) ||
                other.isAuthenticated == isAuthenticated) &&
            (identical(other.credential, credential) ||
                other.credential == credential) &&
            const DeepCollectionEquality().equals(other.metadata, metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      rpId,
      origin,
      platform,
      const DeepCollectionEquality().hash(scopes),
      sessionId,
      isAuthenticated,
      credential,
      const DeepCollectionEquality().hash(metadata));

  @override
  String toString() {
    return 'WebAuthnAuthContext(rpId: $rpId, origin: $origin, platform: $platform, scopes: $scopes, sessionId: $sessionId, isAuthenticated: $isAuthenticated, credential: $credential, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnAuthContextCopyWith<$Res> {
  factory $WebAuthnAuthContextCopyWith(
          WebAuthnAuthContext value, $Res Function(WebAuthnAuthContext) _then) =
      _$WebAuthnAuthContextCopyWithImpl;
  @useResult
  $Res call(
      {String rpId,
      String origin,
      String platform,
      List<String> scopes,
      String? sessionId,
      bool isAuthenticated,
      WebAuthnCredentialPublic? credential,
      Map<String, dynamic> metadata});
}

/// @nodoc
class _$WebAuthnAuthContextCopyWithImpl<$Res>
    implements $WebAuthnAuthContextCopyWith<$Res> {
  _$WebAuthnAuthContextCopyWithImpl(this._self, this._then);

  final WebAuthnAuthContext _self;
  final $Res Function(WebAuthnAuthContext) _then;

  /// Create a copy of WebAuthnAuthContext
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rpId = null,
    Object? origin = null,
    Object? platform = null,
    Object? scopes = null,
    Object? sessionId = freezed,
    Object? isAuthenticated = null,
    Object? credential = freezed,
    Object? metadata = null,
  }) {
    return _then(_self.copyWith(
      rpId: null == rpId
          ? _self.rpId
          : rpId // ignore: cast_nullable_to_non_nullable
              as String,
      origin: null == origin
          ? _self.origin
          : origin // ignore: cast_nullable_to_non_nullable
              as String,
      platform: null == platform
          ? _self.platform
          : platform // ignore: cast_nullable_to_non_nullable
              as String,
      scopes: null == scopes
          ? _self.scopes
          : scopes // ignore: cast_nullable_to_non_nullable
              as List<String>,
      sessionId: freezed == sessionId
          ? _self.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String?,
      isAuthenticated: null == isAuthenticated
          ? _self.isAuthenticated
          : isAuthenticated // ignore: cast_nullable_to_non_nullable
              as bool,
      credential: freezed == credential
          ? _self.credential
          : credential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
      metadata: null == metadata
          ? _self.metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnAuthContext implements WebAuthnAuthContext {
  const _WebAuthnAuthContext(
      {required this.rpId,
      required this.origin,
      required this.platform,
      required final List<String> scopes,
      this.sessionId,
      this.isAuthenticated = false,
      this.credential,
      final Map<String, dynamic> metadata = const {}})
      : _scopes = scopes,
        _metadata = metadata;
  factory _WebAuthnAuthContext.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAuthContextFromJson(json);

  /// Идентификатор RP (Relying Party)
  @override
  final String rpId;

  /// Origin запроса
  @override
  final String origin;

  /// Платформа клиента
  @override
  final String platform;

  /// Скопы пользователя
  final List<String> _scopes;

  /// Скопы пользователя
  @override
  List<String> get scopes {
    if (_scopes is EqualUnmodifiableListView) return _scopes;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_scopes);
  }

  /// Идентификатор сессии
  @override
  final String? sessionId;

  /// Аутентифицирован ли пользователь
  @override
  @JsonKey()
  final bool isAuthenticated;

  /// Учетные данные пользователя (если аутентифицирован)
  @override
  final WebAuthnCredentialPublic? credential;

  /// Дополнительные метаданные
  final Map<String, dynamic> _metadata;

  /// Дополнительные метаданные
  @override
  @JsonKey()
  Map<String, dynamic> get metadata {
    if (_metadata is EqualUnmodifiableMapView) return _metadata;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_metadata);
  }

  /// Create a copy of WebAuthnAuthContext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnAuthContextCopyWith<_WebAuthnAuthContext> get copyWith =>
      __$WebAuthnAuthContextCopyWithImpl<_WebAuthnAuthContext>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnAuthContextToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnAuthContext &&
            (identical(other.rpId, rpId) || other.rpId == rpId) &&
            (identical(other.origin, origin) || other.origin == origin) &&
            (identical(other.platform, platform) ||
                other.platform == platform) &&
            const DeepCollectionEquality().equals(other._scopes, _scopes) &&
            (identical(other.sessionId, sessionId) ||
                other.sessionId == sessionId) &&
            (identical(other.isAuthenticated, isAuthenticated) ||
                other.isAuthenticated == isAuthenticated) &&
            (identical(other.credential, credential) ||
                other.credential == credential) &&
            const DeepCollectionEquality().equals(other._metadata, _metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      rpId,
      origin,
      platform,
      const DeepCollectionEquality().hash(_scopes),
      sessionId,
      isAuthenticated,
      credential,
      const DeepCollectionEquality().hash(_metadata));

  @override
  String toString() {
    return 'WebAuthnAuthContext(rpId: $rpId, origin: $origin, platform: $platform, scopes: $scopes, sessionId: $sessionId, isAuthenticated: $isAuthenticated, credential: $credential, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnAuthContextCopyWith<$Res>
    implements $WebAuthnAuthContextCopyWith<$Res> {
  factory _$WebAuthnAuthContextCopyWith(_WebAuthnAuthContext value,
          $Res Function(_WebAuthnAuthContext) _then) =
      __$WebAuthnAuthContextCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String rpId,
      String origin,
      String platform,
      List<String> scopes,
      String? sessionId,
      bool isAuthenticated,
      WebAuthnCredentialPublic? credential,
      Map<String, dynamic> metadata});
}

/// @nodoc
class __$WebAuthnAuthContextCopyWithImpl<$Res>
    implements _$WebAuthnAuthContextCopyWith<$Res> {
  __$WebAuthnAuthContextCopyWithImpl(this._self, this._then);

  final _WebAuthnAuthContext _self;
  final $Res Function(_WebAuthnAuthContext) _then;

  /// Create a copy of WebAuthnAuthContext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? rpId = null,
    Object? origin = null,
    Object? platform = null,
    Object? scopes = null,
    Object? sessionId = freezed,
    Object? isAuthenticated = null,
    Object? credential = freezed,
    Object? metadata = null,
  }) {
    return _then(_WebAuthnAuthContext(
      rpId: null == rpId
          ? _self.rpId
          : rpId // ignore: cast_nullable_to_non_nullable
              as String,
      origin: null == origin
          ? _self.origin
          : origin // ignore: cast_nullable_to_non_nullable
              as String,
      platform: null == platform
          ? _self.platform
          : platform // ignore: cast_nullable_to_non_nullable
              as String,
      scopes: null == scopes
          ? _self._scopes
          : scopes // ignore: cast_nullable_to_non_nullable
              as List<String>,
      sessionId: freezed == sessionId
          ? _self.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String?,
      isAuthenticated: null == isAuthenticated
          ? _self.isAuthenticated
          : isAuthenticated // ignore: cast_nullable_to_non_nullable
              as bool,
      credential: freezed == credential
          ? _self.credential
          : credential // ignore: cast_nullable_to_non_nullable
              as WebAuthnCredentialPublic?,
      metadata: null == metadata
          ? _self._metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
    ));
  }
}

/// @nodoc
mixin _$AuthContextValidationResult {
  /// Валиден ли контекст
  bool get isValid;

  /// Сообщение об ошибке (если не валиден)
  String? get errorMessage;

  /// Обновлённый контекст (если требуется обновление)
  WebAuthnAuthContext? get updatedContext;

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $AuthContextValidationResultCopyWith<AuthContextValidationResult>
      get copyWith => _$AuthContextValidationResultCopyWithImpl<
              AuthContextValidationResult>(
          this as AuthContextValidationResult, _$identity);

  /// Serializes this AuthContextValidationResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is AuthContextValidationResult &&
            (identical(other.isValid, isValid) || other.isValid == isValid) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.updatedContext, updatedContext) ||
                other.updatedContext == updatedContext));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, isValid, errorMessage, updatedContext);

  @override
  String toString() {
    return 'AuthContextValidationResult(isValid: $isValid, errorMessage: $errorMessage, updatedContext: $updatedContext)';
  }
}

/// @nodoc
abstract mixin class $AuthContextValidationResultCopyWith<$Res> {
  factory $AuthContextValidationResultCopyWith(
          AuthContextValidationResult value,
          $Res Function(AuthContextValidationResult) _then) =
      _$AuthContextValidationResultCopyWithImpl;
  @useResult
  $Res call(
      {bool isValid,
      String? errorMessage,
      WebAuthnAuthContext? updatedContext});

  $WebAuthnAuthContextCopyWith<$Res>? get updatedContext;
}

/// @nodoc
class _$AuthContextValidationResultCopyWithImpl<$Res>
    implements $AuthContextValidationResultCopyWith<$Res> {
  _$AuthContextValidationResultCopyWithImpl(this._self, this._then);

  final AuthContextValidationResult _self;
  final $Res Function(AuthContextValidationResult) _then;

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isValid = null,
    Object? errorMessage = freezed,
    Object? updatedContext = freezed,
  }) {
    return _then(_self.copyWith(
      isValid: null == isValid
          ? _self.isValid
          : isValid // ignore: cast_nullable_to_non_nullable
              as bool,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      updatedContext: freezed == updatedContext
          ? _self.updatedContext
          : updatedContext // ignore: cast_nullable_to_non_nullable
              as WebAuthnAuthContext?,
    ));
  }

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnAuthContextCopyWith<$Res>? get updatedContext {
    if (_self.updatedContext == null) {
      return null;
    }

    return $WebAuthnAuthContextCopyWith<$Res>(_self.updatedContext!, (value) {
      return _then(_self.copyWith(updatedContext: value));
    });
  }
}

/// @nodoc
@JsonSerializable()
class _AuthContextValidationResult implements AuthContextValidationResult {
  const _AuthContextValidationResult(
      {required this.isValid, this.errorMessage, this.updatedContext});
  factory _AuthContextValidationResult.fromJson(Map<String, dynamic> json) =>
      _$AuthContextValidationResultFromJson(json);

  /// Валиден ли контекст
  @override
  final bool isValid;

  /// Сообщение об ошибке (если не валиден)
  @override
  final String? errorMessage;

  /// Обновлённый контекст (если требуется обновление)
  @override
  final WebAuthnAuthContext? updatedContext;

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$AuthContextValidationResultCopyWith<_AuthContextValidationResult>
      get copyWith => __$AuthContextValidationResultCopyWithImpl<
          _AuthContextValidationResult>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$AuthContextValidationResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _AuthContextValidationResult &&
            (identical(other.isValid, isValid) || other.isValid == isValid) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.updatedContext, updatedContext) ||
                other.updatedContext == updatedContext));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, isValid, errorMessage, updatedContext);

  @override
  String toString() {
    return 'AuthContextValidationResult(isValid: $isValid, errorMessage: $errorMessage, updatedContext: $updatedContext)';
  }
}

/// @nodoc
abstract mixin class _$AuthContextValidationResultCopyWith<$Res>
    implements $AuthContextValidationResultCopyWith<$Res> {
  factory _$AuthContextValidationResultCopyWith(
          _AuthContextValidationResult value,
          $Res Function(_AuthContextValidationResult) _then) =
      __$AuthContextValidationResultCopyWithImpl;
  @override
  @useResult
  $Res call(
      {bool isValid,
      String? errorMessage,
      WebAuthnAuthContext? updatedContext});

  @override
  $WebAuthnAuthContextCopyWith<$Res>? get updatedContext;
}

/// @nodoc
class __$AuthContextValidationResultCopyWithImpl<$Res>
    implements _$AuthContextValidationResultCopyWith<$Res> {
  __$AuthContextValidationResultCopyWithImpl(this._self, this._then);

  final _AuthContextValidationResult _self;
  final $Res Function(_AuthContextValidationResult) _then;

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? isValid = null,
    Object? errorMessage = freezed,
    Object? updatedContext = freezed,
  }) {
    return _then(_AuthContextValidationResult(
      isValid: null == isValid
          ? _self.isValid
          : isValid // ignore: cast_nullable_to_non_nullable
              as bool,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      updatedContext: freezed == updatedContext
          ? _self.updatedContext
          : updatedContext // ignore: cast_nullable_to_non_nullable
              as WebAuthnAuthContext?,
    ));
  }

  /// Create a copy of AuthContextValidationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $WebAuthnAuthContextCopyWith<$Res>? get updatedContext {
    if (_self.updatedContext == null) {
      return null;
    }

    return $WebAuthnAuthContextCopyWith<$Res>(_self.updatedContext!, (value) {
      return _then(_self.copyWith(updatedContext: value));
    });
  }
}

/// @nodoc
mixin _$WebAuthnAuthorizationContext {
  /// Идентификатор текущего пользователя
  String get currentUserId;

  /// Права доступа текущего пользователя
  List<WebAuthnPermission> get permissions;

  /// Идентификатор сессии
  String? get sessionId;

  /// Дополнительные метаданные
  Map<String, dynamic> get metadata;

  /// Create a copy of WebAuthnAuthorizationContext
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $WebAuthnAuthorizationContextCopyWith<WebAuthnAuthorizationContext>
      get copyWith => _$WebAuthnAuthorizationContextCopyWithImpl<
              WebAuthnAuthorizationContext>(
          this as WebAuthnAuthorizationContext, _$identity);

  /// Serializes this WebAuthnAuthorizationContext to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is WebAuthnAuthorizationContext &&
            (identical(other.currentUserId, currentUserId) ||
                other.currentUserId == currentUserId) &&
            const DeepCollectionEquality()
                .equals(other.permissions, permissions) &&
            (identical(other.sessionId, sessionId) ||
                other.sessionId == sessionId) &&
            const DeepCollectionEquality().equals(other.metadata, metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      currentUserId,
      const DeepCollectionEquality().hash(permissions),
      sessionId,
      const DeepCollectionEquality().hash(metadata));

  @override
  String toString() {
    return 'WebAuthnAuthorizationContext(currentUserId: $currentUserId, permissions: $permissions, sessionId: $sessionId, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class $WebAuthnAuthorizationContextCopyWith<$Res> {
  factory $WebAuthnAuthorizationContextCopyWith(
          WebAuthnAuthorizationContext value,
          $Res Function(WebAuthnAuthorizationContext) _then) =
      _$WebAuthnAuthorizationContextCopyWithImpl;
  @useResult
  $Res call(
      {String currentUserId,
      List<WebAuthnPermission> permissions,
      String? sessionId,
      Map<String, dynamic> metadata});
}

/// @nodoc
class _$WebAuthnAuthorizationContextCopyWithImpl<$Res>
    implements $WebAuthnAuthorizationContextCopyWith<$Res> {
  _$WebAuthnAuthorizationContextCopyWithImpl(this._self, this._then);

  final WebAuthnAuthorizationContext _self;
  final $Res Function(WebAuthnAuthorizationContext) _then;

  /// Create a copy of WebAuthnAuthorizationContext
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? currentUserId = null,
    Object? permissions = null,
    Object? sessionId = freezed,
    Object? metadata = null,
  }) {
    return _then(_self.copyWith(
      currentUserId: null == currentUserId
          ? _self.currentUserId
          : currentUserId // ignore: cast_nullable_to_non_nullable
              as String,
      permissions: null == permissions
          ? _self.permissions
          : permissions // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnPermission>,
      sessionId: freezed == sessionId
          ? _self.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String?,
      metadata: null == metadata
          ? _self.metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _WebAuthnAuthorizationContext implements WebAuthnAuthorizationContext {
  const _WebAuthnAuthorizationContext(
      {required this.currentUserId,
      required final List<WebAuthnPermission> permissions,
      this.sessionId,
      final Map<String, dynamic> metadata = const {}})
      : _permissions = permissions,
        _metadata = metadata;
  factory _WebAuthnAuthorizationContext.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAuthorizationContextFromJson(json);

  /// Идентификатор текущего пользователя
  @override
  final String currentUserId;

  /// Права доступа текущего пользователя
  final List<WebAuthnPermission> _permissions;

  /// Права доступа текущего пользователя
  @override
  List<WebAuthnPermission> get permissions {
    if (_permissions is EqualUnmodifiableListView) return _permissions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_permissions);
  }

  /// Идентификатор сессии
  @override
  final String? sessionId;

  /// Дополнительные метаданные
  final Map<String, dynamic> _metadata;

  /// Дополнительные метаданные
  @override
  @JsonKey()
  Map<String, dynamic> get metadata {
    if (_metadata is EqualUnmodifiableMapView) return _metadata;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_metadata);
  }

  /// Create a copy of WebAuthnAuthorizationContext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$WebAuthnAuthorizationContextCopyWith<_WebAuthnAuthorizationContext>
      get copyWith => __$WebAuthnAuthorizationContextCopyWithImpl<
          _WebAuthnAuthorizationContext>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$WebAuthnAuthorizationContextToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _WebAuthnAuthorizationContext &&
            (identical(other.currentUserId, currentUserId) ||
                other.currentUserId == currentUserId) &&
            const DeepCollectionEquality()
                .equals(other._permissions, _permissions) &&
            (identical(other.sessionId, sessionId) ||
                other.sessionId == sessionId) &&
            const DeepCollectionEquality().equals(other._metadata, _metadata));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      currentUserId,
      const DeepCollectionEquality().hash(_permissions),
      sessionId,
      const DeepCollectionEquality().hash(_metadata));

  @override
  String toString() {
    return 'WebAuthnAuthorizationContext(currentUserId: $currentUserId, permissions: $permissions, sessionId: $sessionId, metadata: $metadata)';
  }
}

/// @nodoc
abstract mixin class _$WebAuthnAuthorizationContextCopyWith<$Res>
    implements $WebAuthnAuthorizationContextCopyWith<$Res> {
  factory _$WebAuthnAuthorizationContextCopyWith(
          _WebAuthnAuthorizationContext value,
          $Res Function(_WebAuthnAuthorizationContext) _then) =
      __$WebAuthnAuthorizationContextCopyWithImpl;
  @override
  @useResult
  $Res call(
      {String currentUserId,
      List<WebAuthnPermission> permissions,
      String? sessionId,
      Map<String, dynamic> metadata});
}

/// @nodoc
class __$WebAuthnAuthorizationContextCopyWithImpl<$Res>
    implements _$WebAuthnAuthorizationContextCopyWith<$Res> {
  __$WebAuthnAuthorizationContextCopyWithImpl(this._self, this._then);

  final _WebAuthnAuthorizationContext _self;
  final $Res Function(_WebAuthnAuthorizationContext) _then;

  /// Create a copy of WebAuthnAuthorizationContext
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? currentUserId = null,
    Object? permissions = null,
    Object? sessionId = freezed,
    Object? metadata = null,
  }) {
    return _then(_WebAuthnAuthorizationContext(
      currentUserId: null == currentUserId
          ? _self.currentUserId
          : currentUserId // ignore: cast_nullable_to_non_nullable
              as String,
      permissions: null == permissions
          ? _self._permissions
          : permissions // ignore: cast_nullable_to_non_nullable
              as List<WebAuthnPermission>,
      sessionId: freezed == sessionId
          ? _self.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String?,
      metadata: null == metadata
          ? _self._metadata
          : metadata // ignore: cast_nullable_to_non_nullable
              as Map<String, dynamic>,
    ));
  }
}

/// @nodoc
mixin _$AuthorizationResult {
  /// Разрешена ли операция
  bool get isAuthorized;

  /// Сообщение об ошибке (если не разрешена)
  String? get errorMessage;

  /// Код ошибки
  String? get errorCode;

  /// Create a copy of AuthorizationResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $AuthorizationResultCopyWith<AuthorizationResult> get copyWith =>
      _$AuthorizationResultCopyWithImpl<AuthorizationResult>(
          this as AuthorizationResult, _$identity);

  /// Serializes this AuthorizationResult to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is AuthorizationResult &&
            (identical(other.isAuthorized, isAuthorized) ||
                other.isAuthorized == isAuthorized) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.errorCode, errorCode) ||
                other.errorCode == errorCode));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, isAuthorized, errorMessage, errorCode);

  @override
  String toString() {
    return 'AuthorizationResult(isAuthorized: $isAuthorized, errorMessage: $errorMessage, errorCode: $errorCode)';
  }
}

/// @nodoc
abstract mixin class $AuthorizationResultCopyWith<$Res> {
  factory $AuthorizationResultCopyWith(
          AuthorizationResult value, $Res Function(AuthorizationResult) _then) =
      _$AuthorizationResultCopyWithImpl;
  @useResult
  $Res call({bool isAuthorized, String? errorMessage, String? errorCode});
}

/// @nodoc
class _$AuthorizationResultCopyWithImpl<$Res>
    implements $AuthorizationResultCopyWith<$Res> {
  _$AuthorizationResultCopyWithImpl(this._self, this._then);

  final AuthorizationResult _self;
  final $Res Function(AuthorizationResult) _then;

  /// Create a copy of AuthorizationResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isAuthorized = null,
    Object? errorMessage = freezed,
    Object? errorCode = freezed,
  }) {
    return _then(_self.copyWith(
      isAuthorized: null == isAuthorized
          ? _self.isAuthorized
          : isAuthorized // ignore: cast_nullable_to_non_nullable
              as bool,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      errorCode: freezed == errorCode
          ? _self.errorCode
          : errorCode // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _AuthorizationResult implements AuthorizationResult {
  const _AuthorizationResult(
      {required this.isAuthorized, this.errorMessage, this.errorCode});
  factory _AuthorizationResult.fromJson(Map<String, dynamic> json) =>
      _$AuthorizationResultFromJson(json);

  /// Разрешена ли операция
  @override
  final bool isAuthorized;

  /// Сообщение об ошибке (если не разрешена)
  @override
  final String? errorMessage;

  /// Код ошибки
  @override
  final String? errorCode;

  /// Create a copy of AuthorizationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$AuthorizationResultCopyWith<_AuthorizationResult> get copyWith =>
      __$AuthorizationResultCopyWithImpl<_AuthorizationResult>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$AuthorizationResultToJson(
      this,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _AuthorizationResult &&
            (identical(other.isAuthorized, isAuthorized) ||
                other.isAuthorized == isAuthorized) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.errorCode, errorCode) ||
                other.errorCode == errorCode));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, isAuthorized, errorMessage, errorCode);

  @override
  String toString() {
    return 'AuthorizationResult(isAuthorized: $isAuthorized, errorMessage: $errorMessage, errorCode: $errorCode)';
  }
}

/// @nodoc
abstract mixin class _$AuthorizationResultCopyWith<$Res>
    implements $AuthorizationResultCopyWith<$Res> {
  factory _$AuthorizationResultCopyWith(_AuthorizationResult value,
          $Res Function(_AuthorizationResult) _then) =
      __$AuthorizationResultCopyWithImpl;
  @override
  @useResult
  $Res call({bool isAuthorized, String? errorMessage, String? errorCode});
}

/// @nodoc
class __$AuthorizationResultCopyWithImpl<$Res>
    implements _$AuthorizationResultCopyWith<$Res> {
  __$AuthorizationResultCopyWithImpl(this._self, this._then);

  final _AuthorizationResult _self;
  final $Res Function(_AuthorizationResult) _then;

  /// Create a copy of AuthorizationResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? isAuthorized = null,
    Object? errorMessage = freezed,
    Object? errorCode = freezed,
  }) {
    return _then(_AuthorizationResult(
      isAuthorized: null == isAuthorized
          ? _self.isAuthorized
          : isAuthorized // ignore: cast_nullable_to_non_nullable
              as bool,
      errorMessage: freezed == errorMessage
          ? _self.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      errorCode: freezed == errorCode
          ? _self.errorCode
          : errorCode // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

// dart format on
