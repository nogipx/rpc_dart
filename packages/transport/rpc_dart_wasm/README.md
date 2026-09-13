<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_wasm

WASM runtime bridge transport for `rpc_dart`.

This package is intentionally runtime-agnostic. It does not load `.wasm`
modules by itself. Instead, a runtime backend
implements the byte-only `RpcWasmBridge`, and `RpcWasmTransport.fromBridge`
turns it into a normal `IRpcTransport`.

```dart
final transport = RpcWasmTransport.fromBridge(
  bridge: myWasmBridge,
  isClient: true,
);

final endpoint = RpcPeerEndpoint(transport: transport);
endpoint.start();
```

## WASM Bootstrap

Code compiled to WASM can bootstrap itself with `RpcWasm.run(...)`:

```dart
import 'package:rpc_dart_wasm/rpc_wasm.dart';

void main() {
  RpcWasm.run(
    isClient: false,
    configure: (endpoint) {
      // Register RPC services here, then let the bootstrap start listening.
    },
  );
}
```

`RpcWasm.run` installs the runtime-side `rpcWasmReceiveBytes` callback,
adapts the host byte pipe into `RpcWasmTransport`, creates a
`RpcPeerEndpoint`, and starts it after `configure` returns.

## Flutter Backend

`RpcFlutterWasmBridge` is the built-in Flutter plugin backend:

```dart
final support = await RpcFlutterWasmBridge.checkSupport();
if (!support.canRunDartWasm) {
  throw StateError('Dart WASM is not supported on this device');
}

final bridge = await RpcFlutterWasmBridge.load(
  wasmBytes: wasmBytes,
  mjsCode: mjsCode,
);

final transport = RpcWasmTransport.fromBridge(
  bridge: bridge,
  isClient: true,
);
```

Native backends:

- Android: `androidx.javascriptengine.JavaScriptSandbox`, driven from a
  coroutine loop; bytes cross as Binder calls.
- iOS: an offscreen `WKWebView` with a custom `rpc-wasm:` scheme handler. Bytes
  cross as `fetch` calls the handler answers — guest-to-host is a POST, and
  host-to-guest is a long-polled GET.

**iOS is WKWebView, not JavaScriptCore.** JSC has no WebAssembly, so it cannot
run a dart2wasm guest at all.

The Flutter host keeps lifecycle calls on the `rpc_dart_wasm` method channel,
but runtime byte traffic goes over raw binary messenger channels:

- `rpc_dart_wasm/<runtimeId>/outgoing` for Dart to native
- `rpc_dart_wasm/<runtimeId>/incoming` for native to Dart

The WASM JavaScript side should expose a byte receiver:

```js
globalThis.rpcWasmReceiveBytes = function(bytes) {
  // bytes is a Uint8Array containing one RpcChannelFrame.
};
```

To send bytes back to the host, call:

```js
_rpcWasmSendBytes(bytes); // bytes is Uint8Array
```

## Bridge Protocol

`RpcWasmBridge` exchanges only `Uint8List` frames:

```dart
abstract interface class RpcWasmBridge {
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List data);
  bool get isClosed;
  Future<void> close();
}
```

No RPC-level JSON and no WASM-specific envelope is added by this package.
`RpcWasmTransport` adapts the bridge to `IRpcChannel` and reuses
`RpcChannelTransport.fromChannel`, so the wire format is the existing
`RpcChannelFrame`.

## Runtime Backends

Expected backends:

- Flutter plugin backend: an offscreen WKWebView on iOS, JavaScriptSandbox on
  Android.
- Browser backend: `dart:js_interop` / JS functions.
- Native backend: wasmtime/wasmer embedding.
- Test backend: paired in-memory bridge.

The transport itself does not guarantee zero-copy. Most WASM host boundaries
copy bytes; backends may optimize byte transfer independently.

## What a call costs

Every call crosses a process boundary and then waits for a driver tick, so the
cost is dominated by round trips rather than by bytes. Measured, not estimated —
`integration_test/frame_cost_test.dart` in `example/`, round-trip through a real
dart2wasm guest, after a discarded warm-up call:

| shape           |    n | Android p50 | iOS p50 | Android p99 | iOS p99 |
| --------------- | ---: | ----------- | ------- | ----------- | ------- |
| empty unary     |  200 | 10.3 ms     | 3.0 ms  | 78.7 ms     | 12.7 ms |
| 1 KiB response  |  200 | 8.8 ms      | 31.1 ms | 91.7 ms     | 617 ms  |
| 64 KiB response |  100 | 12.0 ms     | 33.5 ms | 51.7 ms     | 183 ms  |
| 1 MiB response  |   20 | 68.3 ms     | 81.2 ms | 132 ms      | 265 ms  |

**Android 11 (API 30) emulator and iOS 18.6 simulator** — a floor rather than a
prediction, since real hardware is faster and the tail especially so. Read the
SHAPE, which the hardware does not change: the price is dominated by the
boundary rather than the payload, and the p99 is several times the p50 because a
call can miss a driver tick.

The two platforms are not interchangeable. iOS answers an empty call in 3 ms
against Android's 10 ms, and Android carries a 1 KiB payload in 8.8 ms against
iOS's 31 ms — so the cheaper platform depends on whether your calls are chatty
or bulky.

Budget accordingly: this transport is for isolating untrusted or hot-swappable
logic, not for chatty per-item calls. Batch where you can.

### Guest timers are not throttled

The iOS guest runs in a `WKWebView` that is never added to a view hierarchy, so
its page is permanently hidden — and WebKit throttles timers in hidden pages.
Measured lag over the requested delay, ten samples each, clocked inside the
guest:

| delay          | Android median | iOS median |
| -------------- | -------------- | ---------- |
| `Timer(1 ms)`  | 3 ms           | 0 ms       |
| `Timer(10 ms)` | 4 ms           | 1 ms       |
| `Timer(100 ms)`| 5 ms           | 1 ms       |
| `Timer(1 s)`   | 7 ms           | 99 ms      |

So deadlines, keepalives and backoff inside a guest are usable on both. iOS is
tighter at short delays and drifts about 10% on a one-second timer; Android is a
flat few milliseconds throughout.

### `Stopwatch` needs a shim on Android, and has one

dart2wasm's glue calls `performance.now()`. A `WKWebView` supplies it;
`JavaScriptSandbox` is a bare V8 isolate that does not, so a guest using
`Stopwatch` used to die on Android with an opaque `Internal server error` while
the same guest worked on iOS. The Android boot script now installs a `Date.now()`
shim when `performance` is absent — **millisecond resolution**, so a guest
timing sub-millisecond intervals reads 0 rather than a wrong number.
