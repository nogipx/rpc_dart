---
round: 384
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_isolate, rpc_dart_http2]
lens: RPC-25
bench: P-72 — new
commit: yes
---

# Round 384 — the sibling told the peer and this one did not

## Target

The owner's goal: confirm IN PRACTICE that bidi works under any conditions, on
the transports that support it, priority websocket > isolate > http2.

Every bidi result in rounds 372-376 was taken on `RpcChannelTransport.pair()`,
and round 377 asked only ONE question of the real transports (does a silent
subscription reach the server, C-43). So the scope taken here was: **C-41's
seven endings and P-64's duplex cases, over a real websocket, on a direct link
and on one with a round trip** — the owner's first transport — and whatever that
turned up.

RPC-25 in the end: the defect is a sibling pair that drifted, and the sibling
was both the control and the model for the fix. RPC-15 rides along — C-41's own
record is corrected below.

## Hypothesis

At least one ending or duplex case that is clean on the in-process pair is not
clean over a real socket: the wire puts a round trip between the caller's
decision and the server's reaction, which a pair flattens (P-58).

## Before

The endings matrix over a real websocket, both links, one connection per arm,
three scales — nine counters on BOTH sides plus a unary call after every scale,
because an ending that WEDGES the connection is invisible to counters that only
read zero:

```
arm                direct link            +50 ms round trip
unary (control)    0 everywhere, usable   0 everywhere, usable
normal             0 everywhere, usable   0 everywhere, usable
consumerCancel     0 everywhere, usable   0 everywhere, usable
tokenCancel        0 everywhere, usable   0 everywhere, usable
handlerThrows      0 everywhere, usable   0 everywhere, usable
deadline           5 / 14 / 14 held       5 / 7 / 7 held
neverFinish        0 everywhere, usable   0 everywhere, usable
fullDuplex 30 each way   30/30 ORDER PRESERVED   30/30 ORDER PRESERVED
8 concurrent calls       8 of 8 clean            8 of 8 clean
```

Probe: `rpc_dart_websocket/.dart_tool/probe/bidi_endings_over_socket.dart`
(P-74). The latency link is a Dart TCP relay, not toxiproxy — equal-duration
timers fire in schedule order, so byte order is preserved.

**The deadline row is not a real-transport effect and not a regression.** P-63
re-run unchanged on the pair reads the same way (5 / 20 / 27), and the timeline
says why: the state clears at ~2.2 s, which is `_reclaimGrace`, the documented
backstop for a handler that ignores its cancellation token. A cooperative
handler clears at once.

What it DOES falsify is C-41's own `deadline: 0`, and the reason is worth
keeping: before round 373 a bidi caller holding its request stream open never
sent initial metadata, so that arm measured a call **the server had never heard
of**. 373 made the call arrive and nobody re-ran P-63.
(`rpc_dart/.dart_tool/probe/bidi_deadline_timeline.dart`.)

Both directions saturated at once — 64 KiB window, 32 KiB messages, 400 offered
each way — is clean too, and the one stall recovers in full:

```
arm            direct link                          +50 ms round trip
reading        400 / 400 / 400 / 400                94 / 92 / 92 / 88
paused  (3s)    11 /   6 /   6 /   0                11 /   6 /   6 /   0
        resumed 400 / 400 / 400 / 400               145 / 141 / 141 / 139
requestOnly    400 produced, 400 taken              144 produced, 143 taken
responseOnly   400 pushed,   400 received           142 pushed,   137 received
```

`paused` stalls because the MIRROR handler cannot read a request until its
previous response is sent, which is the application's coupling, not the
library's: `requestOnly` and `responseOnly` each run flat out with the other
direction dead. (`bidi_both_directions_saturated.dart`, P-75.)

Then the defect, found by asking which request-side failures tell the peer.
**Six sites in the class; four announce, two do not, and both are in
`BidirectionalStreamCaller.requestSink`.** One connection, three scales, counters
read after the call and again three seconds later:

```
arm                         1 call   5 calls   20 calls   +3s
sinkAddError                  1         6         26       26
sinkAddStreamErr              1         6         26       26
control-close (half-close)    0         0          0        0
control-abort (explicit)      0         0          0        0
```

`open` / `responders` / `liveHandlers` / `fcSrv.sendCredit` all move together.
It is linear in the call count and **permanent** — nothing reclaims it.

Probe: `rpc_dart/.dart_tool/probe/bidi_request_sink_errors.dart` (P-72).

## Mechanism

A bidi caller's request stream can end two ways, and the handler must be able to
tell them apart: a half-close ends `await for (requests)` normally, an ERROR has
no wire signal at all. `requestSink`'s `onError` logged and returned, so the
peer heard nothing and its handler waited forever — holding the stream state,
the responder, the admission slot and flow-control credit, with
`maxActiveStreams` counting every one.

The sibling is the control: `ClientStreamCaller.call(Stream)` has set
`abortedLocally` on exactly this path and notified the peer since before this
round, and the endpoint's bidi bridge does the same through
`cleanup(abortPeer: true)`. The same job, written three times, and the third copy
lost the clause — RPC-25's shape, on a FAILURE PATH rather than on a helper.

The sibling also carries the second half, which a first attempt at this fix
missed: it notifies **and then closes**. Notifying alone leaves the call
half-alive with the peer still answering a stream this side has reset.

## After

Same probe, same bench:

```
arm                         1 call   5 calls   20 calls   +3s
sinkAddError                  0         0          0        0
sinkAddStreamErr              0         0          0        0
sinkAddStreamErrPaced         0         0          0        0
control-close                 0         0          0        0
control-abort                 0         0          0        0
```

26 -> 0, both controls unchanged.

**The paced arm is the cost boundary and it is why it exists.** A producer that
throws in the same turn as its last message loses that message (`got` 2 -> 1 per
call); one that throws a beat later does not (`got` 2/12/52, identical before and
after the fix). Only a request still in flight when the call is abandoned can be
lost, which is what abandoning a call means.

## Canary

Two halves, two canaries, two different real messages.

**The notice** — `if (1 > 0) return;` in the sink's `onError`:

```
core       Expected: [0, 0, 0]  Actual: [20, 20, 20]
           "after 10s the server is still holding calls the caller abandoned:
            openStreams=20 activeResponders=20 liveHandlers=20"
websocket  "5 handlers are still waiting on request streams that ended"
isolate    "5 handlers are still waiting on request streams that ended"
http2      "5 handlers are still waiting on request streams that ended"
```

Every GUARD (the healthy half-close) stayed green under it. So the defect was
genuinely present on all three real transports, not merely untested — round
377's argument, and the reason one core fix carries them.

**The close** — `abort(...)` kept, `.whenComplete(close)` removed:

```
http2      RpcStatusException(14): HTTP/2 connection to 127.0.0.1:57720 is no
           longer active (the peer closed it or sent GOAWAY); reconnect and retry
```

A different failure from a different cause, which is what a two-half fix needs.

Restored and re-measured green after each.

**The first version of the witnesses asserted after a fixed sleep and that was
wrong** (`tests.md` item 1): they passed alone and failed inside the workspace
gate, because the teardown is the PEER's and a loaded machine makes it late
rather than absent. They now poll to a bound. Re-canaried after the change —
all four still fail, with the same messages, so the poll did not make them
vacuous.

## Gate

`melos run analyze` clean over 21 packages + wasm. `melos run format:check`
clean. `melos run license:check` — 1475/1475, REUSE compliant. Workspace
`test:unit` filter, concurrency 4: **SUCCESS in all 15 packages** — rpc_dart
+1555 ~1, rpc_dart_http2 +217 ~1, rpc_dart_websocket +171, rpc_dart_isolate +78,
rpc_dart_http +126, and the rest. The two `~1` are the pre-existing core skip
and B-53's.

Two things the gate itself taught, both billed here:

- **`melos run test:unit` hardcodes `--reporter expanded`,** which buries a
  failure under ~20 k characters of passing output. The same filter run through
  `melos exec ... --reporter failures-only` names the failing package in one
  line. That is how the http2 red was finally read rather than guessed at.
- **Every one of the 15 packages passes ALONE while the workspace run is red.**
  That is the shape `config.md` warns about, and it was NOT load here: the red
  was a real, reproducible failure of this round's own witness under contention
  (L-14 — the tell is whether it survives the remedy the flake would respond to;
  running it alone is that remedy, and the concurrent run kept failing at the
  same assertion).

## Not fixed

**B-53 — on HTTP/2 a stream reset that races in-flight responses destroys the
whole connection.** Filed, not fixed, and it needs the owner.

It is NOT caused by this round's fix: the public `abort()` does it on its own,
with no new code in the path. Control matrix, five calls per arm, pinging the
same connection after each:

```
arm                                    handler   abort timing        connection
abortWhileEmitting                     answers   30 ms settle        alive
abortWhenIdle                          silent    30 ms settle        alive
abort racing responses, awaited        answers   no settle           DEAD
sinkErrors, before this round's close  answers   from onError        DEAD
sinkErrors, with the close             answers   from onError        alive
endpoint API, erroring requests        answers   via cleanup()       alive
halfClose (control)                    answers   finishSending       alive
```

The close narrows the window enough that the arm is clean when run alone, and
**not enough under load** — the http2 witness still failed with the GOAWAY
inside the workspace gate. So that ONE TEST is skipped, naming B-53; its GUARD
still runs, and core, websocket and isolate carry the witness unskipped. The
skip is the smallest form available and it is still a loosened test, which the
round records rather than files quietly.

What this leaves the owner to decide is the trade this round could not make
alone: on http2 an erroring request sink now goes from *a permanent leak with a
live connection* to *no leak with a connection that can still die under load*.
The leak is gone on the two transports the owner ranked first; http2's remaining
half is B-53's.

Also unfixed, and deliberately: `requestSink`'s OTHER failure path, a `send()`
that throws, still only logs. C-35 measured that catch as unreachable — three
arms, a `print` planted in it, not reached once — so a notice there would be a
line no witness can cover (L-04).

Not covered by this round: dart2js, `RpcWasm`, a bidi call across a reconnect,
and RSS.

## Links

- RPC-25 — the lens; `applied:` gains 384; the sibling was the control
- RPC-15 — C-41's deadline row corrected, see `checked/C-41`
- P-72 — the bench (new); P-74, P-75 — the two that carry the negatives
- C-44 — bidi over a real websocket, the endings and the duplex cases
- C-41 — its `deadline` row falsified and annotated
- C-35 — why the send-failure half is left alone
- B-53 — the http2 half, owner decision
- **L-15 — new**, and the price is C-41's twelve rounds: a bench arm whose
  subject never reaches the code reads exactly like a clean one
- L-04, L-12, L-14 — a guard against an absence needs an ablation; count the
  class before fixing it; a red that reads like a known flake
