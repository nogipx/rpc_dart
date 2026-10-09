---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: there are paths that run user code outside a guarded zone — or inside one that was never meant to catch it
breaks: a process crash.
applied: [222, 225, 242, 330, 346, 347, 356, 358, 368, 431, 443, 480, 483, 500, 535, 557, 577, 639, 647, 712, 744, 747]
status: confirmed (round 747)
rank: 19
---

# RPC-13 — An unhandled async error is fatal to the isolate

Anything added to an accept loop or to a stream's event handler runs in the root
zone — ask what a platform accessor does on malformed input BEFORE putting it
there.

## Shape

A future running user code is abandoned with no error handler; in Dart that
kills the whole isolate. A dropped future is a SHAPE, not a defect; the defect is
a dropped future that completes with an error.

## Detector

Calls that spawn a future without `await` and without `.catchError`, on paths
that run user code: dispatch, lifecycle callbacks, connection accept loops.
Enumerate with dart-runner `find_references` on `unawaited`, then reconcile
against a grep count of the same `lib/` trees (a Flutter package resolves
`dart:async` from `sky_engine`, a different element).

**And `async` callbacks handed to `Stream.listen`** — `onData`, `onDone`,
`onError` alike. Nothing awaits the future such a callback returns, so it is an
`unawaited` that does not look like one and no grep for `unawaited(` finds it.
`grep -n "async {" ` over the shapes. The `onError` parameter is not a guard for
the callback's own throw; it only receives errors from the stream.

Also `runZonedGuarded` (one site in the workspace's `lib/`) and any sink `add`
that forwards through a StreamController.

## Ask

If this throws, who catches it? Is there a zone, and is it the right one? Who
THROWS on the path, not only who catches? And what would notice if the guard
were removed?

## Evidence

One hole found and closed early; a sweep across all five transport packages (the
121 sweep, off-journal) showed every other site already guarded.

- **Round 222** — re-ran after rounds 206-212 added `unawaited(...)` calls: ~85
  sites, all guarded (`_detached`, bidi dispatch, http2 trailers/GOAWAY, websocket
  refusal, `_fcSendGrant`). Ablating `_detached`'s `.catchError` left the core
  suite green (`+1395 ~1`).
- **Round 242** — the thrower, not the site: `forceReconnect()`'s
  `detach().then(...)` ran the user's `onStateChanged` unguarded (round 235 had
  only made `detach()` unable to reject); 1 unhandled before, 0 after. Ask who
  THROWS on the path; a sweep proves the sites are guarded today, not tomorrow.
  Bench `../probes/P-20-throwing-state-callback.md`,
  `../backlog/B-20-detached-guard-has-no-witness.md`.
- **Round 356** — `RpcWasm.run`'s `runZonedGuarded` swallowed a synchronous boot
  throw and returned an uninitialised `late` (`LateError` instead of the
  `StateError`). Measurement checklist D2 applies to the zone's OWN body too; the
  retry after a failed boot deleted the LIVE handler, found because the witness
  booted twice (U-15). Bench `../probes/P-48-boot-failure-on-a-real-guest.md`,
  `../rounds/356-the-zone-ate-the-reason.md`.
- **Round 358** — `RpcWebSocketChannel.send`'s throw is not on the call stack: a
  sink's `add` is a queue, run in the zone the controller was constructed in (look
  for `runUnaryGuarded` between your call and the throw). The construction zone is
  the lever; only our OWN raw socket closed in the same turn reaches it, not a
  peer close. Deferred to
  `../backlog/B-39-websocket-send-throws-into-the-root-zone.md` (sibling of B-35).
  Bench `../probes/P-49-send-into-a-dead-socket.md`.
- **Round 368** — `async` callbacks to `Stream.listen`: 11 found, 5 guarded, 6
  not. `BidirectionalStreamCaller.requestSink` awaited `CallProcessor.send`'s
  `RpcStatusException(14)` (by design since round 330): 1 uncaught before, 0
  after. The sibling IS the control when the same job is written twice; a zero
  needs its own control (a deliberate throw that must report 1).
  `../probes/P-59-the-four-shapes-under-the-same-edge-case.md`,
  `../checked/C-40-the-four-shapes-agree-on-the-ordinary-edge-cases.md`,
  `../rounds/368-the-callback-that-could-kill-the-process.md`.
- **Round 431** — B-39 reproduced 73 rounds later; a construction-zone guard only
  protects objects whose construction you own, and only the application can close
  the raw socket, so guard and defect are disjoint. Ask who can REACH the resource
  before placing the zone; a doc sentence shipped instead.
  `../rounds/431-the-guard-that-guards-nobody.md`.
- **Round 443** — B-39 closed with the defect live, safe because
  `send_after_raw_socket_close_test.dart` (4 tests) runs in the ordinary suite,
  not `.dart_tool/probe/`. A lead can close on a live defect if it leaves a
  detector that runs unattended; check whether the evidence is in the gate.
  `../rounds/443-a-guard-declined-on-its-own-measurement.md`.
- **Round 500** — B-109 refuted: 100 cancelled `asStream` subscriptions fired 0
  callbacks against 100 for the open control; census found no bare
  `cancelled.then(`. A lead whose mechanism is a primitive's semantics is cheapest
  to settle by measuring and dangerous by reading; census anyway. RSS across arms
  is noise (P-128). `../probes/P-138-does-a-cancelled-asstream-detach.md`,
  `../rounds/500-ask-the-primitive-first.md`,
  `../checked/C-58-a-cancelled-asstream-detaches.md`, B-109.
- **Round 535** — `RpcWebSocketServer._handleConnection`'s failure path ended in
  a bare `channel.sink.close()`. Grep the file for its own guard
  (`unawaited(Future.sync(() => channel.sink.close(...)).catchError(...))`);
  `Future.sync` catches a synchronous throw; the witness must answer a real call
  afterwards. `../rounds/535-the-grab-bag-graded-itself-backwards.md`, B-139.
- **Round 557** — `_discardConnection`'s dropped `terminate()` never errors (four
  arms silent, positive control `finish()` escapes). Without a known-escaping arm
  "nothing escaped" and "the rig could not produce it" read the same; a comment
  can attach a true fact to the wrong call (as in round 347).
  `../rounds/557-the-comment-named-a-zone-that-was-not-there.md`,
  `../probes/P-182-where-terminate-s-error-lands.md`, B-178.
- **Round 744** — `find_references` gave 117, grep 128; the 11 in
  `rpc_dart_wasm` were missing. Count with grep and reconcile before calling an
  enumeration complete. One failing site: the foreign-id release in
  `RpcFlutterWasmBridge.load()` (sibling `_releaseNative()` had the `catchError`).
  `../rounds/744-every-unawaited-site-from-the-analyzer.md`.
