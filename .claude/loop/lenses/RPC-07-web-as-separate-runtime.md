---
refines: U-03
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the web is a real build target (dart2js)
breaks: "wrong result: the web suite silently fails to compile a whole file, and a green run proves nothing. After that, anything, up to a crash on a target nobody ran."
applied: [219, 227, 285]
status: confirmed (round 090, off-journal)
---

# RPC-07 — The web as a separate runtime

## Shape

Code that is green on the VM and broken on dart2js.

## Detector

`melos run test:web`; literals above 2^53; cancelling an `async*`;
`Random.secure`; codecs available only on the VM; clock resolution.

## Ask

Which files did the web suite silently fail to compile?

## Evidence

An `int.parse` of a literal above 2^53 throws THE WHOLE FILE out of the web
suite without a single message.

**The dart2js bug classes found across the monorepo in the June 2026 web sweep**,
imported from private memory after round 238. `C-25` holds the cancel-deadlock's
own measurement; these are the rest, and they are what the detector should look
for:

- **`async*` cancel-deadlock** — `await sub.cancel()` on a suspended
  `async*`/`await for` generator NEVER resolves on dart2js. The trigger shape is
  `yield` BEFORE `await for`; `await for`-first and `yield*` are safe. Fix by
  bridging through a `StreamController` whose `onCancel` fires the inner cancel
  WITHOUT awaiting it. (No longer reproduces on Dart 3.10.1 — see C-25.)
- **int bit-shift overflow** — `1 << 32` overflows to 0 on dart2js, so
  `Random().nextInt(0)` throws RangeError; fix with two 16-bit draws. Note
  `<< 24` of a byte is FINE: dart2js `<<` keeps Dart int semantics, and the old
  CBOR bug was specifically `ByteData.setUint64` / 8-byte accumulation.
- **`DateTime.now()` is millisecond-resolution on JS** — the microsecond digits
  are 0. Values stay valid; only precision drops, so no test may rely on
  sub-millisecond margins.
- **`String.hashCode` differs between the VM and dart2js** — never use it for
  routing, bucketing or anything persisted that must match across platforms.
- **`Random.secure()` fails on the bare `node` runner** (works on chrome and
  real web): tag such tests `vm || chrome`, or fall back to `Random()` for
  non-secret ids.
- **VM-only codecs vanish on web** — core's built-in gzip is registered through a
  `dart:io` conditional import, so on web only `identity` exists unless the app
  registers `RpcGzipCodec` from `rpc_dart_compression`.

Web is a real target for CLIENTS specifically (Flutter Web), including the
SQLite ones via sqlite3mc-on-Wasm, where the app injects a `CommonDatabase`
through `StorageAdapter(db)` / `SqliteBlobRepository.db(db)` and FFI/`dart:io`
is gated behind `if (dart.library.io)`. The `postgres` and `minio` adapters ARE
VM-only.

Round 219 counted what the gate actually runs, which is the first thing to know
before trusting it. `melos run test:web`, exit 0, twelve suites:

    rpc_dart, rpc_dart_compression (20), rpc_dart_grpc_reflection (95)
        the WHOLE suite, on node
    opentelemetry 4, websocket 4, http 3, log 3, rpc_data 3, blob 2,
    blob_webdav 1, data_sqlite 2, blob_sqlite 2
        one hand-written smoke file each
    isolate 6
        three files, on CHROME, serialised

> **Three packages are covered; nine have a build-and-construct check.** That is
> not an oversight — the rest of those suites bind sockets, which node cannot —
> but "web is covered" is true only of core, compression and reflection.

And the census does NOT establish that the guard would catch this lens's bug
classes: nothing was ablated to see whether a planted 2^53 overflow or `async*`
cancel turns anything red. That is `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md`,
and it is why this lens stays `confirmed` rather than `swept here`.
