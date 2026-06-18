// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Captures emitted [LogRecord]s for assertions.
class _CapturingLogOutput extends LogOutput {
  final List<LogEvent> events = [];

  @override
  void write(LogRecord record) {
    if (record is LogEvent) events.add(record);
  }
}

void main() {
  group('RpcReflectionRegistry', () {
    late RpcReflectionRegistry registry;

    setUp(() {
      registry = RpcReflectionRegistry();
    });

    // --- Basic registration ---

    test('empty registry has no services', () {
      expect(registry.serviceNames, isEmpty);
      expect(registry.hasDescriptors, isFalse);
    });

    test('addFileDescriptor registers service name', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      expect(registry.serviceNames, ['echo.v1.EchoService']);
      expect(registry.hasDescriptors, isTrue);
    });

    test('addFileDescriptor registers multiple services', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'multi.proto',
          package: 'svc.v1',
          serviceNames: ['Alpha', 'Beta'],
        ),
      );

      expect(
        registry.serviceNames,
        containsAll(['svc.v1.Alpha', 'svc.v1.Beta']),
      );
    });

    test('no-package service uses unqualified name', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'svc.proto',
          package: '',
          serviceNames: ['MyService'],
        ),
      );

      expect(registry.serviceNames, contains('MyService'));
      expect(registry.fileContainingSymbol('MyService'), isNotNull);
    });

    test('duplicate registration does not duplicate service name', () {
      final bytes = buildMinimalFileDescriptor(
        name: 'echo.proto',
        package: 'echo.v1',
        serviceNames: ['EchoService'],
      );
      registry.addFileDescriptor(bytes);
      registry.addFileDescriptor(bytes);

      expect(
        registry.serviceNames.where((n) => n == 'echo.v1.EchoService').length,
        1,
      );
    });

    test('serviceNames is unmodifiable', () {
      expect(() => registry.serviceNames.add('hacked'), throwsUnsupportedError);
    });

    // --- fileByFilename ---

    test('fileByFilename returns bytes for registered file', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      expect(registry.fileByFilename('echo.proto'), isNotNull);
    });

    test('fileByFilename returns null for unknown file', () {
      expect(registry.fileByFilename('missing.proto'), isNull);
    });

    test('fileByFilename includes the file itself in returned list', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      final result = registry.fileByFilename('echo.proto')!;
      expect(result, hasLength(1));
    });

    // --- fileContainingSymbol ---

    test('fileContainingSymbol finds service by FQN', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      expect(registry.fileContainingSymbol('echo.v1.EchoService'), isNotNull);
    });

    test('fileContainingSymbol finds service with leading dot', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
        ),
      );

      expect(registry.fileContainingSymbol('.echo.v1.EchoService'), isNotNull);
    });

    test('fileContainingSymbol returns null for unknown symbol', () {
      expect(registry.fileContainingSymbol('foo.v1.NotRegistered'), isNull);
    });

    test('fileContainingSymbol finds message type', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptorWithMessages(
          name: 'echo.proto',
          package: 'echo.v1',
          messageNames: ['EchoRequest'],
          serviceNames: [],
        ),
      );

      expect(registry.fileContainingSymbol('echo.v1.EchoRequest'), isNotNull);
      expect(registry.fileContainingSymbol('.echo.v1.EchoRequest'), isNotNull);
    });

    test('fileContainingSymbol finds nested message type', () {
      registry.addFileDescriptor(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedMessageNames: ['Inner'],
        ),
      );

      expect(registry.fileContainingSymbol('nested.v1.Outer'), isNotNull);
      expect(registry.fileContainingSymbol('nested.v1.Outer.Inner'), isNotNull);
      expect(
        registry.fileContainingSymbol('.nested.v1.Outer.Inner'),
        isNotNull,
      );
    });

    test('fileContainingSymbol finds nested enum type', () {
      registry.addFileDescriptor(
        buildDescriptorWithNesting(
          name: 'nested.proto',
          package: 'nested.v1',
          outerName: 'Outer',
          nestedEnumNames: ['Status'],
        ),
      );

      expect(
        registry.fileContainingSymbol('nested.v1.Outer.Status'),
        isNotNull,
      );
      expect(
        registry.fileContainingSymbol('.nested.v1.Outer.Status'),
        isNotNull,
      );
    });

    test('fileContainingSymbol finds file-level enum type', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptorWithMessages(
          name: 'enums.proto',
          package: 'enums.v1',
          messageNames: [],
          serviceNames: [],
          enumNames: ['GlobalStatus'],
        ),
      );

      expect(registry.fileContainingSymbol('enums.v1.GlobalStatus'), isNotNull);
    });

    // --- Dependency resolution ---

    test('fileByFilename includes registered dependency', () {
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

      final result = registry.fileByFilename('echo.proto')!;
      expect(result, hasLength(2));
    });

    test('fileContainingSymbol includes transitive dependencies', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'base.proto',
          package: 'base.v1',
          serviceNames: [],
        ),
      );
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'mid.proto',
          package: 'mid.v1',
          serviceNames: [],
          dependencies: ['base.proto'],
        ),
      );
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'top.proto',
          package: 'top.v1',
          serviceNames: ['TopService'],
          dependencies: ['mid.proto'],
        ),
      );

      final result = registry.fileContainingSymbol('top.v1.TopService')!;
      expect(result, hasLength(3)); // top + mid + base
    });

    test('missing dependency is omitted but partial set still returned', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['google/protobuf/timestamp.proto'], // not registered
        ),
      );

      final result = registry.fileByFilename('echo.proto')!;
      expect(result, hasLength(1)); // only the file itself
    });

    // --- Missing-dependency reporting (backlog #7) ---

    test('missingDependencies lists unregistered declared deps', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['google/protobuf/timestamp.proto'],
        ),
      );

      expect(registry.missingDependencies(), {
        'google/protobuf/timestamp.proto',
      });
    });

    test('missingDependencies empty when closure complete', () {
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

      expect(registry.missingDependencies(), isEmpty);
    });

    test('warning fires naming missing deps on incomplete resolution', () {
      final output = _CapturingLogOutput();
      final logger = LogController(outputs: [output]).scope('test.reflection');
      final reg = RpcReflectionRegistry(logger: logger);

      reg.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['google/protobuf/timestamp.proto'], // not registered
        ),
      );

      final result = reg.fileByFilename('echo.proto')!;
      expect(result, hasLength(1)); // partial set still returned

      final warnings = output.events
          .where((e) => e.level == RpcLogLevel.warning)
          .toList();
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('INCOMPLETE'));
      expect(
        warnings.single.message,
        contains('google/protobuf/timestamp.proto'),
      );
      expect(
        warnings.single.data?['missingFiles'],
        contains('google/protobuf/timestamp.proto'),
      );
    });

    test('no warning when all deps registered', () {
      final output = _CapturingLogOutput();
      final logger = LogController(outputs: [output]).scope('test.reflection');
      final reg = RpcReflectionRegistry(logger: logger);

      reg.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'common.proto',
          package: 'common.v1',
          serviceNames: [],
        ),
      );
      reg.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'echo.proto',
          package: 'echo.v1',
          serviceNames: ['EchoService'],
          dependencies: ['common.proto'],
        ),
      );

      reg.fileByFilename('echo.proto');

      expect(
        output.events.where((e) => e.level == RpcLogLevel.warning),
        isEmpty,
      );
    });

    test('circular dependencies do not cause infinite loop', () {
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'a.proto',
          package: 'a.v1',
          serviceNames: [],
          dependencies: ['b.proto'],
        ),
      );
      registry.addFileDescriptor(
        buildMinimalFileDescriptor(
          name: 'b.proto',
          package: 'b.v1',
          serviceNames: ['BService'],
          dependencies: ['a.proto'],
        ),
      );

      expect(() => registry.fileByFilename('a.proto'), returnsNormally);
    });

    // --- addFromPbjson ---

    test('addFromPbjson registers service from real descriptor bytes', () {
      registry.addFromPbjson(
        name: 'echo.proto',
        package: 'echo.v1',
        messages: [echoRequestDescriptor, echoResponseDescriptor],
        services: [echoServiceDescriptor],
      );

      expect(registry.serviceNames, contains('echo.v1.EchoService'));
      expect(registry.fileByFilename('echo.proto'), isNotNull);
      expect(registry.fileContainingSymbol('echo.v1.EchoService'), isNotNull);
    });

    test('addFromPbjson with dependencies stores them in registry', () {
      registry.addFromPbjson(
        name: 'common.proto',
        package: 'common.v1',
        messages: [],
        services: [],
      );
      registry.addFromPbjson(
        name: 'echo.proto',
        package: 'echo.v1',
        messages: [echoRequestDescriptor, echoResponseDescriptor],
        services: [echoServiceDescriptor],
        dependencies: ['common.proto'],
      );

      final result = registry.fileByFilename('echo.proto')!;
      expect(result, hasLength(2)); // echo + common
    });
  });
}
