<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_isolate

Isolate transport for [`rpc_dart`](https://pub.dev/packages/rpc_dart). The
responder runs in a separate isolate (VM) or Web Worker (web), so CPU-heavy work
does not block the caller. All four call kinds are supported.

Contracts, endpoints, errors and `RpcSecurityPolicy` are documented in
`rpc_dart`. This README covers only what is specific to isolates.

## Install

```yaml
dependencies:
  rpc_dart_isolate: ^0.4.0
```

## The worker entrypoint

The worker side is a function with this signature:

```dart
typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);
```

It receives the worker-side transport and the `customParams` given to `spawn`.
It builds a responder endpoint, registers contracts and starts it:

```dart
import 'package:rpc_dart/rpc_dart.dart';

void calculatorWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final precision = params['precision'] as int? ?? 2;
  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(CalculatorResponder(precision))
    ..start();
}
```

Make it a top-level function or a static method. On the VM the function is sent
to the new isolate, and a closure that captures unsendable state makes `spawn`
throw. Pass data through `customParams` instead.

If the entrypoint throws, `spawn` throws instead of returning a dead transport.

## Spawning (VM)

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

Future<void> runCalculator() async {
  final (:transport, :kill) = await RpcIsolateTransport.spawn(
    entrypoint: calculatorWorker,
    customParams: {'precision': 10},
    debugName: 'calculator-worker',
  );

  final endpoint = RpcCallerEndpoint(transport: transport);
  try {
    // ... make calls through a generated caller or the endpoint ...
  } finally {
    await endpoint.close();
    kill();
  }
}
```

`spawn` completes once the entrypoint has run, and returns a record:

- `transport` — the host-side `IRpcReconnectableTransport`. Give it to an
  `RpcCallerEndpoint`.
- `kill` — closes the transport and terminates the isolate (or worker)
  immediately. Calls in flight fail. Safe to call more than once.

On the VM, closing the transport (for example through `endpoint.close()`) also
terminates the isolate, so `kill()` after a close is a no-op there. Calling it
anyway keeps the same code correct on the web.

### Parameters

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `entrypoint` | `RpcIsolateEntrypoint` | required | Worker function. Ignored on the web, see below. |
| `customParams` | `Map<String, dynamic>?` | `{}` | Passed to the entrypoint. Must be sendable to an isolate (VM) or structured-cloneable (web). |
| `isolateId` | `String` | `'default'` | Used in the default `debugName`. |
| `debugName` | `String?` | `'rpc-isolate-<isolateId>'` | Isolate name in the VM debugger; Worker name on the web. |
| `policy` | `RpcSecurityPolicy` | `RpcSecurityPolicy()` | Applied to both sides; the worker receives the same policy. |
| `workerUri` | `Uri?` | `null` | Web only: the worker script. Ignored on the VM. |
| `startupTimeout` | `Duration` | 30 s | `spawn` throws `TimeoutException` if the worker is not ready by then. |

## Web and Wasm

On the web the worker is a separately compiled program, because a function
cannot be sent to a Web Worker. `entrypoint` is accepted (so one call site
compiles for both targets) but ignored. Instead, the worker program's `main`
calls `runRpcIsolateManagerWorker` with its entrypoint:

```dart
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

// worker.dart, compiled on its own and served next to the app.
void main() {
  runRpcIsolateManagerWorker(calculatorWorker);
}
```

Compile it, for example with
`dart compile js worker.dart -o web/rpcIsolateWorker.js`, and spawn with its
URL:

```dart
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

Future<void> spawnOnWeb() async {
  final (:transport, :kill) = await RpcIsolateTransport.spawn(
    entrypoint: calculatorWorker,
    workerUri: Uri.base.resolve('rpcIsolateWorker.js'),
    customParams: {'precision': 10},
  );
  // ...
  kill();
}
```

- Without `workerUri`, the script `rpcIsolateWorker.js` is resolved against
  `Uri.base`.
- Under dart2wasm the Worker is created with `type: 'module'`, so the script
  must be an ES module.
- The worker inherits `spawn(policy: ...)`. Passing `policy:` to
  `runRpcIsolateManagerWorker` overrides it.
- A script that fails to load, or a worker that throws during startup, makes
  `spawn` throw. A worker that dies later closes the transport, so calls fail
  instead of hanging.
- On the VM `runRpcIsolateManagerWorker` does nothing, so the worker program can
  share code with a VM build.
- `isolateManagerCustomWorker` is re-exported from `isolate_manager`, but this
  transport's worker does not need it: `runRpcIsolateManagerWorker` sets up the
  worker scope itself.

## What crosses the boundary

On the VM `supportsZeroCopy` is `true`: `sendDirectObject` works, and methods
without codecs pass objects as they are. On the web it is `false`; messages are
serialized and posted with structured clone, so methods need codecs there.

`supportsZeroCopy` means the object is sent without serialization. It does not
mean the peer receives the same instance: `SendPort.send` deep-copies everything
that is not deeply immutable.

| What is sent | Result |
| --- | --- |
| ordinary object built at run time | copied |
| `const` instance | shared |
| `@pragma('vm:deeply-immutable')` class | shared, also when built at run time |
| an annotated object inside an ordinary message | the message is copied, the annotated field is shared |
| serialized payload under 256 KiB | sent as `Uint8List`, copied |
| serialized payload of 256 KiB or more | sent as `TransferableTypedData`: copied once when built, then moved |

`test/deeply_immutable_is_shared_test.dart` checks this through the transport.

Under the default `RpcDataTransferMode.auto`, a unary request takes the object
path even when the method declares codecs. Pass
`dataTransferMode: RpcDataTransferMode.codec` to the caller contract to force
serialization (see `rpc_dart`).

### Sharing instead of copying

Annotate the message class. The pragma is what does it; the same class without
it is copied:

```dart
@pragma('vm:deeply-immutable')
final class Tick {
  const Tick(this.symbol, this.priceCents);
  final String symbol;
  final int priceCents;
}
```

The VM enforces this at compile time. The class must be `final` or `sealed`,
every instance field `final` and not `late`, and every field type deeply
immutable: `int`, `double`, `bool`, `String`, `Pointer`, `Float32x4`,
`Float64x2`, `Int32x4`, or another `vm:deeply-immutable` class. `List`, `Map`
and `Uint8List` are rejected, so bulk data does not travel this way; send it as
a serialized payload.

### Direct objects must be sendable

Objects go on the port as they are, so a `Future`, `Timer`, `ReceivePort` or
similar anywhere in the object graph makes `SendPort.send` throw, including in a
field your codec never reads. That fails only the call it belongs to; the
connection and other calls are unaffected, and the error names the offending
field.
