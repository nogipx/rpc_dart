// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

// Minimal protobuf binary parser — only the fields needed for gRPC reflection.
//
// Wire types:
//   0 = VARINT
//   1 = I64
//   2 = LEN (length-delimited)
//   5 = I32

const int _wireVarint = 0;
const int _wireI64 = 1;
const int _wireLen = 2;
const int _wireI32 = 5;

/// Parsed representation of a FileDescriptorProto (only fields used for reflection).
class ParsedFileDescriptor {
  final String name;
  final String package;
  final List<String> services;
  final List<String> messageTypes;
  final Uint8List rawBytes;

  const ParsedFileDescriptor({
    required this.name,
    required this.package,
    required this.services,
    required this.messageTypes,
    required this.rawBytes,
  });
}

/// Parses a single serialized FileDescriptorProto.
ParsedFileDescriptor parseFileDescriptorProto(Uint8List bytes) =>
    _parseFileDescriptorProto(bytes);

/// Parses a serialized FileDescriptorSet and returns all contained FileDescriptorProtos.
List<ParsedFileDescriptor> parseFileDescriptorSet(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  final result = <ParsedFileDescriptor>[];

  while (reader.hasMore) {
    final tag = reader.readTag();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    if (fieldNumber == 1 && wireType == _wireLen) {
      // repeated FileDescriptorProto file = 1
      final fileBytes = reader.readLenDelimited();
      result.add(_parseFileDescriptorProto(fileBytes));
    } else {
      reader.skipField(wireType);
    }
  }

  return result;
}

ParsedFileDescriptor _parseFileDescriptorProto(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var name = '';
  var package = '';
  final services = <String>[];
  final messageTypes = <String>[];

  while (reader.hasMore) {
    final tag = reader.readTag();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 1 when wireType == _wireLen:
        // string name = 1
        name = utf8.decode(reader.readLenDelimited());
      case 2 when wireType == _wireLen:
        // string package = 2
        package = utf8.decode(reader.readLenDelimited());
      case 4 when wireType == _wireLen:
        // repeated DescriptorProto message_type = 4
        final msgBytes = reader.readLenDelimited();
        final msgName = _parseNameField(msgBytes);
        if (msgName.isNotEmpty) messageTypes.add(msgName);
      case 6 when wireType == _wireLen:
        // repeated ServiceDescriptorProto service = 6
        final svcBytes = reader.readLenDelimited();
        final svcName = _parseNameField(svcBytes);
        if (svcName.isNotEmpty) services.add(svcName);
      default:
        reader.skipField(wireType);
    }
  }

  return ParsedFileDescriptor(
    name: name,
    package: package,
    services: services,
    messageTypes: messageTypes,
    rawBytes: bytes,
  );
}

/// Reads field 1 (string name) from a proto message — used for Service/Message descriptors.
String _parseNameField(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  while (reader.hasMore) {
    final tag = reader.readTag();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;
    if (fieldNumber == 1 && wireType == _wireLen) {
      return utf8.decode(reader.readLenDelimited());
    }
    reader.skipField(wireType);
  }
  return '';
}

class _ProtoReader {
  final Uint8List _bytes;
  int _pos = 0;

  _ProtoReader(this._bytes);

  bool get hasMore => _pos < _bytes.length;

  int readTag() => readVarint();

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    return result;
  }

  Uint8List readLenDelimited() {
    final length = readVarint();
    final data = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return data;
  }

  void skipField(int wireType) {
    switch (wireType) {
      case _wireVarint:
        readVarint();
      case _wireI64:
        _pos += 8;
      case _wireLen:
        final length = readVarint();
        _pos += length;
      case _wireI32:
        _pos += 4;
      default:
        throw StateError('Unknown wire type: $wireType at pos $_pos');
    }
  }
}
