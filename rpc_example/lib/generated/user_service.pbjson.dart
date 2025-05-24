//
//  Generated code. Do not modify.
//  source: user_service.proto
//
// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use userStatusDescriptor instead')
const UserStatus$json = {
  '1': 'UserStatus',
  '2': [
    {'1': 'UNKNOWN', '2': 0},
    {'1': 'ACTIVE', '2': 1},
    {'1': 'INACTIVE', '2': 2},
    {'1': 'BANNED', '2': 3},
  ],
};

/// Descriptor for `UserStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List userStatusDescriptor = $convert.base64Decode(
    'CgpVc2VyU3RhdHVzEgsKB1VOS05PV04QABIKCgZBQ1RJVkUQARIMCghJTkFDVElWRRACEgoKBk'
    'JBTk5FRBAD');

@$core.Deprecated('Use userDescriptor instead')
const User$json = {
  '1': 'User',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 5, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'email', '3': 3, '4': 1, '5': 9, '10': 'email'},
    {'1': 'tags', '3': 4, '4': 3, '5': 9, '10': 'tags'},
    {'1': 'status', '3': 5, '4': 1, '5': 14, '6': '.user_service.UserStatus', '10': 'status'},
    {'1': 'created_at', '3': 6, '4': 1, '5': 3, '10': 'createdAt'},
  ],
};

/// Descriptor for `User`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List userDescriptor = $convert.base64Decode(
    'CgRVc2VyEg4KAmlkGAEgASgFUgJpZBISCgRuYW1lGAIgASgJUgRuYW1lEhQKBWVtYWlsGAMgAS'
    'gJUgVlbWFpbBISCgR0YWdzGAQgAygJUgR0YWdzEjAKBnN0YXR1cxgFIAEoDjIYLnVzZXJfc2Vy'
    'dmljZS5Vc2VyU3RhdHVzUgZzdGF0dXMSHQoKY3JlYXRlZF9hdBgGIAEoA1IJY3JlYXRlZEF0');

@$core.Deprecated('Use getUserRequestDescriptor instead')
const GetUserRequest$json = {
  '1': 'GetUserRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 5, '10': 'userId'},
    {'1': 'include_tags', '3': 2, '4': 1, '5': 8, '10': 'includeTags'},
  ],
};

/// Descriptor for `GetUserRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserRequestDescriptor = $convert.base64Decode(
    'Cg5HZXRVc2VyUmVxdWVzdBIXCgd1c2VyX2lkGAEgASgFUgZ1c2VySWQSIQoMaW5jbHVkZV90YW'
    'dzGAIgASgIUgtpbmNsdWRlVGFncw==');

@$core.Deprecated('Use getUserResponseDescriptor instead')
const GetUserResponse$json = {
  '1': 'GetUserResponse',
  '2': [
    {'1': 'user', '3': 1, '4': 1, '5': 11, '6': '.user_service.User', '10': 'user'},
    {'1': 'success', '3': 2, '4': 1, '5': 8, '10': 'success'},
    {'1': 'errorMessage', '3': 3, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `GetUserResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserResponseDescriptor = $convert.base64Decode(
    'Cg9HZXRVc2VyUmVzcG9uc2USJgoEdXNlchgBIAEoCzISLnVzZXJfc2VydmljZS5Vc2VyUgR1c2'
    'VyEhgKB3N1Y2Nlc3MYAiABKAhSB3N1Y2Nlc3MSIgoMZXJyb3JNZXNzYWdlGAMgASgJUgxlcnJv'
    'ck1lc3NhZ2U=');

@$core.Deprecated('Use createUserRequestDescriptor instead')
const CreateUserRequest$json = {
  '1': 'CreateUserRequest',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'email', '3': 2, '4': 1, '5': 9, '10': 'email'},
    {'1': 'tags', '3': 3, '4': 3, '5': 9, '10': 'tags'},
  ],
};

/// Descriptor for `CreateUserRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createUserRequestDescriptor = $convert.base64Decode(
    'ChFDcmVhdGVVc2VyUmVxdWVzdBISCgRuYW1lGAEgASgJUgRuYW1lEhQKBWVtYWlsGAIgASgJUg'
    'VlbWFpbBISCgR0YWdzGAMgAygJUgR0YWdz');

@$core.Deprecated('Use createUserResponseDescriptor instead')
const CreateUserResponse$json = {
  '1': 'CreateUserResponse',
  '2': [
    {'1': 'user', '3': 1, '4': 1, '5': 11, '6': '.user_service.User', '10': 'user'},
    {'1': 'success', '3': 2, '4': 1, '5': 8, '10': 'success'},
    {'1': 'errorMessage', '3': 3, '4': 1, '5': 9, '10': 'errorMessage'},
  ],
};

/// Descriptor for `CreateUserResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createUserResponseDescriptor = $convert.base64Decode(
    'ChJDcmVhdGVVc2VyUmVzcG9uc2USJgoEdXNlchgBIAEoCzISLnVzZXJfc2VydmljZS5Vc2VyUg'
    'R1c2VyEhgKB3N1Y2Nlc3MYAiABKAhSB3N1Y2Nlc3MSIgoMZXJyb3JNZXNzYWdlGAMgASgJUgxl'
    'cnJvck1lc3NhZ2U=');

@$core.Deprecated('Use batchCreateUsersResponseDescriptor instead')
const BatchCreateUsersResponse$json = {
  '1': 'BatchCreateUsersResponse',
  '2': [
    {'1': 'users', '3': 1, '4': 3, '5': 11, '6': '.user_service.User', '10': 'users'},
    {'1': 'totalCreated', '3': 2, '4': 1, '5': 5, '10': 'totalCreated'},
    {'1': 'totalErrors', '3': 3, '4': 1, '5': 5, '10': 'totalErrors'},
    {'1': 'errorMessages', '3': 4, '4': 3, '5': 9, '10': 'errorMessages'},
    {'1': 'success', '3': 5, '4': 1, '5': 8, '10': 'success'},
  ],
};

/// Descriptor for `BatchCreateUsersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List batchCreateUsersResponseDescriptor = $convert.base64Decode(
    'ChhCYXRjaENyZWF0ZVVzZXJzUmVzcG9uc2USKAoFdXNlcnMYASADKAsyEi51c2VyX3NlcnZpY2'
    'UuVXNlclIFdXNlcnMSIgoMdG90YWxDcmVhdGVkGAIgASgFUgx0b3RhbENyZWF0ZWQSIAoLdG90'
    'YWxFcnJvcnMYAyABKAVSC3RvdGFsRXJyb3JzEiQKDWVycm9yTWVzc2FnZXMYBCADKAlSDWVycm'
    '9yTWVzc2FnZXMSGAoHc3VjY2VzcxgFIAEoCFIHc3VjY2Vzcw==');

@$core.Deprecated('Use listUsersRequestDescriptor instead')
const ListUsersRequest$json = {
  '1': 'ListUsersRequest',
  '2': [
    {'1': 'limit', '3': 1, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'offset', '3': 2, '4': 1, '5': 5, '10': 'offset'},
    {'1': 'status_filter', '3': 3, '4': 1, '5': 14, '6': '.user_service.UserStatus', '10': 'statusFilter'},
  ],
};

/// Descriptor for `ListUsersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listUsersRequestDescriptor = $convert.base64Decode(
    'ChBMaXN0VXNlcnNSZXF1ZXN0EhQKBWxpbWl0GAEgASgFUgVsaW1pdBIWCgZvZmZzZXQYAiABKA'
    'VSBm9mZnNldBI9Cg1zdGF0dXNfZmlsdGVyGAMgASgOMhgudXNlcl9zZXJ2aWNlLlVzZXJTdGF0'
    'dXNSDHN0YXR1c0ZpbHRlcg==');

@$core.Deprecated('Use listUsersResponseDescriptor instead')
const ListUsersResponse$json = {
  '1': 'ListUsersResponse',
  '2': [
    {'1': 'users', '3': 1, '4': 3, '5': 11, '6': '.user_service.User', '10': 'users'},
    {'1': 'has_more', '3': 2, '4': 1, '5': 8, '10': 'hasMore'},
  ],
};

/// Descriptor for `ListUsersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listUsersResponseDescriptor = $convert.base64Decode(
    'ChFMaXN0VXNlcnNSZXNwb25zZRIoCgV1c2VycxgBIAMoCzISLnVzZXJfc2VydmljZS5Vc2VyUg'
    'V1c2VycxIZCghoYXNfbW9yZRgCIAEoCFIHaGFzTW9yZQ==');

@$core.Deprecated('Use watchUsersRequestDescriptor instead')
const WatchUsersRequest$json = {
  '1': 'WatchUsersRequest',
  '2': [
    {'1': 'user_ids', '3': 1, '4': 3, '5': 5, '10': 'userIds'},
    {'1': 'event_types', '3': 2, '4': 3, '5': 9, '10': 'eventTypes'},
  ],
};

/// Descriptor for `WatchUsersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List watchUsersRequestDescriptor = $convert.base64Decode(
    'ChFXYXRjaFVzZXJzUmVxdWVzdBIZCgh1c2VyX2lkcxgBIAMoBVIHdXNlcklkcxIfCgtldmVudF'
    '90eXBlcxgCIAMoCVIKZXZlbnRUeXBlcw==');

@$core.Deprecated('Use userEventDescriptor instead')
const UserEvent$json = {
  '1': 'UserEvent',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 5, '10': 'userId'},
    {'1': 'event_type', '3': 2, '4': 1, '5': 9, '10': 'eventType'},
    {'1': 'data', '3': 3, '4': 3, '5': 11, '6': '.user_service.UserEvent.DataEntry', '10': 'data'},
    {'1': 'timestamp', '3': 4, '4': 1, '5': 3, '10': 'timestamp'},
  ],
  '3': [UserEvent_DataEntry$json],
};

@$core.Deprecated('Use userEventDescriptor instead')
const UserEvent_DataEntry$json = {
  '1': 'DataEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `UserEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List userEventDescriptor = $convert.base64Decode(
    'CglVc2VyRXZlbnQSFwoHdXNlcl9pZBgBIAEoBVIGdXNlcklkEh0KCmV2ZW50X3R5cGUYAiABKA'
    'lSCWV2ZW50VHlwZRI1CgRkYXRhGAMgAygLMiEudXNlcl9zZXJ2aWNlLlVzZXJFdmVudC5EYXRh'
    'RW50cnlSBGRhdGESHAoJdGltZXN0YW1wGAQgASgDUgl0aW1lc3RhbXAaNwoJRGF0YUVudHJ5Eh'
    'AKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use userEventResponseDescriptor instead')
const UserEventResponse$json = {
  '1': 'UserEventResponse',
  '2': [
    {'1': 'event', '3': 1, '4': 1, '5': 11, '6': '.user_service.UserEvent', '10': 'event'},
    {'1': 'success', '3': 2, '4': 1, '5': 8, '10': 'success'},
  ],
};

/// Descriptor for `UserEventResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List userEventResponseDescriptor = $convert.base64Decode(
    'ChFVc2VyRXZlbnRSZXNwb25zZRItCgVldmVudBgBIAEoCzIXLnVzZXJfc2VydmljZS5Vc2VyRX'
    'ZlbnRSBWV2ZW50EhgKB3N1Y2Nlc3MYAiABKAhSB3N1Y2Nlc3M=');

