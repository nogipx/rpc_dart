// This is a generated file - do not edit.
//
// Generated from echo.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use echoRequestDescriptor instead')
const EchoRequest$json = {
  '1': 'EchoRequest',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
    {'1': 'count', '3': 2, '4': 1, '5': 5, '10': 'count'},
  ],
};

/// Descriptor for `EchoRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List echoRequestDescriptor = $convert.base64Decode(
    'CgtFY2hvUmVxdWVzdBIYCgdtZXNzYWdlGAEgASgJUgdtZXNzYWdlEhQKBWNvdW50GAIgASgFUg'
    'Vjb3VudA==');

@$core.Deprecated('Use echoResponseDescriptor instead')
const EchoResponse$json = {
  '1': 'EchoResponse',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
    {'1': 'index', '3': 2, '4': 1, '5': 5, '10': 'index'},
  ],
};

/// Descriptor for `EchoResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List echoResponseDescriptor = $convert.base64Decode(
    'CgxFY2hvUmVzcG9uc2USGAoHbWVzc2FnZRgBIAEoCVIHbWVzc2FnZRIUCgVpbmRleBgCIAEoBV'
    'IFaW5kZXg=');

const $core.Map<$core.String, $core.dynamic> EchoServiceBase$json = {
  '1': 'EchoService',
  '2': [
    {'1': 'Echo', '2': '.echo.v1.EchoRequest', '3': '.echo.v1.EchoResponse'},
    {
      '1': 'EchoStream',
      '2': '.echo.v1.EchoRequest',
      '3': '.echo.v1.EchoResponse',
      '6': true
    },
  ],
};

@$core.Deprecated('Use echoServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    EchoServiceBase$messageJson = {
  '.echo.v1.EchoRequest': EchoRequest$json,
  '.echo.v1.EchoResponse': EchoResponse$json,
};

/// Descriptor for `EchoService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List echoServiceDescriptor = $convert.base64Decode(
    'CgtFY2hvU2VydmljZRIzCgRFY2hvEhQuZWNoby52MS5FY2hvUmVxdWVzdBoVLmVjaG8udjEuRW'
    'Nob1Jlc3BvbnNlEjsKCkVjaG9TdHJlYW0SFC5lY2hvLnYxLkVjaG9SZXF1ZXN0GhUuZWNoby52'
    'MS5FY2hvUmVzcG9uc2UwAQ==');
