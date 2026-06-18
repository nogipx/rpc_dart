// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding A3: _escape / _escapeString only escape single-quotes.
//
// generator.dart:1180 (_escape) and generator.dart:1434 (_escapeString):
//   value.replaceAll("'", "\\'")
// They do NOT escape backslash `\`, newline `\n`, or `$`. A method/service
// `description` containing any of these is interpolated raw into a single-quoted
// Dart string literal -> broken / invalid Dart, or unintended interpolation.
//
// This test feeds a description containing a backslash, a literal newline, and a
// `$`, then asserts the generated literal is properly escaped (valid Dart).
// CORRECT behavior:
//   - backslash escaped (`\\`)
//   - `$` escaped (`\$`) so it is not treated as interpolation
//   - no raw (unescaped) newline inside the single-quoted literal
// If escaping is missing -> bug CONFIRMED.

import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart_generator/builder.dart';
import 'package:test/test.dart';

void main() {
  test('A3: special chars in description are escaped', () async {
    final packageConfig = await _loadPackageConfig();
    final readerWriter = TestReaderWriter(rootPackage: 'rpc_dart_generator');
    await readerWriter.testing.loadIsolateSources();

    // Description with backslash, newline, and dollar sign.
    const source = '''
import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

part 'esc.g.dart';

@RpcService(name: 'EscSvc')
abstract class IEscSvc {
  @RpcMethod(name: 'op', description: 'line1\\nline2 path C:\\\\tmp cost \\\$5')
  Future<Foo> op(Foo request, {RpcContext? context});
}

class Foo implements IRpcSerializable {
  @override
  Map<String, dynamic> toJson() => {};
  factory Foo.fromJson(Map<String, dynamic> _) => Foo();
}
''';

    String? generated;
    final logs = <String>[];
    await testBuilder(
      rpcDartBuilder(BuilderOptions({})),
      {'rpc_dart_generator|lib/esc.dart': source},
      rootPackage: 'rpc_dart_generator',
      packageConfig: packageConfig,
      readerWriter: readerWriter,
      onLog: (r) => logs.add('${r.level}: ${r.message} ${r.error ?? ''}'),
      outputs: {
        'rpc_dart_generator|lib/esc.rpc_dart.g.part': decodedMatches(
          predicate<String>((s) {
            generated = s;
            return true;
          }),
        ),
      },
    );

    // If the builder could not even produce output, the unescaped special
    // characters broke generation -> bug CONFIRMED.
    expect(
      generated,
      isNotNull,
      reason:
          'generator produced no output for a description containing '
          'newline / backslash / \$ -> broken escaping. Build logs:\n'
          '${logs.join('\n')}',
    );
    final out = generated!;

    // Locate the description literal.
    final idx = out.indexOf('description:');
    expect(
      idx,
      greaterThanOrEqualTo(0),
      reason: 'no description emitted:\n$out',
    );

    // Extract from `description:` to end of that statement's segment.
    // The description is emitted as `description: '<...>',` (the dart formatter
    // may place the trailing args on their own lines, so the separator after the
    // closing quote can be a space OR a newline).
    final tail = out.substring(idx);

    // 1. The literal must not contain a raw newline (would break the line literal).
    //    We check the first 200 chars after `description:` for a raw \n that is
    //    part of the literal value (not the trailing source formatting).
    final descSegmentEnd = tail.indexOf("',");
    expect(
      descSegmentEnd,
      greaterThanOrEqualTo(0),
      reason: 'could not find end of description literal in:\n$tail',
    );
    final descLiteral = tail.substring(0, descSegmentEnd);

    expect(
      descLiteral.contains('\n'),
      isFalse,
      reason:
          'raw newline inside single-quoted literal -> invalid Dart:\n'
          '$descLiteral',
    );

    // 2. The dollar sign must be escaped, otherwise `$5` becomes interpolation
    //    of an undefined identifier (or a syntax error).
    expect(
      descLiteral.contains(r'$5') && !descLiteral.contains(r'\$5'),
      isFalse,
      reason:
          'unescaped \$ in description literal -> interpolation/compile '
          'error:\n$descLiteral',
    );
  });
}

Future<PackageConfig> _loadPackageConfig() async {
  final file = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  return loadPackageConfigUri(file.uri);
}
