---
refines: U-03
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the web is a real build target (dart2js)
breaks: "wrong result: the web suite silently fails to compile a whole file, and a green run proves nothing. After that, anything, up to a crash on a target nobody ran."
applied: [219, 227, 285, 286, 345, 383, 392, 427, 428, 466, 479, 607, 625, 630, 634, 682, 699, 706]
status: confirmed (round 428)
rank: 22
---

# RPC-07 — The web as a separate runtime

## Shape

Code that is green on the VM and broken on dart2js — or equally correct on
both, at a very different cost.

## Detector

`melos run test:web`; literals above 2^53; cancelling an `async*`;
`Random.secure`; codecs available only on the VM; clock resolution.

The dart2js bug classes from the June 2026 web sweep (imported from private
memory after round 238; C-25 holds the cancel-deadlock's measurement):

- **`async*` cancel-deadlock** — `await sub.cancel()` on a suspended generator
  with `yield` BEFORE `await for` never resolves; bridge through a
  `StreamController` whose `onCancel` does not await. (No longer reproduces on
  Dart 3.10.1 — see C-25.)
- **int bit-shift overflow** — `1 << 32` is 0, so `Random().nextInt(0)` throws;
  use two 16-bit draws. `<< 24` of a byte is fine; the old CBOR bug was
  `ByteData.setUint64` / 8-byte accumulation.
- **`DateTime.now()`** is millisecond-resolution on JS.
- **`String.hashCode`** differs between VM and dart2js — never route or persist on it.
- **`Random.secure()`** fails on bare `node`; tag `vm || chrome` or use `Random()`
  for non-secret ids.
- **VM-only codecs vanish** — built-in gzip is a `dart:io` conditional import;
  on web only `identity` exists unless the app registers `RpcGzipCodec`.

Web is a real target for CLIENTS (Flutter Web), including SQLite via
sqlite3mc-on-Wasm (`StorageAdapter(db)` / `SqliteBlobRepository.db(db)`, FFI
gated behind `if (dart.library.io)`); `postgres` and `minio` ARE VM-only.

When a test is runtime-gated, ask whether the FIXTURE forced that or the
behaviour did. Conditional imports split a package by FILE; the web arm is
often the stub arm too, and a stub runs anywhere.

## Ask

Which files did the web suite silently fail to compile? And what does a guard
COST on each runtime?

## Evidence

An `int.parse` of a literal above 2^53 throws THE WHOLE FILE out of the web
suite without a single message.

- **Round 219** — `test:web` runs twelve suites, but only rpc_dart,
  rpc_dart_compression (20) and rpc_dart_grpc_reflection (95) whole; nine have
  a smoke file, isolate 6 on chrome. Three packages are covered; nine have a
  build-and-construct check. Nothing was ablated, so the gate is a census:
  `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md`, and the lens stays
  `confirmed` rather than `swept here`.
- **Round 286** (with 285) — an understated-ISIZE gzip is refused on both
  runtimes, VM in 12 ms (`boundedInflate`) and dart2js/node in 15980 ms (1332x;
  ~65 KiB of wire buys 64 MiB). A platform gap can hide behind a passing test:
  `isize_wrap_bomb_test` was `@TestOn('vm')` for its fixture, and rebuilding the
  fixture to forge the trailer removed the gate. Deferred as B-29.
  `../probes/P-34-isize-understates-on-web.md`.
- **Round 427** — the permanent gap was documented: when a platform difference
  is permanent, the deliverable is the sentence a user cannot derive from the
  API (`maxDecompressedSize`). The figure moved 16% (15980 ms to a median
  13463 ms), so prose carries the shape and the audit test the number; P-34's
  forged trailer cannot canary the VM half (22 ms), see L-15.
  `../rounds/427-the-number-the-decision-asked-me-to-write-down.md`.
- **Round 428** — B-31 sat 118 rounds believing a test needed wider API; the
  channel, wire format and four helpers moved out of the `dart:js_interop` file
  and round 310's fix got a VM test, with less public surface than the approved
  route. Whatever shares a file with `dart:js_interop` is web-only. `spawn`, the
  ready ack, worker-death listeners and `runRpcIsolateManagerWorker` still need
  a browser. `../rounds/428-the-file-the-test-could-not-import.md`.
- **Round 466** — `ws_open_stub.dart` is both the web arm and the portable
  fallback, so the dropped `pingInterval` was measured on the VM: `ws_open_io`
  626 ms, stub NEVER. A platform-behaviour bench needs a peer that does not
  supply the behaviour (a raw-socket server that goes silent).
  `../rounds/466-the-gap-measured-and-two-promises-priced.md`,
  `../probes/P-116-how-long-until-a-web-client-notices.md`.
- **Round 479** — the web heartbeat opens a STREAM, so it met `maxActiveStreams`
  and first closed a healthy connection at the ceiling. A compensating
  implementation runs at a different layer and meets limits the original never
  did; only SILENCE is death. The third arm is also the answer to the question
  the owner actually asked (does a heartbeat compete with a long call for the
  connection WINDOW?) and it is clean: the ping sends only `sendMetadata`, and
  only `sendMessage` consults credit. The named axis was the wrong one, and the
  unnamed one was fatal. `../rounds/479-only-silence-is-death.md`,
  `../probes/P-120-what-a-heartbeat-mistakes-for-death.md`,
  `../probes/P-121-does-the-ceiling-reach-keepalive.md`.
