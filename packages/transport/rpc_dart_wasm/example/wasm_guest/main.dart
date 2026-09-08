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

/// Items the Firehose handler has yielded, readable over RPC.
int _produced = 0;

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

    // Unbounded, so a caller can cancel mid-flight. `_produced` is readable
    // through Produced below, which is how the host asks whether the handler
    // actually STOPPED rather than merely stopped being listened to.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final body = 'y' * 1024;
        while (true) {
          yield body.rpc;
          _produced++;
          await Future<void>.delayed(Duration.zero);
        }
      },
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Produced',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async => '$_produced'.rpc,
    );

    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        final parts = <String>[];
        await for (final r in requests) {
          parts.add(r.value);
        }
        return '${parts.length}:${parts.join(",")}'.rpc;
      },
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Mirror',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async* {
        await for (final r in requests) {
          yield 'back:${r.value}'.rpc;
        }
      },
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
