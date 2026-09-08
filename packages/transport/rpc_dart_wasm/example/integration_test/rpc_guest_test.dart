// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A REAL dart2wasm guest running rpc_dart INSIDE the sandbox.
//
// plugin_test.dart drives the raw bridge with plain JS, which proves the byte
// pipe and nothing above it. This is the only test where the framing, flow
// control and contract machinery run on both sides of a device boundary --
// what an application actually does.
//
// The guest is built by tool/build_guest.sh, never committed: a checked-in
// .wasm goes stale the moment core changes and the test would then report on a
// guest nobody is shipping.

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

Future<({RpcFlutterWasmBridge bridge, RpcCallerEndpoint caller})>
_connect() async {
  final wasm = (await rootBundle.load(
    'assets/guest.wasm',
  )).buffer.asUint8List();
  final mjs = await rootBundle.loadString('assets/guest.mjs');

  final bridge = await RpcFlutterWasmBridge.load(
    wasmBytes: wasm,
    mjsCode: mjs,
  ).timeout(const Duration(seconds: 60));

  // The guest runs RpcWasm.run with isClient: false, so it takes even stream
  // ids; the host must take odd ones or every call would collide.
  final caller = RpcCallerEndpoint(
    transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
  );
  return (bridge: bridge, caller: caller);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a unary call reaches a real guest and comes back',
    (_) async {
      final c = await _connect();

      final r = await c.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Say',
            request: 'hello'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 30));

      expect(r.value, 'echo:hello');

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'a server stream arrives in order and completes',
    (_) async {
      final c = await _connect();

      final got = await c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Count',
            request: '25'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((e) => e.value)
          .toList()
          .timeout(const Duration(seconds: 60));

      expect(got, hasLength(25));
      expect(got.first, 'item-0');
      expect(got.last, 'item-24');

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'a response near the default message ceiling survives',
    (_) async {
      // 4 MiB from inside the guest, through the framing layer, over the native
      // bridge. On Android this crosses the bounded outbox drain added in round
      // 185, and it is the first time a frame that size has been REASSEMBLED
      // rather than echoed as opaque bytes.
      final c = await _connect();

      const n = 4 * 1024 * 1024;
      final r = await c.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Big',
            request: '$n'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 120));

      expect(r.value.length, n);

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
