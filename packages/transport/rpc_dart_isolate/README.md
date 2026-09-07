<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_isolate

Isolate-based caller/responder transports for `rpc_dart`.

- VM: spawns isolates and bridges them with stream-ID multiplexing.
- Web/wasm: uses `isolate_manager` workers for parity API.
- API: `RpcIsolateTransport.spawn` returns `{ transport, kill }` pair.

Extracted from `rpc_dart_transports` to keep web-safe, single-responsibility package.

## What crosses the isolate boundary

This transport reports `supportsZeroCopy == true`, which means `sendDirectObject`
works here — **not** that the peer receives the sender's instance. `SendPort.send`
deep-copies everything that is not deeply immutable. Measured by comparing
`identityHashCode` on both sides:

| what is sent | result |
| --- | --- |
| ordinary class built at runtime | copied |
| `const` instance | shared |
| `@pragma('vm:deeply-immutable')` class | **shared**, also when built at runtime |
| an annotated class held by an ordinary message | the message is copied, the annotated field is **shared** |
| `Uint8List` payload (`TransferableTypedData`) | moved, not copied |

Measured end to end through this transport, not just over a raw `SendPort`; see
`test/deeply_immutable_is_shared_test.dart`.

### Real zero-copy for your messages

Annotate the message class. The pragma is what does it — the same class with the
same `final` fields and no pragma is copied:

```dart
@pragma('vm:deeply-immutable')
final class Tick {
  const Tick(this.symbol, this.priceCents);
  final String symbol;
  final int priceCents;
}
```

The VM enforces this at compile time. The class must be `final` or `sealed`, every
instance field `final` and non-`late`, and every field type deeply immutable —
`int`, `double`, `bool`, `String`, `Pointer`, `Float32x4`, `Float64x2`, `Int32x4`,
or another `vm:deeply-immutable` class. `List`, `Map` and even `Uint8List` are
rejected, so bulk data does not travel this way; send it as a payload instead,
which the transport already transfers without a copy.

### Every direct object must be SENDABLE

Objects go on the port as they are, so a `Future`, `Timer` or `ReceivePort`
anywhere in the graph makes `SendPort.send` throw — including in a field your
codec never looks at. That fails the call it belongs to (the connection and other
in-flight calls are unaffected), and the error names the offending field.

Note that a **unary** call takes this path even when the method declares codecs,
because `UnaryCaller` branches on the transport's zero-copy support alone.
