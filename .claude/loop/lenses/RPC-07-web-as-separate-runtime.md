---
refines: U-03
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the web is a real build target (dart2js)
breaks: "wrong result: the web suite silently fails to compile a whole file, and a green run proves nothing. After that, anything, up to a crash on a target nobody ran."
applied: [219, 227, 285, 286, 345, 383, 392, 427, 428, 466, 479, 607, 625, 630, 634, 682]
status: confirmed (round 428)
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

**Round 286 is the sharpest instance the lens has, and it is not a red test.**
The same gzip payload — ISIZE understating its real output — is refused on both
runtimes, so every assertion passes everywhere. What differs is the COST of
refusing:

    runtime        refused in   mechanism
    VM                  12 ms   boundedInflate aborts at the limit
    dart2js / node   15980 ms   no bounded inflater: 64 MiB inflated, then
                                rejected on result.length

1332x, and ~65 KiB of wire buys 64 MiB plus sixteen seconds of a single-threaded
event loop.

> **A platform gap can hide behind a passing test.** The detector's usual
> question is "does this go red on dart2js"; here the answer is no, forever, and
> the defect is real. Ask instead what the guard COSTS on each runtime — and
> note how it stayed hidden: `isize_wrap_bomb_test` is `@TestOn('vm')` because
> its fixture needs `dart:io`, so the platform without the defence was the one
> the test could not reach. **When a test is runtime-gated, ask whether the
> FIXTURE forced that or the behaviour did.** Round 286 rebuilt the fixture to
> forge the trailer instead of wrapping it, and the gate became unnecessary.

Deferred as B-29 — no fix is worth proposing, since a compressed-size heuristic
is useless at deflate's 1032:1 ceiling and `package:archive` has no incremental
inflater on web. Bench `../probes/P-34-isize-understates-on-web.md`.

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
cancel turns anything red. That is `../backlog/archive/B-18-web-guard-is-a-census-not-a-sweep.md`,
and it is why this lens stays `confirmed` rather than `swept here`.

## Round 427 — a platform difference that cannot be fixed still has to be SAID

Rounds 285 and 286 measured the one gap in this lens that has no repair:
`boundedInflate` aborts a decompression bomb mid-inflate on the VM and does not
exist on web, because `package:archive` materialises the whole output. Every fix
was examined and declined — a compressed-size heuristic is useless at deflate's
1032:1 ceiling, and a different inflater is a dependency decision.

> **When a platform difference is permanent, the deliverable is the sentence a
> user cannot derive from the API.** The limit's own doc said what it enforces
> and not WHEN, and the package README did not mention the limit existed. An
> operator choosing `maxDecompressedSize` had no way to learn that on web the
> bound is a statement about what you accept, not about what refusing costs.

Two things about writing it, both of which cost something here:

- **The figure had moved 16% in 141 rounds** (15980 ms → a median 13463 ms)
  while the finding was intact. So the prose carries the shape and the audit
  test carries the number — a doc with a measured figure in it reads exactly
  like evidence and nothing checks it.
- **The cheap cross-platform fixture cannot canary the VM half.** P-34 forges
  the ISIZE trailer, and `dart:io`'s filter rejects a forged trailer before the
  inflater runs, so ablating `boundedInflate` against it reads 22 ms and looks
  like a fix that survived. See L-15.

`../rounds/427-the-number-the-decision-asked-me-to-write-down.md`.

## Round 428 — the platform boundary is a FILE, not a code path

B-31 sat for 118 rounds on the belief that testing the web channel meant
widening its API, because the class is library-private. It also recorded, as the
reason route 3 was affordable, that "nothing in the channel's failure path needs
`dart:js_interop`" — true, and it does not follow that a test can reach it. A
test imports a LIBRARY, and that library's first two lines are
`dart:js_interop` and `package:web`.

> **Conditional imports split a package by FILE.** Whatever shares a file with
> `dart:js_interop` is web-only whether or not it uses a single JS type, and the
> ordinary suite cannot see it at all. Before concluding that a web-only class
> needs a browser or an annotation to test, ask what else is in its file — the
> answer is often that the platform-neutral half can simply move.

What that bought here, measured by doing it: the channel, the wire format and
the four helpers moved to a file importing `dart:async` and rpc_dart alone, and
the fix from round 310 got an ordinary VM test with a stub `send` and no Worker.
**Less public surface than the approved route**, which would have annotated a
class inside a file the package barrel conditionally exports.

The residue is real and stated: `spawn`, the ready ack, the worker-death
listeners and `runRpcIsolateManagerWorker` still need a browser, and moving the
channel does not change that.

`../rounds/428-the-file-the-test-could-not-import.md`.

## Round 466 — the web implementation is usually the PORTABLE fallback too

428 found the platform-neutral half of a web-only file and moved it. 466 needed
no move at all, because the thing it had to measure was already importable:

> **A conditional import's "web" arm is very often the STUB arm as well, and a
> stub runs anywhere.** `ws_open_stub.dart` is the web implementation of
> `openWebSocket` and the portable fallback, one file. So the web behaviour —
> `pingInterval` accepted and DROPPED — can be measured on the VM, against the
> same server as the `dart:io` arm, differing in exactly the implementation under
> test. Before concluding a web gap needs a browser, check whether its arm is the
> conditional default.

```
pingInterval = 300ms, silent peer, cap 5s
  ws_open_io   (honours it)          626ms
  ws_open_stub (web, DROPS it)       NEVER
  CONTROL: ws_open_io, no interval   NEVER
```

The trap this one had, and it is the mirror of the rule above:

> **A platform-behaviour bench needs a peer that does not supply the behaviour
> for you.** The first instinct is a `dart:io` WebSocket server, which answers a
> ping inside its own implementation — against one of those NEITHER arm detects
> anything and both read clean. The server has to be a raw socket doing the
> handshake by hand and then going silent.

`../rounds/466-the-gap-measured-and-two-promises-priced.md`,
`../probes/P-116-how-long-until-a-web-client-notices.md`.

## Round 479 — closing a platform gap puts the OTHER platform's assumptions in play

466 measured the gap; 479 closed it, and the interesting part is what the
closing cost. The VM gets half-open detection from `dart:io`, which pings at the
protocol layer. Giving the web the same capability means doing it at the
APPLICATION layer — and an application-layer probe allocates things a protocol
frame does not.

> **A compensating implementation runs at a different layer, so it is subject to
> limits the original never met.** `dart:io`'s ping is a protocol frame charged
> to nothing. The replacement opens a STREAM, which means it meets
> `maxActiveStreams` — and the first version read `createStream()`'s
> `resourceExhausted` as "the peer is dead" and closed a healthy connection,
> killing the very calls that had filled the ceiling. Before shipping a
> platform-parity fix, ask what the substitute consumes that the original did
> not.

Measured against a LIVE responder, so every close is a false positive by
construction:

```
at the ceiling (4 of 4 ids held)     CLOSED    ->  open
CONTROL: one id free (3 of 4)        open          open
under a 120000 x 1 KiB stream        open          open
```

The rule that came out of it is worth more than the fix: **only SILENCE is
death.** A probe that could not be SENT, and a probe the peer ANSWERED with an
error, are both evidence the prober is confused rather than that the path is
gone. Only a timeout — nothing came back — means what the heartbeat is for.

The third arm is also the answer to the question the owner actually asked (does
a heartbeat compete with a long call for the connection WINDOW?) and it is
clean, for a reason reading gave before any arm ran: the ping sends only
`sendMetadata`, and only `sendMessage` consults credit. **The named axis was the
wrong one, and the unnamed one was fatal** — which is the argument for measuring
a decision's open item rather than reasoning it away.

`../rounds/479-only-silence-is-death.md`,
`../probes/P-120-what-a-heartbeat-mistakes-for-death.md`,
`../probes/P-121-does-the-ceiling-reach-keepalive.md`.
