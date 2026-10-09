---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: there are timeouts around operations that hold a resource
breaks: "unbounded growth: the held resource is never released. On this project the price is a leaked isolate rather than a socket: it holds ports and keeps the process from exiting."
applied: [223, 233, 246, 273, 323, 433, 499, 514, 530, 533, 536, 638, 673, 696, 701]
status: confirmed (round 499)
rank: 18
---

# RPC-14 — A timeout abandons the wait, not the work

## Shape

`Future.timeout` around an operation that holds a resource: the waiter is
released, the operation keeps holding. The wider family is "the loser of a race
holds a resource nobody owns"; fixing one interleaving is not evidence the other
is safe.

## Detector

Grep `.timeout(` and, for each hit, ask: **if this fires LATE and succeeds
anyway, who owns what it produced?** Harmless when the value is data (a ping
reply, a response body); a leak when it is a handle (socket, isolate,
subscription, file handle).

Since a `Future` cannot be cancelled, the fix is to ADOPT the abandoned one:
`pending.then((r) => r.close()).catchError((_) {})` inside `onTimeout`. Cancelling
needs something that owns the work; a `Future` owns nothing.

Two more readings: a wait with no local bound at all (a deadline SENT is not a
deadline ENFORCED), and a polled wait — `Future.delayed` inside a `while` whose
condition reads a field another path already updates; is it signalled or asked?

Recorded counts for the next re-sweep (round 433): `rpc_dart/lib` 7 sites (2 hold
something and handle it deliberately — `client_connection.dart` adopts the
abandoned attempt, `call_scope.dart` abandons a USER disposer by design and logs
it; 5 wait on data; `base_endpoint.dart`'s timeout around `close()` is the
near-miss), `rpc_dart_isolate/lib` 4 sites.

## Ask

What lives on after the timeout fires, and who releases it? The answer may be
"the layer below" — check what else could close the stream before concluding
nothing ends an abandoned subscription. And what else is waiting, SEQUENTIALLY,
behind the bounded wait?

## Evidence

Core swept off-journal at round 067; isolate (lead B-04) at 223. The race family,
imported from private memory after round 239
(`RpcClientConnection connectTimeout` 334b3337; close() during reconnect;
reconnect() during reconnect in websocket and http2, 473789b9 / 75fd517f, one
orphan per extra attempt, fixed by SINGLE-FLIGHT) is swept — do not re-hunt it
(round 67: 4x concurrent `forceReconnect` gave `created == closed`, orphans 0,
pinned by `test/resilience/client_connection_concurrency_test.dart`;
`RpcChannelTransport.reconnect()` acquires nothing). The load-bearing guards for a
single-flight fix: a LATER reconnect must still open a new connection, and the
transport must still SERVE a call afterwards.

- **Round 223** — all four isolate `.timeout(` sites guarded, measured not read:
  four spawns against a blocking entrypoint all timed out and the process exited.
  The fourth site's empty `onTimeout` (ready grace) is deliberate, checked under
  U-01. Do not add a watchdog `Timer` to detect "still alive": a pending Timer
  keeps the event loop alive by itself; let the process exit be the observable.
- **Round 233** — `rpc_dart_websocket` has 0 hits for `.timeout( | Timer( |
  Timer. | Completer`: absent, not guarded, so websocket stays out of `paths`.
- **Round 273** — `RpcHttpResponderTransport`'s `readBody().timeout(...)` stops
  anyway: 384 KiB after the 408 against 16384 KiB with the deadline off, because
  dart:io detaches the body of a finished exchange. Two call sites with the same
  construct are not the same defect. `../checked/C-31-the-408-really-does-stop-the-read.md`,
  bench `../probes/P-24-read-after-the-408.md`.
- **Round 323** — no test noticed a removed guard (`+73` still green), see
  `../lessons/L-04-a-guard-with-no-witness.md`; built
  `startup_failure_releases_the_isolate_test.dart` (`+74`, ablation `+73 -1`),
  canarying `teardownStartup()` and `hostTransport.close()` separately (cf.
  `close_releases_the_isolate_test.dart`). Which deadline is reachable is decided
  by the bootstrap's ORDER: the handshake SendPort is sent before the entrypoint
  runs, so the first-handshake path stays unwitnessed.
- **Round 433** — re-swept 110 rounds later: 7 and 4, same eleven sites, lines
  moved. A lens that records its COUNT can be re-swept for the price of one grep.
  Round 430's `TypeError` catch is absorbed by `_discardAbandonedAttempt`'s
  `.catchError`. `../rounds/433-the-count-that-did-not-move.md`.
- **Round 499** — `ping()` never re-reads its context: 200 ms deadline waited
  3003 ms. A deadline SENT is not a deadline ENFORCED; sweep the keepalive first,
  because there the failure and the detector share a code path. When a clock
  cannot be moved, look for the timestamp already injectable (`sentAt`).
  `../probes/P-137-does-ping-honour-its-context.md`,
  `../rounds/499-the-keepalive-hung-on-the-case-it-exists-for.md`, B-108.
- **Round 514** — the responder's drain polled every 50 ms, so 1 ms of work took
  52 ms. Place the signal where the CONDITION becomes true (above
  `_cleanupStream`'s early return); guard the opposite failure (a wait that ends
  too soon); the control also showed ~36 ms of rounding (156 vs 122 ms). The
  wall-clock half was fixed without evidence and labelled as reasoning.
  `../probes/P-152-how-long-does-a-drain-take.md`,
  `../rounds/514-the-drain-waited-for-a-tick.md`, B-123.
- **Round 530** — `RpcWebSocketServer.stop()` summed N per-peer close waits: 20
  peers 6057 ms vs 1 ms control. A correct per-peer bound becomes an incorrect
  total once summed; vary N with a small stand-in and say it is one; `Future.wait`
  abandons the rest on the first error, so catch per item and witness each was
  REACHED. `../probes/P-163-is-shutdown-linear-in-connections.md`, B-134.
- **Round 533** — `openWebSocket`'s `connectTimeout` leaked a descriptor per
  black-hole connect (40 of 40 vs control 1), despite a comment naming the lens. A
  comment that states the lens is not a fix; count the leak from outside the
  runtime (`lsof`, rig assumptions asserted); the fix gave each attempt its own
  `HttpClient`; ablate the thing you claim — only reverting to the SHARED client
  failed. `../probes/P-166-does-a-timed-out-connect-hold-its-descriptor.md`, B-137.
- **Round 536** — HTTP/1.1 `releaseStreamId` freed the accounting, not the work:
  40 of 40 chunks written after abandon, 21 of 40 after the fix. Identical arms
  are the finding when the control separates after the fix (cf. round 531); read
  the abandoned side from the other end; freeing a `maxActiveStreams` slot without
  stopping the work inverts the limit; cancellation must report NOTHING.
  `../probes/P-169-does-abandoning-a-call-stop-the-download.md`, B-140.
