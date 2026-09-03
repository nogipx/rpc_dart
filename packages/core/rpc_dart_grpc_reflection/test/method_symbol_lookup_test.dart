// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// file_containing_symbol indexed services, message types and enum types, but
// not METHODS. The reflection proto documents the symbol as
// `<package>.<service>[.<method>]`, and `grpcurl describe pkg.Service.Method`
// relies on the method form.
//
// Found by pointing grpcurl 1.9.3 -- a real, independent gRPC client -- at
// rpc_dart_grpc_reflection/example/server_protobuf.dart over the HTTP/2
// transport:
//
//   describe echo.v1.EchoService        -> OK (service)
//   describe echo.v1.EchoRequest        -> OK (message)
//   describe echo.v1.EchoService.Echo   -> Failed to resolve symbol
//                                          "echo.v1.EchoService.Echo":
//                                          Symbol not found
//
// after: both Echo and EchoStream resolve, and everything else still works
// (list, describe service, describe message, and real unary + server-stream
// calls through grpcurl).
//
// The existing suite covered "finds file by service FQN", by message type, by
// nested message and by nested enum -- every symbol kind EXCEPT a method, which
// is why Dart-side tests never caught it.

import 'dart:typed_data';

import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:test/test.dart';

/// Builds a FileDescriptorProto with one package, one service and two methods.
///
/// Hand-encoded rather than generated so the test has no protobuf dependency
/// and states the wire shape it relies on outright.
Uint8List _descriptor() {
  final out = BytesBuilder();

  void lenDelimited(int fieldNumber, List<int> payload) {
    out.addByte((fieldNumber << 3) | 2);
    var len = payload.length;
    // varint length
    while (true) {
      final b = len & 0x7F;
      len >>= 7;
      out.addByte(len == 0 ? b : (b | 0x80));
      if (len == 0) break;
    }
    out.add(payload);
  }

  List<int> nameField(String name) {
    final b = BytesBuilder();
    b.addByte((1 << 3) | 2); // field 1, len-delimited
    b.addByte(name.length);
    b.add(name.codeUnits);
    return b.toBytes();
  }

  // MethodDescriptorProto { name }
  List<int> method(String name) => nameField(name);

  // ServiceDescriptorProto { name = 1, method = 2 (repeated) }
  List<int> service(String name, List<String> methods) {
    final b = BytesBuilder();
    b.add(nameField(name));
    for (final m in methods) {
      final encoded = method(m);
      b.addByte((2 << 3) | 2); // field 2, len-delimited
      b.addByte(encoded.length);
      b.add(encoded);
    }
    return b.toBytes();
  }

  lenDelimited(1, 'echo.proto'.codeUnits); // file name
  lenDelimited(2, 'echo.v1'.codeUnits); // package
  lenDelimited(6, service('EchoService', ['Echo', 'EchoStream'])); // service

  return out.toBytes();
}

void main() {
  late RpcReflectionRegistry registry;

  setUp(() {
    registry = RpcReflectionRegistry();
    registry.addFileDescriptor(_descriptor());
  });

  group('file_containing_symbol', () {
    // WITNESS: this returned null before the fix.
    test('resolves a fully-qualified METHOD name', () {
      expect(
        registry.fileContainingSymbol('echo.v1.EchoService.Echo'),
        isNotNull,
        reason:
            'a method symbol is a documented form of file_containing_symbol '
            '(<package>.<service>[.<method>]), and grpcurl describe uses it',
      );
    });

    // WITNESS: streaming methods are indexed the same way.
    test('resolves a streaming method', () {
      expect(
        registry.fileContainingSymbol('echo.v1.EchoService.EchoStream'),
        isNotNull,
      );
    });

    test('resolves a method with a leading dot', () {
      expect(
        registry.fileContainingSymbol('.echo.v1.EchoService.Echo'),
        isNotNull,
        reason: 'the leading-dot form is accepted for every other symbol kind',
      );
    });

    // GUARD: a method that does not exist must still miss, or the fix would be
    // indexing something far too broadly.
    test('does not resolve an unknown method', () {
      expect(registry.fileContainingSymbol('echo.v1.EchoService.Nope'), isNull);
    });

    // GUARDS: the symbol kinds that already worked must keep working.
    test('still resolves the service itself', () {
      expect(registry.fileContainingSymbol('echo.v1.EchoService'), isNotNull);
    });

    test('still lists the service', () {
      expect(registry.serviceNames, contains('echo.v1.EchoService'));
    });

    test('does not resolve an unknown service', () {
      expect(registry.fileContainingSymbol('echo.v1.Missing'), isNull);
    });
  });
}
