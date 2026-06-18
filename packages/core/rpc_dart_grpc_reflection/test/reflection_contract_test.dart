// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late RpcReflectionRegistry registry;
  late ServerReflectionContract contract;

  setUp(() {
    registry = RpcReflectionRegistry();
    contract = ServerReflectionContract(registry);
  });

  group('list_services', () {
    test('returns all registered service names', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'svc.proto',
          package: 'svc.v1',
          serviceNames: ['Alpha', 'Beta'],
        ),
      );

      final response = contract.processRequestForTest(listServicesRequest());
      final services = parseListServicesResponse(response);

      expect(services, containsAll(['svc.v1.Alpha', 'svc.v1.Beta']));
    });

    test('empty registry returns empty service list', () {
      final response = contract.processRequestForTest(listServicesRequest());
      expect(parseListServicesResponse(response), isEmpty);
    });

    test('response includes original_request field', () {
      final request = listServicesRequest();
      final response = contract.processRequestForTest(request);
      expect(hasOriginalRequest(response), isTrue);
    });
  });

  group('file_by_filename', () {
    test('returns file_descriptor_response for registered file', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      final response = contract.processRequestForTest(
        fileByFilenameRequest('echo.proto'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('returns error_response for unknown file', () {
      final response = contract.processRequestForTest(
        fileByFilenameRequest('missing.proto'),
      );
      final err = parseErrorResponse(response);

      expect(err, isNotNull);
      expect(err!.code, 5);
      expect(err.message, contains('missing.proto'));
    });

    test('response contains one file_descriptor_proto for standalone file', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      final response = contract.processRequestForTest(
        fileByFilenameRequest('echo.proto'),
      );

      expect(extractAllFileDescriptorBytes(response), hasLength(1));
    });

    test('response contains file + dependency bytes', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'common.proto',
          package: 'common.v1',
          serviceNames: [],
        ),
      );
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['common.proto'],
        ),
      );

      final response = contract.processRequestForTest(
        fileByFilenameRequest('echo.proto'),
      );

      expect(extractAllFileDescriptorBytes(response), hasLength(2));
    });
  });

  group('file_containing_symbol', () {
    test('finds file by service FQN', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('echo.v1.EchoService'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('finds file by service FQN with leading dot', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('.echo.v1.EchoService'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('finds file by message type', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptorWithMessages(
          name: 'echo.proto',
          package: 'echo.v1',
          messageNames: ['EchoRequest'],
          serviceNames: [],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('echo.v1.EchoRequest'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('finds file by nested message type', () {
      registry.addFileDescriptor(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedMessageNames: ['Inner'],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('nested.v1.Outer.Inner'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('finds file by nested enum type', () {
      registry.addFileDescriptor(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedEnumNames: ['Status'],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('nested.v1.Outer.Status'),
      );

      expect(isFileDescriptorResponse(response), isTrue);
    });

    test('response includes transitive dependency bytes', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'common.proto',
          package: 'common.v1',
          serviceNames: [],
        ),
      );
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['common.proto'],
        ),
      );

      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('echo.v1.EchoService'),
      );

      expect(extractAllFileDescriptorBytes(response), hasLength(2));
    });

    test('returns error_response for unknown symbol', () {
      final response = contract.processRequestForTest(
        fileContainingSymbolRequest('not.registered.Service'),
      );
      final err = parseErrorResponse(response);

      expect(err, isNotNull);
      expect(err!.code, 5);
    });
  });

  group('error handling — malformed input', () {
    test('malformed varint returns error_response, not crash', () {
      final malformed = Uint8List.fromList([0x80, 0x80, 0x80, 0x80]);

      expect(() => contract.processRequestForTest(malformed), returnsNormally);

      final err = parseErrorResponse(contract.processRequestForTest(malformed));
      expect(err, isNotNull);
      expect(err!.code, 2);
    });

    test('oversized length field returns error_response, not RangeError', () {
      final tag = 0x1A; // field 3, wire type 2
      final malformed = Uint8List.fromList([tag, ...encodeVarint(999999999)]);

      expect(() => contract.processRequestForTest(malformed), returnsNormally);

      final err = parseErrorResponse(contract.processRequestForTest(malformed));
      expect(err, isNotNull);
    });

    test('empty bytes returns unknown request type error', () {
      final response = contract.processRequestForTest(Uint8List(0));
      final err = parseErrorResponse(response);

      expect(err, isNotNull);
      expect(err!.code, 5);
    });

    test('unknown wire type stops parsing gracefully', () {
      final bytes = Uint8List.fromList([0x03]); // field 0, wire type 3
      expect(() => contract.processRequestForTest(bytes), returnsNormally);
    });
  });

  group('v1 and v1alpha', () {
    test('both contracts return identical list_services response', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'svc.proto',
          package: 'svc.v1',
          serviceNames: ['MyService'],
        ),
      );

      final v1 = ServerReflectionContract(
        registry,
        serviceName: 'grpc.reflection.v1.ServerReflection',
      );
      final v1alpha = ServerReflectionContract(
        registry,
        serviceName: 'grpc.reflection.v1alpha.ServerReflection',
      );

      final req = listServicesRequest();
      expect(
        parseListServicesResponse(v1.processRequestForTest(req)),
        equals(parseListServicesResponse(v1alpha.processRequestForTest(req))),
      );
    });

    test('ServerReflectionContract.both returns two contracts', () {
      final contracts = ServerReflectionContract.both(registry);
      expect(contracts.length, 2);

      final names = contracts.map((c) => c.serviceName).toList();
      expect(names, contains('grpc.reflection.v1.ServerReflection'));
      expect(names, contains('grpc.reflection.v1alpha.ServerReflection'));
    });
  });
}
