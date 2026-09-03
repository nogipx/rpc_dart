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
//
// FileDescriptorProto fields parsed:
//   1  = name (string)
//   2  = package (string)
//   3  = dependency (repeated string)
//   4  = message_type (repeated DescriptorProto)
//   5  = enum_type (repeated EnumDescriptorProto)
//   6  = service (repeated ServiceDescriptorProto)
//
// DescriptorProto fields parsed (recursive):
//   1  = name (string)
//   3  = nested_type (repeated DescriptorProto)
//   4  = enum_type (repeated EnumDescriptorProto)

const int _wireVarint = 0;
const int _wireI64 = 1;
const int _wireLen = 2;
const int _wireI32 = 5;

/// Parsed representation of a FileDescriptorProto (fields used for reflection).
class ParsedFileDescriptor {
  final String name;
  final String package;

  /// Proto import paths, e.g. `['google/protobuf/timestamp.proto']`.
  final List<String> dependencies;

  final List<String> services;

  /// Method names per service, relative to the package —
  /// e.g. `{'EchoService': ['Echo', 'EchoStream']}`.
  ///
  /// Carried so a fully-qualified METHOD can be indexed for
  /// `file_containing_symbol`, which the reflection proto documents as
  /// accepting `<package>.<service>[.<method>]`. Defaulted rather than
  /// required, so adding it does not break an existing construction.
  final Map<String, List<String>> serviceMethods;

  /// All message type names including nested, relative to package.
  /// e.g. `['Outer', 'Outer.Inner']` for package `foo.v1`.
  final List<String> messageTypes;

  /// All enum type names including nested, relative to package.
  final List<String> enumTypes;

  final Uint8List rawBytes;

  const ParsedFileDescriptor({
    required this.name,
    required this.package,
    required this.dependencies,
    required this.services,
    required this.messageTypes,
    required this.enumTypes,
    required this.rawBytes,
    this.serviceMethods = const {},
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
  final dependencies = <String>[];
  final services = <String>[];
  final serviceMethods = <String, List<String>>{};
  final messageTypes = <String>[];
  final enumTypes = <String>[];

  while (reader.hasMore) {
    final tag = reader.readTag();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;

    switch (fieldNumber) {
      case 1 when wireType == _wireLen:
        name = utf8.decode(reader.readLenDelimited());
      case 2 when wireType == _wireLen:
        package = utf8.decode(reader.readLenDelimited());
      case 3 when wireType == _wireLen:
        // repeated string dependency
        dependencies.add(utf8.decode(reader.readLenDelimited()));
      case 4 when wireType == _wireLen:
        // repeated DescriptorProto message_type — collect names recursively
        _collectAllTypeNames(
          reader.readLenDelimited(),
          '',
          messageTypes,
          enumTypes,
        );
      case 5 when wireType == _wireLen:
        // repeated EnumDescriptorProto enum_type (file-level)
        final enumName = _parseNameField(reader.readLenDelimited());
        if (enumName.isNotEmpty) enumTypes.add(enumName);
      case 6 when wireType == _wireLen:
        // repeated ServiceDescriptorProto service
        final svcBytes = reader.readLenDelimited();
        final svcName = _parseNameField(svcBytes);
        if (svcName.isNotEmpty) {
          services.add(svcName);
          final methods = _parseServiceMethodNames(svcBytes);
          if (methods.isNotEmpty) serviceMethods[svcName] = methods;
        }
      default:
        reader.skipField(wireType);
    }
  }

  return ParsedFileDescriptor(
    name: name,
    package: package,
    dependencies: dependencies,
    services: services,
    serviceMethods: serviceMethods,
    messageTypes: messageTypes,
    enumTypes: enumTypes,
    rawBytes: bytes,
  );
}

/// Recursively collects all message and enum type names from a DescriptorProto.
///
/// [prefix] is the dotted path of enclosing messages, e.g. `'Outer.'`.
/// Names are appended to [messages] and [enums] as `prefix + name`.
void _collectAllTypeNames(
  Uint8List bytes,
  String prefix,
  List<String> messages,
  List<String> enums,
) {
  final reader = _ProtoReader(bytes);
  var name = '';
  final nestedMessageBytes = <Uint8List>[];
  final nestedEnumBytes = <Uint8List>[];

  while (reader.hasMore) {
    final tag = reader.readTag();
    final fn = tag >> 3;
    final wt = tag & 0x7;

    switch (fn) {
      case 1 when wt == _wireLen:
        name = utf8.decode(reader.readLenDelimited());
      case 3 when wt == _wireLen:
        // nested_type (repeated DescriptorProto)
        nestedMessageBytes.add(reader.readLenDelimited());
      case 4 when wt == _wireLen:
        // enum_type (repeated EnumDescriptorProto)
        nestedEnumBytes.add(reader.readLenDelimited());
      default:
        reader.skipField(wt);
    }
  }

  if (name.isEmpty) return;

  final fqn = '$prefix$name';
  messages.add(fqn);

  final nestedPrefix = '$fqn.';
  for (final nb in nestedMessageBytes) {
    _collectAllTypeNames(nb, nestedPrefix, messages, enums);
  }
  for (final eb in nestedEnumBytes) {
    final enumName = _parseNameField(eb);
    if (enumName.isNotEmpty) enums.add('$nestedPrefix$enumName');
  }
}

/// Reads field 1 (string name) from a proto message.
/// Extracts the method names from a serialized `ServiceDescriptorProto`.
///
/// `ServiceDescriptorProto.method` is field 2, and each `MethodDescriptorProto`
/// carries its name in field 1.
///
/// Needed because `file_containing_symbol` accepts a fully-qualified METHOD
/// name -- the reflection proto documents the symbol as
/// `<package>.<service>[.<method>]` -- and that is how `grpcurl describe
/// pkg.Service.Method` resolves. Without the method names there is nothing to
/// index them under.
List<String> _parseServiceMethodNames(Uint8List bytes) {
  final methods = <String>[];
  final reader = _ProtoReader(bytes);
  while (reader.hasMore) {
    final tag = reader.readTag();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x7;
    if (fieldNumber == 2 && wireType == _wireLen) {
      final name = _parseNameField(reader.readLenDelimited());
      if (name.isNotEmpty) methods.add(name);
      continue;
    }
    reader.skipField(wireType);
  }
  return methods;
}

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
    // Accumulate the low and high 32-bit halves separately. On dart2js the
    // bitwise `<<` is a 32-bit operation, so shifting past bit 31 in a single
    // native int saturates/loses the high bits. Combining the halves via
    // multiplication keeps full 64-bit values correct under both the VM and JS.
    var low = 0;
    var high = 0;
    var shift = 0;
    while (_pos < _bytes.length) {
      if (shift >= 64) throw const FormatException('Varint exceeds 64 bits');
      final b = _bytes[_pos++];
      final part = b & 0x7F;
      if (shift < 28) {
        low |= part << shift;
      } else if (shift == 28) {
        // 4 bits stay in the low half, the remaining 3 start the high half.
        low |= (part & 0x0F) << 28;
        high = (part >> 4) & 0x07;
      } else {
        high |= part << (shift - 32);
      }
      if (b & 0x80 == 0) {
        return high == 0 ? low : (high * 0x100000000) + (low & 0xFFFFFFFF);
      }
      shift += 7;
    }
    throw const FormatException('Truncated varint');
  }

  Uint8List readLenDelimited() {
    final length = readVarint();
    if (length < 0 || _pos + length > _bytes.length) {
      throw FormatException(
        'Length-delimited field runs past end of buffer: '
        'need $length bytes at offset $_pos but only '
        '${_bytes.length - _pos} remain',
      );
    }
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
