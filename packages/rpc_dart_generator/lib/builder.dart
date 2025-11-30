import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/generator.dart';

Builder rpcDartBuilder(BuilderOptions options) {
  return PartBuilder(
    [RpcDartGenerator()],
    '.g.dart',
    header: '// GENERATED CODE - DO NOT MODIFY BY HAND',
  );
}
