//
//  Generated code. Do not modify.
//  source: user_service.proto
//
// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'user_service.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'user_service.pbenum.dart';

/// Базовая информация о пользователе
class User extends $pb.GeneratedMessage {
  factory User({
    $core.int? id,
    $core.String? name,
    $core.String? email,
    $core.Iterable<$core.String>? tags,
    UserStatus? status,
    $fixnum.Int64? createdAt,
  }) {
    final $result = create();
    if (id != null) {
      $result.id = id;
    }
    if (name != null) {
      $result.name = name;
    }
    if (email != null) {
      $result.email = email;
    }
    if (tags != null) {
      $result.tags.addAll(tags);
    }
    if (status != null) {
      $result.status = status;
    }
    if (createdAt != null) {
      $result.createdAt = createdAt;
    }
    return $result;
  }
  User._() : super();
  factory User.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory User.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'User', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'id', $pb.PbFieldType.O3)
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'email')
    ..pPS(4, _omitFieldNames ? '' : 'tags')
    ..e<UserStatus>(5, _omitFieldNames ? '' : 'status', $pb.PbFieldType.OE, defaultOrMaker: UserStatus.UNKNOWN, valueOf: UserStatus.valueOf, enumValues: UserStatus.values)
    ..aInt64(6, _omitFieldNames ? '' : 'createdAt')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  User clone() => User()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  User copyWith(void Function(User) updates) => super.copyWith((message) => updates(message as User)) as User;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static User create() => User._();
  User createEmptyInstance() => create();
  static $pb.PbList<User> createRepeated() => $pb.PbList<User>();
  @$core.pragma('dart2js:noInline')
  static User getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<User>(create);
  static User? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get id => $_getIZ(0);
  @$pb.TagNumber(1)
  set id($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get email => $_getSZ(2);
  @$pb.TagNumber(3)
  set email($core.String v) { $_setString(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasEmail() => $_has(2);
  @$pb.TagNumber(3)
  void clearEmail() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbList<$core.String> get tags => $_getList(3);

  @$pb.TagNumber(5)
  UserStatus get status => $_getN(4);
  @$pb.TagNumber(5)
  set status(UserStatus v) { $_setField(5, v); }
  @$pb.TagNumber(5)
  $core.bool hasStatus() => $_has(4);
  @$pb.TagNumber(5)
  void clearStatus() => $_clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get createdAt => $_getI64(5);
  @$pb.TagNumber(6)
  set createdAt($fixnum.Int64 v) { $_setInt64(5, v); }
  @$pb.TagNumber(6)
  $core.bool hasCreatedAt() => $_has(5);
  @$pb.TagNumber(6)
  void clearCreatedAt() => $_clearField(6);
}

/// Запрос на получение пользователя
class GetUserRequest extends $pb.GeneratedMessage {
  factory GetUserRequest({
    $core.int? userId,
    $core.bool? includeTags,
  }) {
    final $result = create();
    if (userId != null) {
      $result.userId = userId;
    }
    if (includeTags != null) {
      $result.includeTags = includeTags;
    }
    return $result;
  }
  GetUserRequest._() : super();
  factory GetUserRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory GetUserRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'GetUserRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'userId', $pb.PbFieldType.O3)
    ..aOB(2, _omitFieldNames ? '' : 'includeTags')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserRequest clone() => GetUserRequest()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserRequest copyWith(void Function(GetUserRequest) updates) => super.copyWith((message) => updates(message as GetUserRequest)) as GetUserRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetUserRequest create() => GetUserRequest._();
  GetUserRequest createEmptyInstance() => create();
  static $pb.PbList<GetUserRequest> createRepeated() => $pb.PbList<GetUserRequest>();
  @$core.pragma('dart2js:noInline')
  static GetUserRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetUserRequest>(create);
  static GetUserRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get userId => $_getIZ(0);
  @$pb.TagNumber(1)
  set userId($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get includeTags => $_getBF(1);
  @$pb.TagNumber(2)
  set includeTags($core.bool v) { $_setBool(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasIncludeTags() => $_has(1);
  @$pb.TagNumber(2)
  void clearIncludeTags() => $_clearField(2);
}

/// Ответ с информацией о пользователе
class GetUserResponse extends $pb.GeneratedMessage {
  factory GetUserResponse({
    User? user,
    $core.bool? success,
    $core.String? errorMessage,
  }) {
    final $result = create();
    if (user != null) {
      $result.user = user;
    }
    if (success != null) {
      $result.success = success;
    }
    if (errorMessage != null) {
      $result.errorMessage = errorMessage;
    }
    return $result;
  }
  GetUserResponse._() : super();
  factory GetUserResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory GetUserResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'GetUserResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..aOM<User>(1, _omitFieldNames ? '' : 'user', subBuilder: User.create)
    ..aOB(2, _omitFieldNames ? '' : 'success')
    ..aOS(3, _omitFieldNames ? '' : 'errorMessage', protoName: 'errorMessage')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserResponse clone() => GetUserResponse()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserResponse copyWith(void Function(GetUserResponse) updates) => super.copyWith((message) => updates(message as GetUserResponse)) as GetUserResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GetUserResponse create() => GetUserResponse._();
  GetUserResponse createEmptyInstance() => create();
  static $pb.PbList<GetUserResponse> createRepeated() => $pb.PbList<GetUserResponse>();
  @$core.pragma('dart2js:noInline')
  static GetUserResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetUserResponse>(create);
  static GetUserResponse? _defaultInstance;

  @$pb.TagNumber(1)
  User get user => $_getN(0);
  @$pb.TagNumber(1)
  set user(User v) { $_setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  User ensureUser() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.bool get success => $_getBF(1);
  @$pb.TagNumber(2)
  set success($core.bool v) { $_setBool(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasSuccess() => $_has(1);
  @$pb.TagNumber(2)
  void clearSuccess() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get errorMessage => $_getSZ(2);
  @$pb.TagNumber(3)
  set errorMessage($core.String v) { $_setString(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasErrorMessage() => $_has(2);
  @$pb.TagNumber(3)
  void clearErrorMessage() => $_clearField(3);
}

/// Запрос на создание пользователя
class CreateUserRequest extends $pb.GeneratedMessage {
  factory CreateUserRequest({
    $core.String? name,
    $core.String? email,
    $core.Iterable<$core.String>? tags,
  }) {
    final $result = create();
    if (name != null) {
      $result.name = name;
    }
    if (email != null) {
      $result.email = email;
    }
    if (tags != null) {
      $result.tags.addAll(tags);
    }
    return $result;
  }
  CreateUserRequest._() : super();
  factory CreateUserRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory CreateUserRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateUserRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'email')
    ..pPS(3, _omitFieldNames ? '' : 'tags')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUserRequest clone() => CreateUserRequest()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUserRequest copyWith(void Function(CreateUserRequest) updates) => super.copyWith((message) => updates(message as CreateUserRequest)) as CreateUserRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateUserRequest create() => CreateUserRequest._();
  CreateUserRequest createEmptyInstance() => create();
  static $pb.PbList<CreateUserRequest> createRepeated() => $pb.PbList<CreateUserRequest>();
  @$core.pragma('dart2js:noInline')
  static CreateUserRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateUserRequest>(create);
  static CreateUserRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String v) { $_setString(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get email => $_getSZ(1);
  @$pb.TagNumber(2)
  set email($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasEmail() => $_has(1);
  @$pb.TagNumber(2)
  void clearEmail() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get tags => $_getList(2);
}

/// Ответ на создание пользователя
class CreateUserResponse extends $pb.GeneratedMessage {
  factory CreateUserResponse({
    User? user,
    $core.bool? success,
    $core.String? errorMessage,
  }) {
    final $result = create();
    if (user != null) {
      $result.user = user;
    }
    if (success != null) {
      $result.success = success;
    }
    if (errorMessage != null) {
      $result.errorMessage = errorMessage;
    }
    return $result;
  }
  CreateUserResponse._() : super();
  factory CreateUserResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory CreateUserResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'CreateUserResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..aOM<User>(1, _omitFieldNames ? '' : 'user', subBuilder: User.create)
    ..aOB(2, _omitFieldNames ? '' : 'success')
    ..aOS(3, _omitFieldNames ? '' : 'errorMessage', protoName: 'errorMessage')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUserResponse clone() => CreateUserResponse()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUserResponse copyWith(void Function(CreateUserResponse) updates) => super.copyWith((message) => updates(message as CreateUserResponse)) as CreateUserResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CreateUserResponse create() => CreateUserResponse._();
  CreateUserResponse createEmptyInstance() => create();
  static $pb.PbList<CreateUserResponse> createRepeated() => $pb.PbList<CreateUserResponse>();
  @$core.pragma('dart2js:noInline')
  static CreateUserResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateUserResponse>(create);
  static CreateUserResponse? _defaultInstance;

  @$pb.TagNumber(1)
  User get user => $_getN(0);
  @$pb.TagNumber(1)
  set user(User v) { $_setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  User ensureUser() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.bool get success => $_getBF(1);
  @$pb.TagNumber(2)
  set success($core.bool v) { $_setBool(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasSuccess() => $_has(1);
  @$pb.TagNumber(2)
  void clearSuccess() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get errorMessage => $_getSZ(2);
  @$pb.TagNumber(3)
  set errorMessage($core.String v) { $_setString(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasErrorMessage() => $_has(2);
  @$pb.TagNumber(3)
  void clearErrorMessage() => $_clearField(3);
}

/// Ответ на пакетное создание пользователей (для client streaming)
class BatchCreateUsersResponse extends $pb.GeneratedMessage {
  factory BatchCreateUsersResponse({
    $core.Iterable<User>? users,
    $core.int? totalCreated,
    $core.int? totalErrors,
    $core.Iterable<$core.String>? errorMessages,
    $core.bool? success,
  }) {
    final $result = create();
    if (users != null) {
      $result.users.addAll(users);
    }
    if (totalCreated != null) {
      $result.totalCreated = totalCreated;
    }
    if (totalErrors != null) {
      $result.totalErrors = totalErrors;
    }
    if (errorMessages != null) {
      $result.errorMessages.addAll(errorMessages);
    }
    if (success != null) {
      $result.success = success;
    }
    return $result;
  }
  BatchCreateUsersResponse._() : super();
  factory BatchCreateUsersResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory BatchCreateUsersResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'BatchCreateUsersResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..pc<User>(1, _omitFieldNames ? '' : 'users', $pb.PbFieldType.PM, subBuilder: User.create)
    ..a<$core.int>(2, _omitFieldNames ? '' : 'totalCreated', $pb.PbFieldType.O3, protoName: 'totalCreated')
    ..a<$core.int>(3, _omitFieldNames ? '' : 'totalErrors', $pb.PbFieldType.O3, protoName: 'totalErrors')
    ..pPS(4, _omitFieldNames ? '' : 'errorMessages', protoName: 'errorMessages')
    ..aOB(5, _omitFieldNames ? '' : 'success')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BatchCreateUsersResponse clone() => BatchCreateUsersResponse()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BatchCreateUsersResponse copyWith(void Function(BatchCreateUsersResponse) updates) => super.copyWith((message) => updates(message as BatchCreateUsersResponse)) as BatchCreateUsersResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BatchCreateUsersResponse create() => BatchCreateUsersResponse._();
  BatchCreateUsersResponse createEmptyInstance() => create();
  static $pb.PbList<BatchCreateUsersResponse> createRepeated() => $pb.PbList<BatchCreateUsersResponse>();
  @$core.pragma('dart2js:noInline')
  static BatchCreateUsersResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BatchCreateUsersResponse>(create);
  static BatchCreateUsersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<User> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.int get totalCreated => $_getIZ(1);
  @$pb.TagNumber(2)
  set totalCreated($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasTotalCreated() => $_has(1);
  @$pb.TagNumber(2)
  void clearTotalCreated() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get totalErrors => $_getIZ(2);
  @$pb.TagNumber(3)
  set totalErrors($core.int v) { $_setSignedInt32(2, v); }
  @$pb.TagNumber(3)
  $core.bool hasTotalErrors() => $_has(2);
  @$pb.TagNumber(3)
  void clearTotalErrors() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbList<$core.String> get errorMessages => $_getList(3);

  @$pb.TagNumber(5)
  $core.bool get success => $_getBF(4);
  @$pb.TagNumber(5)
  set success($core.bool v) { $_setBool(4, v); }
  @$pb.TagNumber(5)
  $core.bool hasSuccess() => $_has(4);
  @$pb.TagNumber(5)
  void clearSuccess() => $_clearField(5);
}

/// Запрос на получение списка пользователей (для серверного стрима)
class ListUsersRequest extends $pb.GeneratedMessage {
  factory ListUsersRequest({
    $core.int? limit,
    $core.int? offset,
    UserStatus? statusFilter,
  }) {
    final $result = create();
    if (limit != null) {
      $result.limit = limit;
    }
    if (offset != null) {
      $result.offset = offset;
    }
    if (statusFilter != null) {
      $result.statusFilter = statusFilter;
    }
    return $result;
  }
  ListUsersRequest._() : super();
  factory ListUsersRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ListUsersRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ListUsersRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'limit', $pb.PbFieldType.O3)
    ..a<$core.int>(2, _omitFieldNames ? '' : 'offset', $pb.PbFieldType.O3)
    ..e<UserStatus>(3, _omitFieldNames ? '' : 'statusFilter', $pb.PbFieldType.OE, defaultOrMaker: UserStatus.UNKNOWN, valueOf: UserStatus.valueOf, enumValues: UserStatus.values)
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUsersRequest clone() => ListUsersRequest()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUsersRequest copyWith(void Function(ListUsersRequest) updates) => super.copyWith((message) => updates(message as ListUsersRequest)) as ListUsersRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListUsersRequest create() => ListUsersRequest._();
  ListUsersRequest createEmptyInstance() => create();
  static $pb.PbList<ListUsersRequest> createRepeated() => $pb.PbList<ListUsersRequest>();
  @$core.pragma('dart2js:noInline')
  static ListUsersRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ListUsersRequest>(create);
  static ListUsersRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get limit => $_getIZ(0);
  @$pb.TagNumber(1)
  set limit($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasLimit() => $_has(0);
  @$pb.TagNumber(1)
  void clearLimit() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get offset => $_getIZ(1);
  @$pb.TagNumber(2)
  set offset($core.int v) { $_setSignedInt32(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasOffset() => $_has(1);
  @$pb.TagNumber(2)
  void clearOffset() => $_clearField(2);

  @$pb.TagNumber(3)
  UserStatus get statusFilter => $_getN(2);
  @$pb.TagNumber(3)
  set statusFilter(UserStatus v) { $_setField(3, v); }
  @$pb.TagNumber(3)
  $core.bool hasStatusFilter() => $_has(2);
  @$pb.TagNumber(3)
  void clearStatusFilter() => $_clearField(3);
}

/// Ответ со списком пользователей
class ListUsersResponse extends $pb.GeneratedMessage {
  factory ListUsersResponse({
    $core.Iterable<User>? users,
    $core.bool? hasMore,
  }) {
    final $result = create();
    if (users != null) {
      $result.users.addAll(users);
    }
    if (hasMore != null) {
      $result.hasMore = hasMore;
    }
    return $result;
  }
  ListUsersResponse._() : super();
  factory ListUsersResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory ListUsersResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'ListUsersResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..pc<User>(1, _omitFieldNames ? '' : 'users', $pb.PbFieldType.PM, subBuilder: User.create)
    ..aOB(2, _omitFieldNames ? '' : 'hasMore')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUsersResponse clone() => ListUsersResponse()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUsersResponse copyWith(void Function(ListUsersResponse) updates) => super.copyWith((message) => updates(message as ListUsersResponse)) as ListUsersResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListUsersResponse create() => ListUsersResponse._();
  ListUsersResponse createEmptyInstance() => create();
  static $pb.PbList<ListUsersResponse> createRepeated() => $pb.PbList<ListUsersResponse>();
  @$core.pragma('dart2js:noInline')
  static ListUsersResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ListUsersResponse>(create);
  static ListUsersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<User> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.bool get hasMore => $_getBF(1);
  @$pb.TagNumber(2)
  set hasMore($core.bool v) { $_setBool(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasHasMore() => $_has(1);
  @$pb.TagNumber(2)
  void clearHasMore() => $_clearField(2);
}

/// Запрос для отслеживания пользователей (для двунаправленного стрима)
class WatchUsersRequest extends $pb.GeneratedMessage {
  factory WatchUsersRequest({
    $core.Iterable<$core.int>? userIds,
    $core.Iterable<$core.String>? eventTypes,
  }) {
    final $result = create();
    if (userIds != null) {
      $result.userIds.addAll(userIds);
    }
    if (eventTypes != null) {
      $result.eventTypes.addAll(eventTypes);
    }
    return $result;
  }
  WatchUsersRequest._() : super();
  factory WatchUsersRequest.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory WatchUsersRequest.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'WatchUsersRequest', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..p<$core.int>(1, _omitFieldNames ? '' : 'userIds', $pb.PbFieldType.K3)
    ..pPS(2, _omitFieldNames ? '' : 'eventTypes')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WatchUsersRequest clone() => WatchUsersRequest()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WatchUsersRequest copyWith(void Function(WatchUsersRequest) updates) => super.copyWith((message) => updates(message as WatchUsersRequest)) as WatchUsersRequest;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static WatchUsersRequest create() => WatchUsersRequest._();
  WatchUsersRequest createEmptyInstance() => create();
  static $pb.PbList<WatchUsersRequest> createRepeated() => $pb.PbList<WatchUsersRequest>();
  @$core.pragma('dart2js:noInline')
  static WatchUsersRequest getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<WatchUsersRequest>(create);
  static WatchUsersRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.int> get userIds => $_getList(0);

  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get eventTypes => $_getList(1);
}

/// События пользователей
class UserEvent extends $pb.GeneratedMessage {
  factory UserEvent({
    $core.int? userId,
    $core.String? eventType,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? data,
    $fixnum.Int64? timestamp,
  }) {
    final $result = create();
    if (userId != null) {
      $result.userId = userId;
    }
    if (eventType != null) {
      $result.eventType = eventType;
    }
    if (data != null) {
      $result.data.addEntries(data);
    }
    if (timestamp != null) {
      $result.timestamp = timestamp;
    }
    return $result;
  }
  UserEvent._() : super();
  factory UserEvent.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory UserEvent.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'UserEvent', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'userId', $pb.PbFieldType.O3)
    ..aOS(2, _omitFieldNames ? '' : 'eventType')
    ..m<$core.String, $core.String>(3, _omitFieldNames ? '' : 'data', entryClassName: 'UserEvent.DataEntry', keyFieldType: $pb.PbFieldType.OS, valueFieldType: $pb.PbFieldType.OS, packageName: const $pb.PackageName('user_service'))
    ..aInt64(4, _omitFieldNames ? '' : 'timestamp')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserEvent clone() => UserEvent()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserEvent copyWith(void Function(UserEvent) updates) => super.copyWith((message) => updates(message as UserEvent)) as UserEvent;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UserEvent create() => UserEvent._();
  UserEvent createEmptyInstance() => create();
  static $pb.PbList<UserEvent> createRepeated() => $pb.PbList<UserEvent>();
  @$core.pragma('dart2js:noInline')
  static UserEvent getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UserEvent>(create);
  static UserEvent? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get userId => $_getIZ(0);
  @$pb.TagNumber(1)
  set userId($core.int v) { $_setSignedInt32(0, v); }
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get eventType => $_getSZ(1);
  @$pb.TagNumber(2)
  set eventType($core.String v) { $_setString(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasEventType() => $_has(1);
  @$pb.TagNumber(2)
  void clearEventType() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbMap<$core.String, $core.String> get data => $_getMap(2);

  @$pb.TagNumber(4)
  $fixnum.Int64 get timestamp => $_getI64(3);
  @$pb.TagNumber(4)
  set timestamp($fixnum.Int64 v) { $_setInt64(3, v); }
  @$pb.TagNumber(4)
  $core.bool hasTimestamp() => $_has(3);
  @$pb.TagNumber(4)
  void clearTimestamp() => $_clearField(4);
}

/// Ответ с событием пользователя
class UserEventResponse extends $pb.GeneratedMessage {
  factory UserEventResponse({
    UserEvent? event,
    $core.bool? success,
  }) {
    final $result = create();
    if (event != null) {
      $result.event = event;
    }
    if (success != null) {
      $result.success = success;
    }
    return $result;
  }
  UserEventResponse._() : super();
  factory UserEventResponse.fromBuffer($core.List<$core.int> i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromBuffer(i, r);
  factory UserEventResponse.fromJson($core.String i, [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) => create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(_omitMessageNames ? '' : 'UserEventResponse', package: const $pb.PackageName(_omitMessageNames ? '' : 'user_service'), createEmptyInstance: create)
    ..aOM<UserEvent>(1, _omitFieldNames ? '' : 'event', subBuilder: UserEvent.create)
    ..aOB(2, _omitFieldNames ? '' : 'success')
    ..hasRequiredFields = false
  ;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserEventResponse clone() => UserEventResponse()..mergeFromMessage(this);
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserEventResponse copyWith(void Function(UserEventResponse) updates) => super.copyWith((message) => updates(message as UserEventResponse)) as UserEventResponse;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static UserEventResponse create() => UserEventResponse._();
  UserEventResponse createEmptyInstance() => create();
  static $pb.PbList<UserEventResponse> createRepeated() => $pb.PbList<UserEventResponse>();
  @$core.pragma('dart2js:noInline')
  static UserEventResponse getDefault() => _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UserEventResponse>(create);
  static UserEventResponse? _defaultInstance;

  @$pb.TagNumber(1)
  UserEvent get event => $_getN(0);
  @$pb.TagNumber(1)
  set event(UserEvent v) { $_setField(1, v); }
  @$pb.TagNumber(1)
  $core.bool hasEvent() => $_has(0);
  @$pb.TagNumber(1)
  void clearEvent() => $_clearField(1);
  @$pb.TagNumber(1)
  UserEvent ensureEvent() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.bool get success => $_getBF(1);
  @$pb.TagNumber(2)
  set success($core.bool v) { $_setBool(1, v); }
  @$pb.TagNumber(2)
  $core.bool hasSuccess() => $_has(1);
  @$pb.TagNumber(2)
  void clearSuccess() => $_clearField(2);
}


const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames = $core.bool.fromEnvironment('protobuf.omit_message_names');
