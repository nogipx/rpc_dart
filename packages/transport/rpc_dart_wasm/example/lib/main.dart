// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Minimal host for the plugin's native code.
//
// It exists so `flutter build` and `flutter test integration_test` have
// something to compile the Swift and Kotlin INTO -- a plugin on its own is not
// buildable. What it shows is the one thing worth seeing without a real WASM
// module: what the platform reports about its own capabilities.

import 'package:flutter/material.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

void main() {
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  RpcWasmSupportInfo? _info;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await RpcFlutterWasmBridge.checkSupport();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final error = _error;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('rpc_dart_wasm')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: error != null
                ? Text('checkSupport failed: $error')
                : info == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('JS engine:   ${info.jsEngineAvailable}'),
                      Text('WebAssembly: ${info.webAssemblyAvailable}'),
                      // False below iOS 17.2 even though the plugin installs
                      // from 15.0: the deployment target is what LINKS, WasmGC
                      // is probed at runtime and is what dart2wasm needs.
                      Text('WasmGC:      ${info.wasmGcSupported}'),
                      const SizedBox(height: 12),
                      Text('can run dart2wasm: ${info.canRunDartWasm}'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
