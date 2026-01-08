<div style="text-align: center;">
  <h1>
    <p>RPC Dart - Transports</p>
  </h1>
</div>

Transport implementations for [RPC Dart](https://pub.dev/packages/rpc_dart). Provides ready transports.

### Core concepts

- Transport — concrete implementation of the IRpcTransport interface.
- Client/Server transports — client-side connectors and server-side handlers.
- Multiplexing — many RPCs over one connection where supported.
- Zero-copy — supported where transport permits in-process object transfer.
- Health monitoring — each transport exposes `health()` snapshots and
  `reconnect()` attempts to simplify diagnostics.

### Supported transports

- WebSocketTransport — bidirectional real-time transport with reconnection and optional multiplexing.
- IsolateTransport — efficient communication between Dart isolates, supports zero-copy for in-process objects.
- Http2Transport — HTTP/2 based transport with gRPC-compatible framing, TLS support and stream multiplexing.

#### Isolate transport on web (workers)

- On the web, use `isolate_manager` with a Web Worker. Annotate your worker with `@isolateManagerCustomWorker`, call `runRpcIsolateManagerWorker(yourServerEntrypoint);`, and build it with `dart compile js web/rpc_isolate_worker.dart -o web/rpcIsolateWorker.js` (default name resolved relative to `Uri.base`). No manual `postMessage` plumbing is needed.
- For dart2wasm builds the worker is started as `type: 'module'`; ensure your bundler/server serves a module worker. You can override the filename via `workerUri`, and `debugName` is forwarded into `WorkerOptions.name`.
- `RpcIsolateTransport.spawn` keeps the same API and defaults to `rpcIsolateWorker.js` when `workerUri` is not provided. The `entrypoint` parameter exists for parity—real logic lives in the worker.
- Zero-copy is not available inside the worker; use normal serialization (codecs or framed bytes).
- Worker channels must carry JSON-friendly values only (`num`/`String`/`bool`/`null`/`Map`/`List`). Binary payloads are automatically serialized to `List<int>` inside the transport.
- On Dart VM isolates, zero-copy is supported via `TransferableTypedData` when both sides send/receive binary payloads (fallbacks to copies when not available). On the web, `TransferableTypedData` is not exposed and worker channels go through structured-clone JSON, so payloads are serialized instead.

Example worker (`web/rpc_isolate_worker.dart`):

```dart
// Run in the worker context. Bundlers should keep this as a dedicated entry.
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

/// This will be used to generate JS for the worker for the WEB platform.
@isolateManagerCustomWorker
FutureOr<void> rpcIsolateWorker(dynamic _) async {
  runRpcIsolateManagerWorker(isolateEntrypoint);
}

/// This should be used directly in RpcIsolateTransport.spawn() on IO platform.
void isolateEntrypoint(IRpcTransport transport, Map<String, dynamic> customParams) {
  final responder = RpcResponderEndpoint(
    transport: transport,
    policy: const RpcSecurityPolicy(), // Optional; match your host.
  );

  // Register your contracts/handlers here.
  // responder.registerContract(MyServiceContract());
  responder.start();
}

```

Generate the JS worker after edits:

```bash
dart run isolate_manager:generate
# or
dart compile js web/rpc_isolate_worker.dart -o web/rpcIsolateWorker.js
```

#### WebSocket transport notes

- Frame layout: `[streamId:4][flags:1][gRPC_frame...]`, where `gRPC_frame` is the 5-byte gRPC prefix plus payload.
- For large messages you can enable WebSocket chunking (`enableChunking: true` in `RpcWebSocketTransportBase` constructors). It slices gRPC frames with an extra chunk header and reassembles them on receive.
- Chunking is off by default for backward compatibility—enable only when both peers support chunked flags.
