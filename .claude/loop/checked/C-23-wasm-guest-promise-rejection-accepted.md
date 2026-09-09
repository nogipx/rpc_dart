---
round: 223
commit: 0e7b984a
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
scope: [wasm]
---

# C-23 — a guest promise rejection is reported on iOS and lost on Android

The lead this closes said "there is neither an `unhandledrejection` event nor a
host callback". **That is false on iOS**, and the lint refusing a negative
without a control is what forced the check that found it. Rule one: the prose
was a secondary source and it was wrong.

## Measurement

Searched both native plugins for any rejection or error hook:

```
grep unhandledrejection|onUnhandled|rejectionHandled|      1 hit
     setConsoleCallback|WebViewClient|addWebMessageListener
     over ios/ and android/

  ios/Classes/RpcDartWasmPlugin.swift:162
      window.onunhandledrejection = function(event) { ... }
  android/.../RpcDartWasmPlugin.kt                        no hit
```

iOS installs it deliberately, and the comment above it names this exact class:
"A Dart guest's unawaited failing Future arrives HERE, not in onerror: a rejected
promise is not an error event." It sits next to a `window.onerror` handler, and
both route into `_rpcOnFailure`, which reports through `rpcBoot` before boot and
`console.error` after.

Android's boot script has neither. It has a synthetic `console` object
(`RpcDartWasmPlugin.kt:176`) drained by `_rpcDrainConsole()` and shipped to Dart
over a `rpc_dart_wasm/<id>/console` channel, plus `try/catch` around each
microtask and timer callback — so a SYNCHRONOUS throw is reported. A rejected
promise reaches none of them.

## Control

The same grep, over the same two directories, **finds the iOS handler**. So the
search can see a hook where one exists, and Android's zero is an absence in the
code rather than a failure of the instrument.

## Why it is accepted rather than fixed

The asymmetry is not an oversight, and the fix is not "do what iOS does":

1. **The mechanism does not port.** iOS runs the guest in a WKWebView, which has
   a real `window` and the HTML event loop that defines `unhandledrejection`.
   Android runs it in androidx.javascriptengine's `JavaScriptIsolate` — a bare
   V8 sandbox with no DOM and no HTML event loop, so there is no such event to
   subscribe to. V8's embedder-level `SetPromiseRejectCallback` is not exposed
   by the library.
2. **What is left is disproportionate.** With no event and no host callback, the
   only route from inside JS is wrapping `Promise`, which changes the semantics
   of every dart2wasm guest promise, for everybody.
3. **The population is nearly empty.** A Dart error is ZONAL before it ever
   becomes a JS rejection, and the guest bootstrap is our own code. What remains
   is non-Dart code running inside our guest — not a supported use case today.
4. **It cannot be verified here.** Confirming a `Promise` wrap does not break the
   ordinary path needs a real `.wasm` fixture and a booted device, the
   `test:wasm:device` toolchain this environment does not reliably have.

## What would reopen it

Non-Dart guest code becoming supported, or androidx.javascriptengine exposing a
rejection callback — at which point the fix is a subscription rather than a
`Promise` wrap, and reason 2 disappears.

Lens: `../lenses/RPC-06-native-plugin-layers.md`. Lead, now closed:
`../backlog/B-02-wasm-android-promise-rejection.md`.
