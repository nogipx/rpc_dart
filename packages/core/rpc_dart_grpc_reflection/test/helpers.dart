// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:convert' as $convert;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Proto encoding helpers (minimal, no dependency on ProtoWriter)
// ---------------------------------------------------------------------------

/// Encodes a non-negative integer as a protobuf varint.
List<int> encodeVarint(int value) {
  final bytes = <int>[];
  while (value > 0x7F) {
    bytes.add((value & 0x7F) | 0x80);
    value >>= 7;
  }
  bytes.add(value & 0x7F);
  return bytes;
}

List<int> _encodeTag(int fieldNumber, int wireType) =>
    encodeVarint((fieldNumber << 3) | wireType);

List<int> _encodeString(int fieldNumber, String value) {
  if (value.isEmpty) return [];
  final encoded = utf8.encode(value);
  return [
    ..._encodeTag(fieldNumber, 2),
    ...encodeVarint(encoded.length),
    ...encoded,
  ];
}

List<int> _encodeBytes(int fieldNumber, List<int> value) {
  if (value.isEmpty) return [];
  return [
    ..._encodeTag(fieldNumber, 2),
    ...encodeVarint(value.length),
    ...value,
  ];
}

// ---------------------------------------------------------------------------
// FileDescriptorProto builders
// ---------------------------------------------------------------------------

/// Builds a minimal `FileDescriptorProto` with the given services.
Uint8List buildMinimalFileDescriptor({
  required String name,
  required String package,
  required List<String> serviceNames,
  List<String> dependencies = const [],
}) => buildMinimalFileDescriptorWithMessages(
  name: name,
  package: package,
  messageNames: [],
  serviceNames: serviceNames,
  dependencies: dependencies,
);

/// Builds a `FileDescriptorProto` with messages and services.
Uint8List buildMinimalFileDescriptorWithMessages({
  required String name,
  required String package,
  required List<String> messageNames,
  required List<String> serviceNames,
  List<String> dependencies = const [],
  List<String> enumNames = const [],
}) {
  final buf = <int>[];
  buf.addAll(_encodeString(1, name));
  buf.addAll(_encodeString(2, package));

  for (final dep in dependencies) {
    buf.addAll(_encodeString(3, dep));
  }

  for (final msgName in messageNames) {
    final msgBuf = _encodeString(1, msgName);
    buf.addAll(_encodeBytes(4, msgBuf));
  }

  for (final enumName in enumNames) {
    final enumBuf = _encodeString(1, enumName);
    buf.addAll(_encodeBytes(5, enumBuf));
  }

  for (final svcName in serviceNames) {
    final svcBuf = _encodeString(1, svcName);
    buf.addAll(_encodeBytes(6, svcBuf));
  }

  return Uint8List.fromList(buf);
}

/// Builds a `FileDescriptorProto` with a message that has nested types and enums.
///
/// [outerName] — top-level message name
/// [nestedMessageNames] — nested message names inside [outerName]
/// [nestedEnumNames] — enum names inside [outerName]
Uint8List buildDescriptorWithNesting({
  required String name,
  required String package,
  required String outerName,
  List<String> nestedMessageNames = const [],
  List<String> nestedEnumNames = const [],
  List<String> serviceNames = const [],
}) {
  // Build inner nested messages
  final outerBuf = <int>[];
  outerBuf.addAll(_encodeString(1, outerName));

  for (final nm in nestedMessageNames) {
    final nestedBuf = _encodeString(1, nm);
    outerBuf.addAll(_encodeBytes(3, nestedBuf)); // nested_type = field 3
  }

  for (final en in nestedEnumNames) {
    final enumBuf = _encodeString(1, en);
    outerBuf.addAll(_encodeBytes(4, enumBuf)); // enum_type = field 4
  }

  final buf = <int>[];
  buf.addAll(_encodeString(1, name));
  buf.addAll(_encodeString(2, package));
  buf.addAll(_encodeBytes(4, outerBuf)); // message_type = field 4

  for (final svcName in serviceNames) {
    final svcBuf = _encodeString(1, svcName);
    buf.addAll(_encodeBytes(6, svcBuf));
  }

  return Uint8List.fromList(buf);
}

/// Builds a `FileDescriptorSet` containing multiple `FileDescriptorProto` entries.
Uint8List buildMinimalFileDescriptorSet(
  List<(String name, String package, List<String> services)> files,
) {
  final buf = <int>[];
  for (final (name, package, services) in files) {
    final fd = buildMinimalFileDescriptor(
      name: name,
      package: package,
      serviceNames: services,
    );
    buf.addAll(_encodeBytes(1, fd));
  }
  return Uint8List.fromList(buf);
}

// ---------------------------------------------------------------------------
// Request builders (ServerReflectionRequest wire format)
// ---------------------------------------------------------------------------

/// list_services request: field 7, any non-empty string.
Uint8List listServicesRequest() => Uint8List.fromList(_encodeString(7, '*'));

/// file_by_filename request: field 3 = filename string.
Uint8List fileByFilenameRequest(String filename) =>
    Uint8List.fromList(_encodeString(3, filename));

/// file_containing_symbol request: field 4 = symbol string.
Uint8List fileContainingSymbolRequest(String symbol) =>
    Uint8List.fromList(_encodeString(4, symbol));

// ---------------------------------------------------------------------------
// Response parsers (ServerReflectionResponse wire format)
// ---------------------------------------------------------------------------

class ErrorResult {
  final int code;
  final String message;
  ErrorResult(this.code, this.message);
}

/// Parses field 6 (list_services_response) → repeated service names.
List<String> parseListServicesResponse(Uint8List bytes) {
  final outer = _parseFields(bytes);
  final listSvcBytes = outer[6];
  if (listSvcBytes == null) return [];

  final services = <String>[];
  for (final svcBytes in _parseRepeatedBytes(
    Uint8List.fromList(listSvcBytes),
    1,
  )) {
    final svcFields = _parseFields(Uint8List.fromList(svcBytes));
    final nameBytes = svcFields[1];
    if (nameBytes != null) services.add(utf8.decode(nameBytes));
  }
  return services;
}

/// Returns true if field 4 (file_descriptor_response) is present.
bool isFileDescriptorResponse(Uint8List bytes) =>
    _parseFields(bytes).containsKey(4);

/// Extracts all file_descriptor_proto byte payloads (field 4 → repeated field 1).
List<Uint8List> extractAllFileDescriptorBytes(Uint8List bytes) {
  final outer = _parseFields(bytes);
  final fdRespBytes = outer[4];
  if (fdRespBytes == null) return [];
  return _parseRepeatedBytes(
    Uint8List.fromList(fdRespBytes),
    1,
  ).map((b) => Uint8List.fromList(b)).toList();
}

/// Returns true if field 2 (original_request) is present.
bool hasOriginalRequest(Uint8List bytes) => _parseFields(bytes).containsKey(2);

/// Parses field 7 (error_response). Returns null if not an error response.
ErrorResult? parseErrorResponse(Uint8List bytes) {
  final outer = _parseFields(bytes);
  final errBytes = outer[7];
  if (errBytes == null) return null;
  final inner = _parseFields(Uint8List.fromList(errBytes));
  final codeBytes = inner[1];
  final msgBytes = inner[2];
  final code = codeBytes != null ? _decodeVarint(codeBytes) : 0;
  final message = msgBytes != null ? utf8.decode(msgBytes) : '';
  return ErrorResult(code, message);
}

// ---------------------------------------------------------------------------
// Minimal proto decoder (for tests only)
// ---------------------------------------------------------------------------

/// Parses the first occurrence of each field number → raw value bytes.
/// Wire type 0 (varint): stores raw varint bytes.
/// Wire type 2 (LEN): stores the payload bytes.
Map<int, List<int>> _parseFields(Uint8List bytes) {
  final result = <int, List<int>>{};
  var pos = 0;

  while (pos < bytes.length) {
    var tag = 0;
    var shift = 0;
    while (pos < bytes.length) {
      final b = bytes[pos++];
      tag |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    if (wireType == 0) {
      final start = pos;
      while (pos < bytes.length && bytes[pos] & 0x80 != 0) pos++;
      if (pos < bytes.length) pos++;
      result.putIfAbsent(fieldNumber, () => bytes.sublist(start, pos).toList());
    } else if (wireType == 2) {
      var len = 0;
      shift = 0;
      while (pos < bytes.length) {
        final b = bytes[pos++];
        len |= (b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
      }
      if (pos + len > bytes.length) break;
      result.putIfAbsent(
        fieldNumber,
        () => bytes.sublist(pos, pos + len).toList(),
      );
      pos += len;
    } else if (wireType == 1) {
      pos += 8;
    } else if (wireType == 5) {
      pos += 4;
    } else {
      break;
    }
  }
  return result;
}

/// Parses all repeated LEN fields with the given field number.
List<List<int>> _parseRepeatedBytes(Uint8List bytes, int targetField) {
  final result = <List<int>>[];
  var pos = 0;

  while (pos < bytes.length) {
    var tag = 0;
    var shift = 0;
    while (pos < bytes.length) {
      final b = bytes[pos++];
      tag |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    if (wireType == 0) {
      while (pos < bytes.length && bytes[pos] & 0x80 != 0) pos++;
      if (pos < bytes.length) pos++;
    } else if (wireType == 2) {
      var len = 0;
      shift = 0;
      while (pos < bytes.length) {
        final b = bytes[pos++];
        len |= (b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
      }
      if (pos + len > bytes.length) break;
      if (fieldNumber == targetField) {
        result.add(bytes.sublist(pos, pos + len).toList());
      }
      pos += len;
    } else if (wireType == 1) {
      pos += 8;
    } else if (wireType == 5) {
      pos += 4;
    } else {
      break;
    }
  }
  return result;
}

int _decodeVarint(List<int> bytes) {
  var result = 0;
  var shift = 0;
  for (final b in bytes) {
    result |= (b & 0x7F) << shift;
    if (b & 0x80 == 0) break;
    shift += 7;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Real protobuf descriptor bytes (from example/gen/echo.pbjson.dart)
// ---------------------------------------------------------------------------

final Uint8List echoRequestDescriptor = $convert.base64Decode(
  'CgtFY2hvUmVxdWVzdBIYCgdtZXNzYWdlGAEgASgJUgdtZXNzYWdlEhQKBWNvdW50GAIgASgFUg'
  'Vjb3VudA==',
);

final Uint8List echoResponseDescriptor = $convert.base64Decode(
  'CgxFY2hvUmVzcG9uc2USGAoHbWVzc2FnZRgBIAEoCVIHbWVzc2FnZRIUCgVpbmRleBgCIAEoBV'
  'IFaW5kZXg=',
);

final Uint8List echoServiceDescriptor = $convert.base64Decode(
  'CgtFY2hvU2VydmljZRIzCgRFY2hvEhQuZWNoby52MS5FY2hvUmVxdWVzdBoVLmVjaG8udjEuRW'
  'Nob1Jlc3BvbnNlEjsKCkVjaG9TdHJlYW0SFC5lY2hvLnYxLkVjaG9SZXF1ZXN0GhUuZWNoby52'
  'MS5FY2hvUmVzcG9uc2UwAQ==',
);

/// Builds a FileDescriptorProto for echo.proto from real pbjson descriptors.
Uint8List echoFileDescriptorBytes() {
  final buf = <int>[];
  buf.addAll(_encodeString(1, 'echo.proto'));
  buf.addAll(_encodeString(2, 'echo.v1'));
  buf.addAll(_encodeBytes(4, echoRequestDescriptor));
  buf.addAll(_encodeBytes(4, echoResponseDescriptor));
  buf.addAll(_encodeBytes(6, echoServiceDescriptor));
  return Uint8List.fromList(buf);
}
