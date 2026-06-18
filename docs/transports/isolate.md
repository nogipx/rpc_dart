<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Isolate Transport

`rpc_dart_isolate` provides a transport that runs the responder side in a separate Dart isolate. Use it to offload CPU-intensive work without blocking the main isolate. On native platforms it uses `dart:isolate`; on web it uses `isolate_manager` with web workers.

---

## Installation

```yaml
dependencies:
  rpc_dart_isolate: <latest>
```

---

## How It Works

`RpcIsolateTransport.spawn()` starts an isolate, sets up a bidirectional message channel between host and worker, and returns a named record:

```dart
final (:transport, :kill) = await RpcIsolateTransport.spawn(
  entrypoint: myWorkerEntrypoint,
);
```

- `transport` — the host-side `IRpcTransport`. Wire it to a `RpcCallerEndpoint` as usual.
- `kill()` — terminates the isolate immediately.

---

## Defining the Worker Entrypoint

The worker function receives the transport and custom parameters. It must set up a `RpcResponderEndpoint` and register contracts:

```dart
void calculatorWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.registerServiceContract(CalculatorResponder());
  endpoint.start();
  // The isolate stays alive as long as the endpoint is open.
}
```

The entrypoint signature must match `RpcIsolateEntrypoint`:

```dart
typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);
```

!!! warning
    The entrypoint function must be a top-level function or a static method — Dart isolates cannot send closures across isolate boundaries.

---

## Usage

```dart
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

// Spawn the worker isolate
final (:transport, :kill) = await RpcIsolateTransport.spawn(
  entrypoint: calculatorWorker,
  customParams: {'precision': 10},
  debugName: 'calculator-worker',
);

// Use the transport on the host side
final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: transport),
);

final result = await caller.sum(SumRequest(values: [1, 2, 3]));
print('sum = ${result.result}');

// Shut down
await caller.endpoint.close();
kill();
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `entrypoint` | `RpcIsolateEntrypoint` | required | Worker function |
| `customParams` | `Map<String, dynamic>?` | `{}` | Arbitrary data passed to the worker |
| `isolateId` | `String` | `'default'` | Logical ID (used in default debug name) |
| `debugName` | `String?` | `'rpc-isolate-{id}'` | Name shown in the Dart VM debugger |
| `policy` | `RpcSecurityPolicy` | default policy | Security limits |
| `workerUri` | `Uri?` | `null` | Web worker script URI (web only, ignored on IO) |

---

## Web / Wasm

On web, `workerUri` points to the compiled worker script. The API is identical — only the `workerUri` parameter differs:

```dart
final (:transport, :kill) = await RpcIsolateTransport.spawn(
  entrypoint: calculatorWorker,
  workerUri: Uri.parse('worker.dart.js'),
);
```

---

## Notes

- The isolate transport supports zero-copy (`supportsZeroCopy == true`) — objects are passed directly via `SendPort` as `directObject` messages without serialization.
- All four RPC patterns (unary, server-stream, client-stream, bidirectional) are supported.
- `kill()` is immediate; for a graceful shutdown close the endpoint first, then call `kill()`.