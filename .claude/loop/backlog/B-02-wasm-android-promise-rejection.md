---
status: awaiting owner
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
probe: —
reason: the only way to see the rejection is to wrap Promise inside the guest, which changes the semantics of every dart2wasm promise
---

# B-02 — wasm: an unhandled promise rejection is silently lost on Android

There is neither an `unhandledrejection` event nor a host callback. The only way
to see it is to wrap `Promise` inside the guest, which changes the semantics for
every dart2wasm guest promise and cannot be checked without a real `.wasm`
fixture.

The scope is narrower than first recorded: a Dart error is ZONAL before it ever
becomes a JS rejection, and the guest bootstrap is our own code. This is only
about non-Dart guest code.

Lens: `../lenses/RPC-06-native-plugin-layers.md`.

## Owner decision

—
