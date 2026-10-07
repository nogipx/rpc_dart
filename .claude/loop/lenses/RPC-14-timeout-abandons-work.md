---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: there are timeouts around operations that hold a resource
breaks: "unbounded growth: the held resource is never released. On this project the price is a leaked isolate rather than a socket: it holds ports and keeps the process from exiting."
applied: [223, 233, 246, 273, 323, 433, 499, 514, 530, 533, 536, 638, 673, 696]
status: confirmed (round 499)
---

# RPC-14 — A timeout abandons the wait, not the work

## Shape

`Future.timeout` around an operation that holds a resource: the waiter is
released, the operation keeps holding.

## Detector

Grep `.timeout(` and, for each hit, ask: **if this fires LATE and succeeds
anyway, who owns what it produced?** Harmless when the value is data — a ping
reply, a response body. A leak when it is a handle: a socket, an isolate, a
subscription, a file handle.

**The fix, since a `Future` cannot be cancelled, is to ADOPT the abandoned one**
— `pending.then((r) => r.close()).catchError((_) {})` inside `onTimeout`. A
source that then fails late, or never settles at all, costs nothing.

## Ask

What lives on after the timeout fires, and who releases it?

**And the answer may be "the layer below".** Round 273 predicted the shape at
`RpcHttpResponderTransport`'s `readBody().timeout(...)` — a `.timeout` on a
future whose `await for` it cannot cancel — one round after the identical
construct on the same file's `_reject` had proved to need an explicit cancel.
Measured, it stops: 384 KiB accepted after the 408 (the socket's own buffering)
against 16384 KiB in 49 ms with the deadline off. dart:io detaches the body of
a finished exchange, so the response ends the read that the timeout does not.
`_reject`'s drain runs BEFORE any response exists, which is the whole
difference, and it is invisible in our code.

> **Two call sites with the same construct are not the same defect.** Before
> concluding nothing ends an abandoned subscription, ask what else could close
> the stream. `../checked/C-31-the-408-really-does-stop-the-read.md`,
> bench `../probes/P-24-read-after-the-408.md`.

## The wider family — an await another path can interleave with

Imported from private memory after round 239. The timeout is one member; the
shape is "the loser of a race holds a resource nobody owns", and **fixing one
interleaving is not evidence the other is safe** — both callers had the
close-during-reconnect half fixed long before anyone asked about
reconnect-during-reconnect.

    RpcClientConnection connectTimeout   334b3337   the abandoned factory result
    close() DURING reconnect, both       -          re-check after the await and
      callers                                       close what would be abandoned
    reconnect() during reconnect,        473789b9   each attempt opened a
      websocket and http2                75fd517f   connection and the last
                                                    assignment won: ONE ORPHAN
                                                    PER EXTRA ATTEMPT (2 -> 1,
                                                    3 -> 2). Fixed by
                                                    SINGLE-FLIGHT, a second
                                                    caller joining the first

**The family is swept — do not re-hunt it** (round 67). `RpcClientConnection`
measured clean: `_connectingGuard` refuses a second loop and the loop completes
it synchronously after attach, so no window exists — 4x concurrent
`forceReconnect`, a drop racing `forceReconnect`, and repeated drops all gave
`created == closed`, orphans 0. Pinned by
`test/resilience/client_connection_concurrency_test.dart`, because the behaviour
was correct but untested and `_onTransportDropped` nulls the guard deliberately.
`RpcChannelTransport.reconnect()` is documented unsupported and acquires no
resource, so isolate and wasm have nothing to race.

> **The load-bearing guards for a single-flight fix**, both easy to omit: a LATER
> reconnect must still open a new connection (the in-flight marker has to clear),
> and the transport must still SERVE a call afterwards.

## Evidence

Swept across core off-journal at round 067. The isolate package was NOT part of
that sweep — the exception was carried as lead B-04 — and round 223 swept it,
clean. All four sites:

```
.timeout( in rpc_dart_isolate/lib                    4 sites

  isolate_transport.dart:419  first handshake     catch -> teardownStartup()
                                                  kills the isolate, cancels
                                                  all three subscriptions,
                                                  closes all three ports
  isolate_transport.dart:571  ready ack           catch -> hostTransport.close()
                                                  then teardownStartup()
  isolate_transport_web.dart:316 initialization   catch -> abandon()
                                                  closes the transport and
                                                  terminates the worker
  isolate_transport_web.dart:385 ready grace      onTimeout: () {} — DELIBERATE
```

Round 223's verdict was reached by MEASURING, not reading: four spawns against a
synchronously blocking entrypoint all raised `TimeoutException`, none of the
workers reached their post-block marker — so every isolate really was killed,
even mid-busy-loop — and the process exited promptly afterwards.

> **Do not add a watchdog `Timer` to detect "the process is still alive".** A
> pending Timer keeps the event loop alive by itself, so the check reports a hang
> unconditionally. Let the process exit BE the observable and time the run.

The fourth site is the one worth knowing about. Its empty `onTimeout` looks
exactly like this lens's defect and is not: a worker built before the ready
protocol never sends the ack, and hanging those would be a worse regression than
the wait, so proceeding without it is the point. `readySub.cancel()` runs on both
paths, and a post-timeout error from the abandoned `Future.any` is swallowed by
`timeout`'s own handler rather than reaching the root zone. U-01 applies: the
comment justifying it was treated as a lead and checked against the code, not
taken as a closed door.

Round 233 pointed the same detector at `rpc_dart_websocket`, which is NOT in
this lens's paths and never has been:

```
  .timeout( | Timer( | Timer. | Completer   whole package    0 hits
```

**Absent, not guarded** — a stronger result than a clean sweep, and the reason
the paths above still do not list websocket: adding it would claim a sweep where
there was nothing to sweep. The control is round 223's identical grep, which
returned four sites in `rpc_dart_isolate`.

## What the sweep does NOT establish

Every site is guarded, and **no test would notice if a guard were removed.**
With `teardownStartup()` deleted from the failed-handshake path, so a stuck
isolate and its ports are left behind, the isolate suite still passes (`+73`).
So this verdict is "the class does not arise today", not "the class cannot
arise". See `../lessons/L-04-a-guard-with-no-witness.md`; the witness needs the
subprocess shape `close_releases_the_isolate_test.dart` already uses.

**Round 323 built it, for the READY deadline.** `startup_failure_releases_the_isolate_test.dart`
spawns a synchronously blocking worker with a 500 ms `startupTimeout` and asks
whether the host process exits. Both halves of that path are load-bearing and
were canaried separately — `teardownStartup()` for the isolate and the
error/exit ports, `hostTransport.close()` for `hostReceivePort` via the
channel's `onClose` — and removing either leaves the child `still running`.
The suite went `+73` to `+74`, and under the ablation reads `+73 -1`: the only
red is the new test, so nothing that already existed watched this path.

> **Which deadline is reachable is decided by the bootstrap's ORDER.** The
> worker sends its handshake SendPort at `isolate_transport.dart:257`, before it
> calls the entrypoint at 285 — so no user code can make the FIRST handshake
> time out, and a test aiming at line 417 lands on 545 instead. The first
> handshake path is still unwitnessed; its teardown is a strict subset of the
> ready path's, which is a weaker statement than a canary.

The core sites have never been listed here. Round 323's count, for the next
sweep to compare against: 7 in `rpc_dart/lib`, of which 2 hold something and
handle it deliberately (`client_connection.dart:514` adopts the abandoned
attempt; `call_scope.dart:222` abandons a USER disposer by design and logs it)
and 5 wait on data. `base_endpoint.dart:203` is the near-miss — a timeout around
`close()`, which produces no handle, and dart:async drops a post-timeout error
instead of raising it.

## Round 433 re-swept it, 110 rounds and 57 changed files later

```
                         round 323   round 433
rpc_dart/lib                 7           7
rpc_dart_isolate/lib         4           4
```

Same eleven sites and the same disposition; every line number has moved, two of
them in the same session that re-swept (`client_connection.dart:514 -> :609`,
`isolate_transport_web.dart:316 -> :124`).

> **A lens that records its COUNT can be re-swept for the price of one grep.**
> That is what made this the cheapest round available and why the instruction to
> record it, written in 323, paid for itself. A lens that records only a verdict
> gives the next sweep nothing to compare against and has to be re-derived.

The one site worth re-reading rather than re-counting was
`client_connection`'s: round 430 put a `TypeError` catch inside that timeout
region, and this lens's whole subject is what the abandoned future does.
`_discardAbandonedAttempt` ends in `.catchError((Object _) {})`, so the downcast
430 made possible is caught there rather than reaching the root zone.

The control, repeated from 323 because the code has moved: skipping
`teardownStartup()` on the ready path fails
`startup_failure_releases_the_isolate_test` at 20 s with the child *still
running*. Ten of the eleven sites remain unwitnessed, which is what
`## What the sweep does NOT establish` says and still says.

`../rounds/433-the-count-that-did-not-move.md`.

## Round 499 — the mirror: a wait with no timeout at all

Every earlier application asks what a FIRED timeout leaves running. Round 499 is
the other side: a wait that could not fire, on the one path whose entire purpose
is to notice a peer that has stopped answering.

`ping()` pre-checks its context — `throwIfCancelled()`, `isExpired` — and then
never reads it again. The deadline goes out as `grpc-timeout` and bounds the
SERVER; locally `execute` bounds the wait only `if (timeout != null)`, meaning the
explicit argument alone:

    timeout: 200ms              222ms   bounded
    context deadline 200ms     3003ms   the PROBE's budget
    token cancelled at 200ms   3002ms   the PROBE's budget

> **A deadline SENT is not a deadline ENFORCED.** The header made the intent
> visible on the wire, which is what made the gap easy to miss: everything about
> the call said 200 ms except the code that waits. For every place a bound is
> transmitted, ask who applies it locally.

> **Sweep the keepalive first.** This lens's targets are ordinary calls, where an
> unbounded wait is one hung call. On a health check it is the mechanism that was
> supposed to detect the hang — the failure and the detector share a code path,
> so the detector fails exactly when it is needed.

A method note worth reusing: the RTT was two `DateTime.now()` readings, and a
clock step cannot be caused in a test — but `sentAt` is a CONSTRUCTOR PARAMETER,
so injecting an hour in the past stands in for the step and the ablation reads
`1:00:00.012557`. **When a clock cannot be moved, look for the timestamp that is
already injectable.**

`../probes/P-137-does-ping-honour-its-context.md`,
`../rounds/499-the-keepalive-hung-on-the-case-it-exists-for.md`, B-108.

## Round 514 — a wait that does not notice it is over

The third reading of this lens. Not a wait that gives up too early, nor one with no
bound at all, but one that **finishes late because nothing tells it to stop**. The
responder's drain polled every 50 ms, so work that completed 1 ms in still took
`52 ms`.

**The detector: for every wait, is it signalled or asked?** A polled wait has two
costs — the latency up to one interval, and the interval being a compromise somebody
chose between latency and waste. A signal removes the compromise. Look for
`Future.delayed` inside a `while` whose condition reads a field that some other code
path already updates; that other path is where the signal belongs.

> **Place the signal where the CONDITION becomes true, not where it is convenient.**
> Here `_cleanupStream` returns early when the id had no state — but the drain waits
> on the COUNT reaching zero, which is true either way, so the signal goes above that
> return.

> **The guards go on the opposite failure.** Replacing a poll with a signal risks a
> wait that ends too soon, which is worse than the latency: a drain that abandoned
> in-flight calls, or a completer that replaced the deadline so a stuck handler hung
> the deploy. Both get their own arm.

> **And the control may pay twice.** The arm where the work genuinely takes longer
> than the interval exists to prove the wait still waits — and it also showed polling
> added ~36 ms of rounding even THERE (`156 ms` against `122 ms`), which is a finding
> the lead did not contain.

The wall-clock half of the same lead was fixed without evidence, and the record says
so: `DateTime.now()` deadlines became a Timer and a `Stopwatch` on the argument
`RpcCircuitBreakerInterceptor` already documents. Compare the note above about
`sentAt` — when a clock cannot be moved, sometimes there is no injectable stand-in
either, and then reasoning has to be labelled as reasoning.

`../probes/P-152-how-long-does-a-drain-take.md`,
`../rounds/514-the-drain-waited-for-a-tick.md`, B-123.

**Round 530 read the lens from the other end.** The timeout there is dart:io's close
handshake, and it behaves correctly; the defect is that everything else QUEUES behind
it. `RpcWebSocketServer.stop()` awaited each endpoint's close in a loop, making
shutdown the SUM of N independent waits on N different peers:

    1 peer, close takes 300ms       316ms
    5 peers                        1512ms
    20 peers                       6057ms
    CONTROL 20 peers, instant         1ms

`../probes/P-163-is-shutdown-linear-in-connections.md`, B-134.

> **Ask what else is waiting on the bounded wait.** The detector's question — who
> waits on an operation with a deadline — finds the operation. The follow-up is
> whether anything SEQUENTIAL is behind it that need not be, because a correct
> per-peer bound becomes an incorrect total the moment it is summed.

> **When the real cost is slow to reproduce, fix it small and vary N.** The honest
> magnitude here needs a raw TCP peer that completes a WebSocket handshake and then
> ignores the close frame. The PROPERTY is the serialisation, which a 300 ms stand-in
> shows in six seconds instead of a hundred — provided the record says the stand-in is
> one.

> **`Future.wait` is not a drop-in for a loop of awaits.** It abandons the remaining
> futures on the first error, so the failure has to be caught PER item or a teardown
> leaves work undone. And the witness needs an arm proving each item was still
> REACHED: abandoning them is also fast.

**Round 533 — the canonical shape, and the file's comment had already named it.**
`openWebSocket`'s `connectTimeout` said out loud that `Future.timeout` abandons the
AWAIT and not the WORK, then handled only the half where the work succeeds LATE. The
half it did not: a connect that never arrives.

    baseline TCP fds                              0
    CONTROL 40 opens that succeed and close       1   (the local listener)
    40 opens to a BLACK HOLE, 100ms timeout      40

`../probes/P-166-does-a-timed-out-connect-hold-its-descriptor.md`, B-137.

> **A comment that states the lens is not a fix for it.** This one is unusually good —
> it names the mechanism and cites where core learned it — and it covered one of two
> directions. Read what a correct explanation DOES, not what it knows.

> **Count the leaked thing from outside the runtime.** A held descriptor leaves the
> process working, the socket invisible to Dart, and the attempt failing on time. Every
> in-process observable sits behind a retry schedule the OS owns, so the count came
> from `lsof` — and both of the rig's assumptions (lsof exists, the address really is a
> black hole) are ASSERTED, because either failing silently yields zero.

> **Cancelling needs something that owns the work.** A `Future` owns nothing. The fix
> was to give the attempt its own `HttpClient`, because that is the object a timeout can
> take down; the shared one leaves the timeout with nothing to do but stop waiting.

> **The canary has to remove the FIX, and the fix is not always the newest-looking
> line.** Two ablations here read green — plain close instead of forced, and
> `connectionTimeout` removed — because each left the other mechanism standing. Only
> reverting to the SHARED client failed. Ablate the thing you claim, and if it passes,
> suspect the claim before the rig.

**Round 536 — a teardown that freed the ACCOUNTING and not the work.** The third form
of this lens in seven rounds: 530 found work queued behind a bounded wait, 533 a timeout
with nothing to cancel, and here `releaseStreamId` on the HTTP/1.1 caller removed
`_pending`, `_activeStreams` and the id while the POST and the body read ran to
completion.

    call abandoned at 300ms    40 of 40 chunks written    server finished
    CONTROL not abandoned      40 of 40 chunks written    server finished

`../probes/P-169-does-abandoning-a-call-stop-the-download.md`, B-140.

> **When both arms agree, that IS the finding — provided the arms differ.** Two
> identical rows usually mean a broken rig (round 531 hit exactly that). Here they mean
> abandoning changed nothing, and what makes the difference legible is that the control
> separates AFTER the fix: `21 of 40 / not finished` against `40 of 40 / finished`.

> **Read the abandoned side from the OTHER end.** A dropped future reports nothing
> locally whether the work stopped or not, so the client cannot answer the question at
> all. The server's own progress can.

> **Freeing a slot without stopping the work inverts the limit.** `maxActiveStreams` is
> returned by the same call that abandons the socket, so a cancelling client gets its
> concurrency back while still holding the connection — the ceiling stops bounding real
> sockets exactly when it matters most.

> **Cancellation must report NOTHING.** The abort is this side's own doing, so it gets
> its own catch branch above the general handler. Surfacing it would answer a stream the
> endpoint has stopped listening to, and logging it at error would make ordinary
> teardown look like breakage — which is the guard, and it is as load-bearing as the fix.
