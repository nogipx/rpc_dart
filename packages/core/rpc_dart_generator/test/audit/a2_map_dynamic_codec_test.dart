// Audit finding A2: Map<String,dynamic> / primitive codec emits `.fromJson`.
//
// generator.dart:931-936: _assertSerializable allows String/int/double/bool and
// `Map<String, dynamic>` to pass without implementing IRpcSerializable.
// But generator.dart:437 _buildCodecs unconditionally emits:
//   RpcCodec<T>.withDecoder(T.fromJson)
// For T == `Map<String, dynamic>` this produces
//   RpcCodec<Map<String, dynamic>>.withDecoder(Map<String, dynamic>.fromJson)
// `Map<String, dynamic>.fromJson` does not exist -> generated code won't compile.
//
// CORRECT behavior: output must NOT contain `Map<String, dynamic>.fromJson`
// (the codec for such a type should not reference a non-existent factory).
// If it does -> bug CONFIRMED.

import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

void main() {
  test('A2: Map<String,dynamic> codec must not emit Map.fromJson', () async {
    final packageConfig = await _loadPackageConfig();
    final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
    await readerWriter.testing.loadIsolateSources();

    const source = r'''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'mapdyn.g.dart';

@RpcService(name: 'MapSvc')
abstract class IMapSvc {
  @RpcMethod(name: 'echo')
  Future<Map<String, dynamic>> echo(
    Map<String, dynamic> request, {
    RpcContext? context,
  });
}
''';

    String? generated;
    await testBuilder(
      rpcDartBuilder(BuilderOptions({})),
      {'rpc_dart_generator|lib/mapdyn.dart': source},
      rootPackage: 'rpc_dart_generator',
      packageConfig: packageConfig,
      readerWriter: readerWriter,
      onLog: (_) {},
      outputs: {
        'rpc_dart_generator|lib/mapdyn.rpc_dart.g.part': decodedMatches(
          predicate<String>((s) {
            generated = s;
            return true;
          }),
        ),
      },
    );

    expect(generated, isNotNull, reason: 'generator produced no output');

    expect(
      generated,
      isNot(contains('Map<String, dynamic>.fromJson')),
      reason:
          'Emitted reference to non-existent Map<String, dynamic>.fromJson; '
          'generated code will not compile. Output:\n$generated',
    );
  });
}

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}
