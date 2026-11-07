// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web-safety smoke: compiles each probe to JavaScript and runs it under
// node. dart compile js alone is NOT a web check on SDK 3.12 — it accepts
// dart:io and stubs it to throw at run time — so the probes execute real
// code and let the stubs blow up if anything io leaked onto their path.
//
// fvm dart run tool/web/web_smoke.dart

import 'dart:io';

const _probes = <String, String>{
  'core': 'tool/web/probe_web_core.dart',
  'rpc_tunnel': 'tool/web/probe_web_rpc_tunnel.dart',
};

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('rpc_acp_web_smoke_');
  var failed = false;
  try {
    for (final probe in _probes.entries) {
      final js = File('${tmp.path}/${probe.key}.js');
      final compile = await Process.run('fvm', <String>[
        'dart',
        'compile',
        'js',
        '-o',
        js.path,
        probe.value,
      ]);
      if (compile.exitCode != 0) {
        stderr.writeln('${probe.key}: compile failed\n${compile.stderr}');
        failed = true;
        continue;
      }
      final run = await Process.run('node', <String>[js.path]);
      stdout.write(run.stdout);
      stderr.write(run.stderr);
      final ok = run.exitCode == 0;
      print('${probe.key}: ${ok ? 'ok' : 'FAIL (exit ${run.exitCode})'}');
      if (!ok) failed = true;
    }
  } finally {
    await tmp.delete(recursive: true);
  }
  if (failed) exitCode = 1;
}
