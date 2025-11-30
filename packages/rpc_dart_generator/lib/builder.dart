import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/generator.dart';

Builder rpcDartBuilder(BuilderOptions options) {
  return SharedPartBuilder([RpcDartGenerator()], 'rpc_dart_generator');
}
