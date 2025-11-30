import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

void main() {
  group('rpc_dart_generator', () {
    test(
      'generates caller and responder for unary and server stream',
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

part 'input.g.dart';

@RpcService(name: 'Calc')
abstract class ICalc {
  @RpcMethod(name: 'sum')
  Future<Foo> sum(Foo request, {RpcContext? context});

  @RpcMethod(name: 'numbers', kind: RpcMethodKind.serverStream)
  Stream<Foo> numbers(Foo request);
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

        await testBuilder(
          rpcDartBuilder(BuilderOptions({})),
          {'rpc_dart_generator|lib/input.dart': source},
          rootPackage: 'rpc_dart_generator',
          packageConfig: packageConfig,
          readerWriter: readerWriter,
          outputs: {
            'rpc_dart_generator|lib/input.g.dart': decodedMatches(
              allOf([
                contains('class CalcNames'),
                contains('final class CalcCaller'),
                contains('abstract class CalcResponder'),
                contains("static const service = 'Calc'"),
                contains("static const sum = 'sum'"),
                contains('methodName: CalcNames.sum'),
                contains("addUnaryMethod<Foo, Foo>"),
                contains("addServerStreamMethod<Foo, Foo>"),
              ]),
            ),
          },
        );
      },
    );

    test('fails on invalid signature', () async {
      final packageConfig = await _loadPackageConfig();
      final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
      await readerWriter.testing.loadIsolateSources();
      const badSource = r'''
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'bad.g.dart';

@RpcService(name: 'Bad')
abstract class BadService {
  @RpcMethod(name: 'broken')
  Foo broken(Foo request);
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
}
''';

      final result = await testBuilder(
        rpcDartBuilder(BuilderOptions({})),
        {'rpc_dart_generator|lib/bad.dart': badSource},
        rootPackage: 'rpc_dart_generator',
        packageConfig: packageConfig,
        readerWriter: readerWriter,
      );

      expect(result.succeeded, isFalse);
      expect(
        result.errors.join('\n'),
        contains('Future'),
        reason: 'fails on invalid signature',
      );
    });
  });
}

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}
