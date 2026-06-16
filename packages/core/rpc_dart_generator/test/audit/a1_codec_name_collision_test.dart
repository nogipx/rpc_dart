// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding A1: Codec name collisions.
//
// generator.dart:398,406-407,430,1451: codec identifiers are built from
// getDisplayString() (simple type name, no import prefix) via
// _sanitizeTypeName. Two distinct types with the same simple name from
// different libraries (e.g. `a.Foo` and `b.Foo`) both map to the key/identifier
// `codecFoo`. The codecMap keyed only on simple display string means the second
// type is silently dropped (containsKey short-circuits at 410/418), and only
// ONE `codecFoo` is emitted -> the other type has no codec / wrong codec.
//
// CORRECT behavior: each distinct request/response type gets its own distinct
// codec constant. This test asserts that two distinct `Foo` types yield two
// distinct codec constants. If only one codecFoo is emitted -> bug CONFIRMED.

import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

void main() {
  test('A1: distinct same-simple-named types get distinct codecs', () async {
    final packageConfig = await _loadPackageConfig();
    final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
    await readerWriter.testing.loadIsolateSources();

    const fooA = r'''
import 'package:rpc_dart/rpc_dart.dart';
class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
  factory Foo.fromJson(Map<String, dynamic> _) => Foo();
}
''';

    const fooB = r'''
import 'package:rpc_dart/rpc_dart.dart';
class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
  factory Foo.fromJson(Map<String, dynamic> _) => Foo();
}
''';

    const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';
import 'foo_a.dart' as a;
import 'foo_b.dart' as b;

part 'collide.g.dart';

@RpcService(name: 'Collide')
abstract class ICollide {
  @RpcMethod(name: 'go')
  Future<b.Foo> go(a.Foo request, {RpcContext? context});
}
''';

    String? generated;
    await testBuilder(
      rpcDartBuilder(BuilderOptions({})),
      {
        'rpc_dart_generator|lib/collide.dart': source,
        'rpc_dart_generator|lib/foo_a.dart': fooA,
        'rpc_dart_generator|lib/foo_b.dart': fooB,
      },
      rootPackage: 'rpc_dart_generator',
      packageConfig: packageConfig,
      readerWriter: readerWriter,
      onLog: (_) {},
      outputs: {
        'rpc_dart_generator|lib/collide.rpc_dart.g.part': decodedMatches(
          predicate<String>((s) {
            generated = s;
            return true;
          }),
        ),
      },
    );

    expect(generated, isNotNull, reason: 'generator produced no output');

    // Two distinct codec constants must exist for the two distinct Foo types.
    // With the collision bug, only ONE `codecFoo` is emitted.
    final codecCount =
        RegExp(r'static const codec\w*\s*=').allMatches(generated!).length;

    expect(
      codecCount,
      greaterThanOrEqualTo(2),
      reason: 'Expected 2 distinct codecs for two distinct Foo types, got '
          '$codecCount. Generated:\n$generated',
    );
  });
}

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}
