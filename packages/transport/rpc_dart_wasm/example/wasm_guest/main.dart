// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A REAL dart2wasm guest, compiled by tool/build_guest.sh and loaded by the
// integration tests.
//
// Everything else on the device runs plain JS through the raw bridge, which
// proves the byte pipe and nothing above it. This is the only thing that puts
// rpc_dart's own stack -- framing, flow control, contracts -- inside the
// sandbox, which is what an application actually does.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

final class _EchoService extends RpcResponderContract {
  _EchoService() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Say',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async =>
          'echo:${request.value}'.rpc,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Big',
      requestCodec: _codec,
      responseCodec: _codec,
      // Returns as many bytes as asked for, so a caller can drive the response
      // across the host's transport ceilings from inside the guest.
      handler: (request, {RpcContext? context}) async =>
          ('x' * int.parse(request.value)).rpc,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Count',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final n = int.parse(request.value);
        for (var i = 0; i < n; i++) {
          yield 'item-$i'.rpc;
        }
      },
    );
  }
}

void main() {
  RpcWasm.run(
    configure: (endpoint) {
      endpoint.registerServiceContract(_EchoService());
    },
  );
}
