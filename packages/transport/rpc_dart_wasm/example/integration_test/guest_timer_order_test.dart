// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Guest timers that fall due together fire as they do in a browser or on the
// VM: in deadline order, ties in creation order, and the microtasks one timer
// schedules run before the next timer.
//
// The guest creates Timer(30 ms) 'late', Timer(10 ms) 'early' -- which
// schedules a microtask 'micro' -- and Timer(10 ms) 'same', then holds its
// thread for 60 ms so all three are due on the same tick.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'guest timers due together fire in deadline order',
    (_) async {
      final wasm = (await rootBundle.load(
        'assets/guest.wasm',
      )).buffer.asUint8List();
      final mjs = await rootBundle.loadString('assets/guest.mjs');
      final bridge = await RpcFlutterWasmBridge.load(
        wasmBytes: wasm,
        mjsCode: mjs,
      ).timeout(const Duration(seconds: 60));
      final caller = RpcCallerEndpoint(
        transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
      );

      final order =
          (await caller
                  .unaryRequest<RpcString, RpcString>(
                    serviceName: 'Echo',
                    methodName: 'TimerOrder',
                    request: ''.rpc,
                    requestCodec: _codec,
                    responseCodec: _codec,
                  )
                  .timeout(const Duration(seconds: 30)))
              .value;
      // ignore: avoid_print
      print('platform: ${Platform.operatingSystem}  order: $order');

      expect(order, 'early,micro,same,late');

      await caller.close();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
