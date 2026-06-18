// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:typed_data';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

// The reflection package owns the canonical proto wire writer/parser. These
// tests validate that the descriptor bytes this generator emits are accepted
// by the reflection server that serves them (proving the two byte-identical
// proto writers stay in lockstep).
import 'package:rpc_dart_grpc_reflection/src/proto_parser.dart';
import 'package:rpc_dart_grpc_reflection/src/proto_writer.dart';

void main() {
  group('grpc descriptor — explicit field numbers, enum mapping', () {
    test(
      'explicit @RpcProtoField numbers + enum field round-trip via reflection',
      () async {
        final packageConfig = await _loadPackageConfig();
        final readerWriter = TestReaderWriter(
          rootPackage: 'rpc_dart_generator',
        );
        await readerWriter.testing.loadIsolateSources();

        const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'field_num.g.dart';

enum Color { red, green, blue }

@RpcService(name: 'shop.v1.Catalog', grpcDescriptor: true)
abstract class ICatalog {
  @RpcMethod(name: 'get')
  Future<Item> get(Query request);
}

class Query implements IRpcSerializable {
  @RpcProtoField(7)
  final String term;
  const Query({required this.term});
  @override Map<String, dynamic> toJson() => {'term': term};
}

class Item implements IRpcSerializable {
  @RpcProtoField(1)
  final String name;
  @RpcProtoField(2)
  final Color color;
  const Item({required this.name, required this.color});
  @override Map<String, dynamic> toJson() => {'name': name};
}
''';

        final captured = <String>[];
        String? output;
        await testBuilder(
          rpcDartBuilder(BuilderOptions({})),
          {'rpc_dart_generator|lib/field_num.dart': source},
          rootPackage: 'rpc_dart_generator',
          packageConfig: packageConfig,
          readerWriter: readerWriter,
          onLog: (record) => captured.add(record.message),
          outputs: {
            'rpc_dart_generator|lib/field_num.rpc_dart.g.part': decodedMatches(
              predicate<String>((s) {
                output = s;
                return true;
              }),
            ),
          },
        );

        // Explicit numbering must NOT trigger a declaration-order warning.
        expect(
          captured.where((m) => m.contains('declaration order')),
          isEmpty,
          reason: 'all fields are pinned with @RpcProtoField',
        );

        final descriptor = _extractDescriptorBytes(output!);
        final parsed = parseFileDescriptorProto(descriptor);

        expect(parsed.services, contains('Catalog'));
        expect(parsed.messageTypes, containsAll(['Query', 'Item']));

        // The Item message must carry an enum-typed field (proto type 14).
        expect(
          _messageHasFieldType(descriptor, 'Item', 14),
          isTrue,
          reason: 'Color enum field must map to TYPE_ENUM (14)',
        );
        // Item.name stays a string (type 9), proving only the enum was remapped.
        expect(_messageHasFieldType(descriptor, 'Item', 9), isTrue);
        // And the explicit numbers must be present (7 for Query.term).
        expect(_messageHasFieldNumber(descriptor, 'Query', 7), isTrue);
      },
    );

    test('declaration-order fallback emits an instability warning', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();

      const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'no_num.g.dart';

@RpcService(name: 'shop.v1.Cart', grpcDescriptor: true)
abstract class ICart {
  @RpcMethod(name: 'add')
  Future<Ack> add(AddReq request);
}

class AddReq implements IRpcSerializable {
  final String sku;
  final int qty;
  const AddReq({required this.sku, required this.qty});
  @override Map<String, dynamic> toJson() => {'sku': sku, 'qty': qty};
}

class Ack implements IRpcSerializable {
  @override Map<String, dynamic> toJson() => {};
}
''';

      final captured = <String>[];
      await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/no_num.dart': source},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
        onLog: (record) => captured.add(record.message),
      );

      expect(
        captured.any(
          (m) =>
              m.contains('declaration order') && m.contains('@RpcProtoField'),
        ),
        isTrue,
        reason: 'unpinned fields must warn about unstable numbering',
      );
    });
  });

  group('grpc descriptor — fully-qualified type names', () {
    test(
      'message field type names are package-qualified like service refs',
      () async {
        final packageConfig = await _loadPackageConfig();
        final readerWriter = TestReaderWriter(
          rootPackage: 'rpc_dart_generator',
        );
        await readerWriter.testing.loadIsolateSources();

        // The service name carries the proto package `shop.v1`. A field that
        // references another message type must be emitted as
        // `.shop.v1.Item`, byte-identical to the service input/output refs,
        // otherwise the descriptor pool cannot resolve the cross-reference.
        const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
part 'qualified.g.dart';

@RpcService(name: 'shop.v1.Catalog', grpcDescriptor: true)
abstract class ICatalog {
  @RpcMethod(name: 'get')
  Future<Order> get(Query request);
}

class Query implements IRpcSerializable {
  @RpcProtoField(1)
  final String term;
  const Query({required this.term});
  @override Map<String, dynamic> toJson() => {'term': term};
}

class Item implements IRpcSerializable {
  @RpcProtoField(1)
  final String name;
  const Item({required this.name});
  @override Map<String, dynamic> toJson() => {'name': name};
}

class Order implements IRpcSerializable {
  @RpcProtoField(1)
  final Item item;
  const Order({required this.item});
  @override Map<String, dynamic> toJson() => {};
}
''';

        String? output;
        await testBuilder(
          rpcDartBuilder(BuilderOptions({})),
          {'rpc_dart_generator|lib/qualified.dart': source},
          rootPackage: 'rpc_dart_generator',
          packageConfig: packageConfig,
          readerWriter: readerWriter,
          outputs: {
            'rpc_dart_generator|lib/qualified.rpc_dart.g.part': decodedMatches(
              predicate<String>((s) {
                output = s;
                return true;
              }),
            ),
          },
        );

        final descriptor = _extractDescriptorBytes(output!);

        // The field Order.item references Item -> must be fully-qualified.
        final fieldTypeName = _messageFieldTypeName(
          descriptor,
          'Order',
          'item',
        );
        expect(
          fieldTypeName,
          '.shop.v1.Item',
          reason: 'field type refs must carry the proto package prefix',
        );

        // And it must match the service input/output ref naming convention.
        final inputTypeName = _serviceMethodTypeName(descriptor, 'get', 2);
        expect(inputTypeName, '.shop.v1.Query');
      },
    );
  });

  group('proto writer parity (generator <-> reflection)', () {
    // The generator uses a byte-identical private copy of reflection's
    // ProtoWriter. We cannot import the private copy, but we can assert that
    // reflection's writer produces the golden bytes the generator side is
    // pinned to — both pin the same goldens in their respective parity tests.
    test('reflection ProtoWriter produces the pinned golden bytes', () {
      final w = ProtoWriter();
      w.writeString(1, 'Msg');
      w.writeInt32(3, 1);
      w.writeInt32(4, 1);
      w.writeInt32(5, 14);
      w.writeString(6, '.foo.Status');
      expect(
        w.toBytes(),
        Uint8List.fromList([
          10,
          3,
          77,
          115,
          103,
          24,
          1,
          32,
          1,
          40,
          14,
          50,
          11,
          46,
          102,
          111,
          111,
          46,
          83,
          116,
          97,
          116,
          117,
          115,
        ]),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}

/// Extracts the `Uint8List.fromList(const [...])` descriptor bytes from the
/// generated source text.
Uint8List _extractDescriptorBytes(String generated) {
  final match = RegExp(
    r'grpcDescriptor = Uint8List\.fromList\(const \[([0-9,\s]*)\]\)',
  ).firstMatch(generated);
  expect(match, isNotNull, reason: 'descriptor literal must be present');
  final nums = match!
      .group(1)!
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();
  return Uint8List.fromList(nums);
}

/// Returns true if [fileBytes] contains a message named [messageName] with a
/// field whose proto type equals [protoType].
bool _messageHasFieldType(
  Uint8List fileBytes,
  String messageName,
  int protoType,
) => _scanMessageField(fileBytes, messageName, 5, protoType);

/// Returns true if [messageName] has a field with the given proto field number.
bool _messageHasFieldNumber(
  Uint8List fileBytes,
  String messageName,
  int number,
) => _scanMessageField(fileBytes, messageName, 3, number);

/// Walks the FileDescriptorProto to find [messageName], then checks whether any
/// of its fields carries a varint sub-field [fieldTag] equal to [expected].
bool _scanMessageField(
  Uint8List fileBytes,
  String messageName,
  int fieldTag,
  int expected,
) {
  final messages = _collectLenDelimited(fileBytes, 4); // message_type
  for (final msg in messages) {
    if (_readName(msg) != messageName) continue;
    for (final field in _collectLenDelimited(msg, 2)) {
      // field
      if (_readVarintSubField(field, fieldTag) == expected) return true;
    }
  }
  return false;
}

/// Returns the proto `type_name` (field tag 6) of the field named [fieldName]
/// inside the message named [messageName], or null if not found.
String? _messageFieldTypeName(
  Uint8List fileBytes,
  String messageName,
  String fieldName,
) {
  for (final msg in _collectLenDelimited(fileBytes, 4)) {
    if (_readName(msg) != messageName) continue;
    for (final field in _collectLenDelimited(msg, 2)) {
      if (_readName(field) != fieldName) continue;
      return _readStringSubField(field, 6);
    }
  }
  return null;
}

/// Returns the input (tag 2) or output (tag 3) type name of the service method
/// named [methodName]. [typeTag] is 2 for input, 3 for output.
String? _serviceMethodTypeName(
  Uint8List fileBytes,
  String methodName,
  int typeTag,
) {
  for (final service in _collectLenDelimited(fileBytes, 6)) {
    for (final method in _collectLenDelimited(service, 2)) {
      if (_readName(method) != methodName) continue;
      return _readStringSubField(method, typeTag);
    }
  }
  return null;
}

String? _readStringSubField(Uint8List bytes, int fieldNumber) {
  final r = _Reader(bytes);
  while (r.hasMore) {
    final tag = r.varint();
    if (tag >> 3 == fieldNumber && tag & 7 == 2) {
      return String.fromCharCodes(r.lenDelimited());
    }
    r.skip(tag & 7);
  }
  return null;
}

String _readName(Uint8List bytes) {
  final r = _Reader(bytes);
  while (r.hasMore) {
    final tag = r.varint();
    if (tag >> 3 == 1 && tag & 7 == 2) {
      return String.fromCharCodes(r.lenDelimited());
    }
    r.skip(tag & 7);
  }
  return '';
}

int? _readVarintSubField(Uint8List bytes, int fieldNumber) {
  final r = _Reader(bytes);
  while (r.hasMore) {
    final tag = r.varint();
    if (tag >> 3 == fieldNumber && tag & 7 == 0) return r.varint();
    r.skip(tag & 7);
  }
  return null;
}

List<Uint8List> _collectLenDelimited(Uint8List bytes, int fieldNumber) {
  final out = <Uint8List>[];
  final r = _Reader(bytes);
  while (r.hasMore) {
    final tag = r.varint();
    if (tag >> 3 == fieldNumber && tag & 7 == 2) {
      out.add(r.lenDelimited());
    } else {
      r.skip(tag & 7);
    }
  }
  return out;
}

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int _pos = 0;
  bool get hasMore => _pos < _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List lenDelimited() {
    final len = varint();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        final len = varint();
        _pos += len;
      case 5:
        _pos += 4;
    }
  }
}
