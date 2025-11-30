import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';

/// Builds executable arguments for relaunching the current process in daemon mode.
class RuntimeInvocationBuilder {
  const RuntimeInvocationBuilder._();

  /// Returns the full argument list that should be passed to [Process.start]
  /// when spawning a detached copy of the current executable.
  static List<String> build(List<String> childArgs) {
    final executableArgs = <String>[];

    final inherited = Platform.executableArguments;
    if (inherited.isNotEmpty) {
      executableArgs.addAll(inherited);
    }

    final executableName =
        p.basename(Platform.resolvedExecutable).toLowerCase();
    final needsScriptArgument = executableName == 'dart' ||
        executableName == 'dart.exe' ||
        executableName == 'dartaotruntime' ||
        executableName == 'dartaotruntime.exe' ||
        executableName == 'dart_precompiled_runtime' ||
        executableName == 'dart_precompiled_runtime.exe';

    if (needsScriptArgument) {
      final scriptUri = Platform.script;
      if (scriptUri.scheme == 'file') {
        try {
          executableArgs.add(scriptUri.toFilePath());
        } on UnsupportedError {
          // Ignore invalid URIs and continue with the resolved executable only.
        }
      }
    }

    return <String>[...executableArgs, ...childArgs];
  }
}
