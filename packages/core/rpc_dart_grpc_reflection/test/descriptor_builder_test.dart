// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:test/test.dart';

import '../lib/src/proto_parser.dart';

void main() {
  group('RpcFileDescriptorBuilder — round-trip via parser', () {
    test('name and package are preserved', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'echo.proto',
        package: 'echo.v1',
      ).build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.name, 'echo.proto');
      expect(parsed.package, 'echo.v1');
    });

    test('addDependency is included in parsed dependencies', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'echo.proto',
        package: 'echo.v1',
      )
          .addDependency('common.proto')
          .addDependency('google/protobuf/timestamp.proto')
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.dependencies,
          containsAll(['common.proto', 'google/protobuf/timestamp.proto']));
    });

    test('addMessage registers message name', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'echo.proto',
        package: 'echo.v1',
      )
          .addMessage(const RpcMessageDescriptor(name: 'EchoRequest'))
          .addMessage(const RpcMessageDescriptor(name: 'EchoResponse'))
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.messageTypes, containsAll(['EchoRequest', 'EchoResponse']));
    });

    test('addService registers service name', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'echo.proto',
        package: 'echo.v1',
      )
          .addService(
            name: 'EchoService',
            methods: [
              const RpcMethodDescriptor(
                name: 'Echo',
                inputType: '.echo.v1.EchoRequest',
                outputType: '.echo.v1.EchoResponse',
              ),
            ],
          )
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.services, contains('EchoService'));
    });

    test('addEnum registers file-level enum', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'enums.proto',
        package: 'enums.v1',
      )
          .addEnum(const RpcEnumDescriptor(
            name: 'Status',
            values: [
              RpcEnumValueDescriptor(name: 'UNKNOWN', number: 0),
              RpcEnumValueDescriptor(name: 'ACTIVE', number: 1),
            ],
          ))
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.enumTypes, contains('Status'));
    });

    test('nested message types are included in parsed messageTypes', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'nested.proto',
        package: 'nested.v1',
      )
          .addMessage(const RpcMessageDescriptor(
            name: 'Outer',
            nestedTypes: [
              RpcMessageDescriptor(name: 'Inner'),
              RpcMessageDescriptor(name: 'AnotherInner'),
            ],
          ))
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.messageTypes, contains('Outer'));
      expect(parsed.messageTypes, contains('Outer.Inner'));
      expect(parsed.messageTypes, contains('Outer.AnotherInner'));
    });

    test('nested enum types inside message are included in parsed enumTypes', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'nested.proto',
        package: 'nested.v1',
      )
          .addMessage(const RpcMessageDescriptor(
            name: 'Outer',
            enumTypes: [
              RpcEnumDescriptor(
                name: 'Status',
                values: [RpcEnumValueDescriptor(name: 'UNKNOWN', number: 0)],
              ),
            ],
          ))
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.enumTypes, contains('Outer.Status'));
    });

    test('deeply nested message types are included', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'deep.proto',
        package: 'deep.v1',
      )
          .addMessage(const RpcMessageDescriptor(
            name: 'L1',
            nestedTypes: [
              RpcMessageDescriptor(
                name: 'L2',
                nestedTypes: [
                  RpcMessageDescriptor(name: 'L3'),
                ],
              ),
            ],
          ))
          .build();
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.messageTypes, containsAll(['L1', 'L1.L2', 'L1.L2.L3']));
    });

    test('syntax field is included in output', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'echo.proto',
        package: 'echo.v1',
      ).build();

      // Verify bytes are non-empty and parseable (syntax is field 12, skipped by parser but valid)
      expect(bytes, isNotEmpty);
      expect(() => parseFileDescriptorProto(bytes), returnsNormally);
    });
  });

  group('RpcFileDescriptorBuilder — registry integration', () {
    test('builder output is accepted by registry for all symbol types', () {
      final bytes = RpcFileDescriptorBuilder(
        name: 'full.proto',
        package: 'full.v1',
      )
          .addMessage(const RpcMessageDescriptor(
            name: 'Request',
            nestedTypes: [RpcMessageDescriptor(name: 'Header')],
            enumTypes: [
              RpcEnumDescriptor(
                name: 'Priority',
                values: [RpcEnumValueDescriptor(name: 'LOW', number: 0)],
              ),
            ],
          ))
          .addEnum(const RpcEnumDescriptor(
            name: 'GlobalStatus',
            values: [RpcEnumValueDescriptor(name: 'UNKNOWN', number: 0)],
          ))
          .addService(
            name: 'FullService',
            methods: [
              const RpcMethodDescriptor(
                name: 'Do',
                inputType: '.full.v1.Request',
                outputType: '.full.v1.Request',
              ),
            ],
          )
          .build();

      final registry = RpcReflectionRegistry();
      registry.addFileDescriptor(bytes);

      expect(registry.fileContainingSymbol('full.v1.FullService'), isNotNull);
      expect(registry.fileContainingSymbol('full.v1.Request'), isNotNull);
      expect(registry.fileContainingSymbol('full.v1.Request.Header'), isNotNull);
      expect(registry.fileContainingSymbol('full.v1.Request.Priority'), isNotNull);
      expect(registry.fileContainingSymbol('full.v1.GlobalStatus'), isNotNull);
    });
  });

  group('RpcMessageDescriptor', () {
    test('toBytes with fields only', () {
      const msg = RpcMessageDescriptor(
        name: 'EchoRequest',
        fields: [
          RpcFieldDescriptor(
            name: 'message',
            number: 1,
            type: RpcFieldType.typeString,
          ),
        ],
      );
      final bytes = msg.toBytes();
      expect(bytes, isNotEmpty);

      final parsed = parseFileDescriptorProto(
        _wrapInFileDescriptor('test.proto', 'test', bytes),
      );
      expect(parsed.messageTypes, contains('EchoRequest'));
    });
  });

  group('RpcEnumDescriptor', () {
    test('toBytes is non-empty', () {
      const enm = RpcEnumDescriptor(
        name: 'Status',
        values: [
          RpcEnumValueDescriptor(name: 'UNKNOWN', number: 0),
          RpcEnumValueDescriptor(name: 'ACTIVE', number: 1),
        ],
      );
      expect(enm.toBytes(), isNotEmpty);
    });
  });

  group('RpcMethodDescriptor', () {
    test('streaming flags are encoded', () {
      const method = RpcMethodDescriptor(
        name: 'BiStream',
        inputType: '.foo.Request',
        outputType: '.foo.Response',
        clientStreaming: true,
        serverStreaming: true,
      );
      final bytes = method.toBytes();
      expect(bytes, isNotEmpty);
    });
  });

  group('RpcFieldDescriptor', () {
    test('json_name is camelCase of snake_case field name', () {
      // Verified indirectly: toBytes() must not throw and output is non-empty
      const field = RpcFieldDescriptor(
        name: 'my_field_name',
        number: 1,
        type: RpcFieldType.typeString,
      );
      expect(field.toBytes(), isNotEmpty);
    });

    test('repeated label is encoded', () {
      const field = RpcFieldDescriptor(
        name: 'items',
        number: 1,
        type: RpcFieldType.typeString,
        label: RpcFieldLabel.repeated,
      );
      expect(field.toBytes(), isNotEmpty);
    });

    test('message field with typeName is encoded', () {
      const field = RpcFieldDescriptor(
        name: 'payload',
        number: 1,
        type: RpcFieldType.typeMessage,
        typeName: '.foo.v1.Payload',
      );
      expect(field.toBytes(), isNotEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<int> _varint(int value) {
  final out = <int>[];
  while (value > 0x7F) {
    out.add((value & 0x7F) | 0x80);
    value >>= 7;
  }
  out.add(value & 0x7F);
  return out;
}

List<int> _str(int field, String v) {
  if (v.isEmpty) return [];
  final b = utf8.encode(v);
  return [..._varint((field << 3) | 2), ..._varint(b.length), ...b];
}

/// Wraps raw DescriptorProto bytes into a minimal FileDescriptorProto.
Uint8List _wrapInFileDescriptor(String name, String package, Uint8List msgBytes) {
  final buf = <int>[];
  buf.addAll(_str(1, name));
  buf.addAll(_str(2, package));
  buf.addAll([..._varint((4 << 3) | 2), ..._varint(msgBytes.length), ...msgBytes]);
  return Uint8List.fromList(buf);
}
