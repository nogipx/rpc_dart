---
status: closed (round 223)
round: 223
commit: 0e7b984a
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
probe: —
reason: owner decided (round 223) — accepted, recorded as C-23; the fix changes every guest promise to surface a diagnostic for nobody
---

# B-02 — wasm: an unhandled promise rejection is silently lost on Android

There is neither an `unhandledrejection` event nor a host callback. The only way
to see it is to wrap `Promise` inside the guest, which changes the semantics for
every dart2wasm guest promise and cannot be checked without a real `.wasm`
fixture.

> **Corrected in round 223: that paragraph is wrong about iOS.**
> `ios/Classes/RpcDartWasmPlugin.swift:162` installs
> `window.onunhandledrejection` deliberately, with a comment naming this exact
> class. The gap is a platform ASYMMETRY, not a project-wide absence: iOS runs
> the guest in a WKWebView with a real `window`, Android in
> androidx.javascriptengine's bare `JavaScriptIsolate`, which has no DOM and
> therefore no such event. The "wrap `Promise`" conclusion survives for Android
> only, and for that reason. See
> `../checked/C-23-wasm-guest-promise-rejection-accepted.md`.

The scope is narrower than first recorded: a Dart error is ZONAL before it ever
becomes a JS rejection, and the guest bootstrap is our own code. This is only
about non-Dart guest code.

Lens: `../lenses/RPC-06-native-plugin-layers.md`.

## Owner decision

**Accept it — close as a negative.** (Asked and answered in round 223.)

Recorded as `../checked/C-23-wasm-guest-promise-rejection-accepted.md`, which
also states plainly that it carries no number and why. Reopens only if non-Dart
guest code becomes a supported use case, or if androidx.javascriptengine grows a
host-side `unhandledrejection` hook — at which point the fix is an event
subscription rather than a `Promise` wrap, and the cost argument changes.
