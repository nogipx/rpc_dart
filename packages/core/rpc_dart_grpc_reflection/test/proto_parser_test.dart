// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:test/test.dart';

import '../lib/src/proto_parser.dart';
import 'helpers.dart';

void main() {
  group('parseFileDescriptorProto', () {
    test('extracts name and package', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: [],
        ),
      );

      expect(parsed.name, 'echo.proto');
      expect(parsed.package, 'echo.v1');
    });

    test('extracts service names', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptor(
          name: 'svc.proto',
          package: 'svc.v1',
          serviceNames: ['Alpha', 'Beta'],
        ),
      );

      expect(parsed.services, containsAll(['Alpha', 'Beta']));
    });

    test('extracts top-level message type names', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptorWithMessages(
          name: 'msg.proto',
          package: 'msg.v1',
          messageNames: ['Request', 'Response'],
          serviceNames: [],
        ),
      );

      expect(parsed.messageTypes, containsAll(['Request', 'Response']));
    });

    test('extracts file-level enum type names', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptorWithMessages(
          name: 'enums.proto',
          package: 'enums.v1',
          messageNames: [],
          serviceNames: [],
          enumNames: ['GlobalStatus', 'Priority'],
        ),
      );

      expect(parsed.enumTypes, containsAll(['GlobalStatus', 'Priority']));
    });

    test('extracts import dependencies', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: [],
          dependencies: ['common.proto', 'google/protobuf/timestamp.proto'],
        ),
      );

      expect(
        parsed.dependencies,
        containsAll(['common.proto', 'google/protobuf/timestamp.proto']),
      );
    });

    test('extracts nested message type names', () {
      final parsed = parseFileDescriptorProto(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedMessageNames: ['Inner', 'AnotherInner'],
        ),
      );

      expect(parsed.messageTypes, contains('Outer'));
      expect(parsed.messageTypes, contains('Outer.Inner'));
      expect(parsed.messageTypes, contains('Outer.AnotherInner'));
    });

    test('extracts nested enum type names', () {
      final parsed = parseFileDescriptorProto(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedEnumNames: ['Status', 'Priority'],
        ),
      );

      expect(parsed.enumTypes, contains('Outer.Status'));
      expect(parsed.enumTypes, contains('Outer.Priority'));
    });

    test('empty package is preserved', () {
      final parsed = parseFileDescriptorProto(
        buildMinimalFileDescriptor(
          name: 'svc.proto',
          package: '',
          serviceNames: ['MyService'],
        ),
      );

      expect(parsed.package, '');
      expect(parsed.dependencies, isEmpty);
    });

    test('rawBytes matches input', () {
      final bytes = buildMinimalFileDescriptor(
        name: 'echo.proto',
        package: 'echo.v1',
        serviceNames: ['EchoService'],
      );
      final parsed = parseFileDescriptorProto(bytes);

      expect(parsed.rawBytes, equals(bytes));
    });

    test('parses real protobuf echo descriptor', () {
      final parsed = parseFileDescriptorProto(echoFileDescriptorBytes());

      expect(parsed.services, contains('EchoService'));
      expect(parsed.messageTypes, containsAll(['EchoRequest', 'EchoResponse']));
    });

    test('empty bytes returns empty descriptor without error', () {
      final parsed = parseFileDescriptorProto(Uint8List(0));

      expect(parsed.name, '');
      expect(parsed.package, '');
      expect(parsed.services, isEmpty);
      expect(parsed.messageTypes, isEmpty);
      expect(parsed.enumTypes, isEmpty);
      expect(parsed.dependencies, isEmpty);
    });
  });

  group('_ProtoReader.readVarint — malformed input', () {
    test('truncated varint throws FormatException', () {
      final bytes = Uint8List.fromList([0x80, 0x80, 0x80]);
      expect(
        () => parseFileDescriptorProto(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('varint exceeding 64 bits throws FormatException', () {
      final bytes = Uint8List.fromList([
        0x0A, // tag: field 1, wire type 2
        0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00,
      ]);
      expect(
        () => parseFileDescriptorProto(bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parseFileDescriptorSet', () {
    test('returns all contained FileDescriptorProtos', () {
      final set = buildMinimalFileDescriptorSet([
        ('a.proto', 'a.v1', ['ServiceA']),
        ('b.proto', 'b.v1', ['ServiceB']),
      ]);
      final parsed = parseFileDescriptorSet(set);

      expect(parsed.length, 2);
      expect(parsed.map((p) => p.name), containsAll(['a.proto', 'b.proto']));
    });

    test('empty set returns empty list', () {
      final parsed = parseFileDescriptorSet(Uint8List(0));
      expect(parsed, isEmpty);
    });
  });
}
