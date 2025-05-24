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

import 'package:protobuf/protobuf.dart' as $pb;

/// Статус пользователя
class UserStatus extends $pb.ProtobufEnum {
  static const UserStatus UNKNOWN = UserStatus._(0, _omitEnumNames ? '' : 'UNKNOWN');
  static const UserStatus ACTIVE = UserStatus._(1, _omitEnumNames ? '' : 'ACTIVE');
  static const UserStatus INACTIVE = UserStatus._(2, _omitEnumNames ? '' : 'INACTIVE');
  static const UserStatus BANNED = UserStatus._(3, _omitEnumNames ? '' : 'BANNED');

  static const $core.List<UserStatus> values = <UserStatus> [
    UNKNOWN,
    ACTIVE,
    INACTIVE,
    BANNED,
  ];

  static final $core.List<UserStatus?> _byValue = $pb.ProtobufEnum.$_initByValueList(values, 3);
  static UserStatus? valueOf($core.int value) =>  value < 0 || value >= _byValue.length ? null : _byValue[value];

  const UserStatus._(super.v, super.n);
}


const _omitEnumNames = $core.bool.fromEnvironment('protobuf.omit_enum_names');
