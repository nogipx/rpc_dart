---
refines: U-18
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart/lib/src/rpc/transports/**]
applies: one signal carries both "this is terminal" and "this is recoverable, or local" — a lifecycle flag, an error stream, any single channel two readers interpret differently
breaks: a hang; or every in-flight call answered by something that concerned one of them.
applied: [238, 268, 324, 353, 359, 405, 411, 419, 421, 485, 486, 495, 531, 552, 572, 592, 651, 653, 667, 668, 669, 676, 678, 691, 746, 748, 753, 779, 780, 787, 798]
status: confirmed (round 748)
rank: 17
---

# RPC-19 — One flag, two lifecycle meanings

## Shape

A single boolean carries two states that are not the same: **terminal** (the
caller closed us; never coming back) and **recoverable** (no live connection,
recovery expected). Every reader then interprets it in whichever sense suits
that call site, and the interpretations contradict each other — one path says
"reconnect required", another refuses the reconnect because the flag means
"closed". The object need not be a flag: an error stream, a status code on the
wire, a `Map`'s keys, an end-of-stream that conflates two DIRECTIONS.

The give-away is a recovery API that works exactly once.

## Detector

Every `bool _closed` / `_isClosed` / `_stopped` in the classes above. For each,
list its WRITERS and ask whether they all mean the same thing: `close()` is
terminal, but a failed reconnect, a dropped socket and a peer death are not.
Then list its READERS — `health()`, the send paths, the post-factory re-check in
`reconnect()` — and ask what each of them wants to know. A flag that four
readers want four different answers from is the defect. If `close()` is the only
writer, stop: a flag conflates two meanings only where two meanings exist.

The vocabulary both callers settled on, and what a sweep should expect to find:
`_closed` written ONLY by `close()`, `_disconnected` for "no connection,
recovery expected" (14 occurrences across the two caller transports today).

Extensions the rounds below paid for: for a signal, list what can be put on it
(or, from outside, who can PRODUCE it) and its readers; enumerate the ways the
connection can END and cross off which reach a writer; ask what the flag says
DURING the recovery, per await; ask what else the recovery path RESETS (a
counter); for a map, list which KEYS each exit carries.

## Ask

Drive the recovery API **twice, and once while the peer is down.** Does the
second attempt still work? What do the OBSERVERS (`health()`) report during it?

## Evidence

The origin, three defects found by calling `reconnect()` twice and once with the
peer down — the suites called it ONCE per test on a healthy peer; a one-shot
happy-path test of a recovery API proves nothing
(`../lessons/L-08-a-per-test-connection-hides-it.md`):
`RpcHttp2CallerTransport.reconnect()` set `_isClosed = true` on failure, so the
transport told you to reconnect and then refused every attempt (63aa8e93) — **a
previous fix created it**: 48847ffc removed the `_isClosed = false` un-close;
check the writers before deleting a state reset. The websocket caller left the
wrapper `isClosed == false` over a CLOSED `_inner`, a call reached it and status
14 in the ROOT zone killed the isolate (3bfa7715) — *the quiet-close property is
the trap*: `RpcChannelTransport` answers a closed transport silently, so a
wrapper must never hand work to one. And **never `finish()` a dead http2
connection; always `terminate()`** — `_discardConnection()` does it inside
`runZonedGuarded`; shared with `RPC-16-check-before-await.md`. Imported from
private memory in the curate pass after round 234.

- **Round 238** — sweep, no third instance; four failed reconnects into a dead peer then recovery, twice, clean on the websocket caller. **Ablate the observable the bench samples** — removing the `_disconnected` branch from `health()` moved nothing because the bench reads `reconnect()`. `../probes/P-17-retry-until-the-peer-returns.md`
- **Round 324** — re-swept 21 moved files: `_disconnected` 14 code lines, 10 of 11 lifecycle flags single-writer; `RpcClientConnection._isStopped` has four writers and one meaning, `_disposed` the terminal one. Writing `_isStopped = true` on give-up changes nothing (`+120` green) because `connect()` clears it. **A recovery API can be made one-shot by a COUNTER as easily as by a flag** — remove the `_reconnectAttempts` reset and every later `connect()` gives up while 119 resilience tests stay green. `../rounds/324-the-flag-was-never-the-risk.md`, pinned by `resume_after_giving_up_test.dart`.
- **Round 353** — the object was an ERROR STREAM: `RpcWebSocketChannel` sent a plain `RpcException` for a discarded TEXT frame and `RpcChannelTransport` failed both in-flight calls with the connection alive. **When a comment says "not fatal", ask fatal to what.** Of seven `addError` sites across core and five transports, one meant something other than "the connection is gone"; fixed with `IRpcAdvisoryChannelError`. `../probes/P-45-text-frame-blast-radius.md`, `../rounds/353-reported-not-fatal-was-half-true.md`
- **Round 359** — the THIRD state: `_reconnectOnce` set `_disconnected` only on the outcome, so in the handshake window `getMessagesForStream` gave status 14 while sends returned. **The in-window column should equal one of the two controls and equals neither; a flag written from a `catch` describes an outcome, and an outcome is not a state.** Fixed by `_disconnected = true` after `_inner.close()`; the guard is that the window ENDS. `../probes/P-50-calls-inside-the-reconnect-window.md`, `../rounds/359-the-state-nobody-named.md`
- **Round 405** — http2's two `_disconnected = true` writers are both failure handlers (keepalive, reconnect catch), so a server that simply goes away left `createStream()` handing out ids on a dead connection. **A flag whose writers are all on EXCEPTIONAL paths has no value for the ordinary one; gate each arm on the object's own `health()` first.** `../probes/P-90-which-type-escapes-when-disconnected.md`, `../rounds/405-the-guard-that-never-fires.md`, B-61.
- **Round 485** — UNAVAILABLE on the wire has four producers, one about the connection; `_reconnectIfConnectionIsGone` reconnected on any of them, killing a sibling server stream (sockets 2, errored after 4 messages). **Ask the component about itself** — gate on `isHealthy`; for a signal from OUTSIDE, enumerate who can PRODUCE it. The third arm guards the real reconnect (`sockets=2, recovered`; ablated, `RpcNoConnectionException`). `../probes/P-124-what-one-calls-unavailable-costs-the-others.md`, `../rounds/485-unavailable-is-about-the-call.md`, B-94.
- **Round 486** — `RpcClientConnection`, one layer above 353's fix, retired on any error (`cancelOnError: true`): a text keepalive built a second transport and errored the other call. **A distinction is only as good as its furthest reader; the discriminator was not the TYPE; let the thing speak for itself** (act on the connection's ending, not its errors). The second canary kills the STRICT guard. `../probes/P-125-what-one-bad-frame-costs-a-reconnecting-client.md`, `../rounds/486-a-bad-frame-is-not-a-dropped-connection.md`, B-95.
- **Round 495** — the two awaits ahead of 359's fix: inside the close await a call got status 9 not retryable and `health=closed`. **"During the recovery" is not one instant: ask per AWAIT; make each segment separately addressable, with the fixed one as control; ask what the OBSERVERS report.** Trap: `Stream.empty()` ends at once and fakes a drop. `../probes/P-133-which-part-of-reconnect-answers-what.md`, `../rounds/495-the-whole-method-is-one-window.md`, B-104.
- **Round 531** — `RpcWebSocketServer._isRunning` meant "accepting" and "no shutdown in progress"; a `start()` inside `stop()` left new connections torn down or held by nothing. **A conflated flag has two failure modes needing separate arms; a phase that ends early is one the rig never entered; the fix may already exist one layer down** (`_handleConnection` refuses). `../probes/P-164-what-happens-to-a-connection-accepted-mid-shutdown.md`, B-135.
- **Round 552** — one end-of-stream meant "peer finished sending" and "call over", so a peer-opened server stream dropped its window at the start: 510806 msgs with `initialSendWindowBytes` off, 4372 after. **This one conflated two DIRECTIONS; the discriminator `locallyInitiated` was four lines above. A limit restored by accident is a limit with no test; fixing one direction's cleanup can delete the other's** (round 206's pool repayment). `../rounds/552-the-window-was-off-not-loose.md`, `../probes/P-180-what-the-window-actually-charges.md`, B-195, B-218.
- **Round 592** — `RpcWebSocketCallerTransport.health()`'s `_closed` and `_disconnected` early returns dropped the wrapper's counters, giving `Null check operator used on a null value` in a gate run. **For a map-shaped signal, list which KEYS each exit carries; the exits that omit are the states a diagnostic exists FOR.** `../rounds/592-the-diagnostic-that-went-quiet-when-it-mattered.md`, B-219, B-104.
- **Round 667** — `incomingMessages` has three connection-wide readers and three transports wrote one-stream errors to it: `[13,13,13]`, `[3,3,3]`, `[14,14,14]`. Enumerate writers AND readers, per signal. `../rounds/667-one-stream-error-fails-every-call.md`.
- **Round 746** — an open, silent message stream meant "recoverable" to the transport and "online" to `RpcClientConnection`, so after a server restart every call failed for good. Fixed with `IRpcConnectionLossReporting.connectionLost`. **When one signal has two readers, a new meaning needs a new signal, not a new event on the old one.** `../rounds/746-the-connection-that-never-noticed.md`.
- **Round 748** — `RpcClientOnline` meant "factory returned" and "server serving"; the backoff reset on it, so a server that accepts and refuses got base-delay reconnects for ever. The count now resets only on the drop of a connection that held up. `../rounds/748-a-connection-that-drops-at-once.md`.
