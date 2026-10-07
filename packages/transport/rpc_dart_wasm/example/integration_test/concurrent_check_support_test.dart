// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Concurrent `checkSupport` calls each get the same, correct answer. On iOS each
// call evaluates its probe in a WKWebView, and a probe whose web view is
// released while it runs never answers or answers "no WebAssembly".
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'concurrent checkSupport calls agree',
    (_) async {
      final single = await RpcFlutterWasmBridge.checkSupport().timeout(
        const Duration(seconds: 30),
      );

      final answers = await Future.wait([
        for (var i = 0; i < 4; i++)
          RpcFlutterWasmBridge.checkSupport()
              .timeout(const Duration(seconds: 30))
              .then((s) => '${s.canRunDartWasm}')
              .catchError((Object e) => 'ERR ${e.runtimeType}'),
      ]);
      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}  single: ${single.canRunDartWasm}'
        '  concurrent: $answers',
      );

      expect(answers, everyElement('${single.canRunDartWasm}'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
