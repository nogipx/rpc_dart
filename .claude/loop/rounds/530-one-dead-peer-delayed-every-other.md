---
round: 530
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-14
bench: P-163 — new
commit: yes
---

# Round 530 — one dead peer delayed every other

## Target

B-134, next in rank order: `RpcWebSocketServer.stop()` closes endpoints one at a time, so N
dead peers cost N x the close timeout.

Lens RPC-14 — a timeout that abandons work — read from the other end: here the timeout does
its job, and the defect is that everything else QUEUES behind it. The lens's detector asks
who waits on a bounded operation; this asks what else is waiting on that wait.

## Hypothesis

Shutdown is the sum of every peer's close handshake rather than the longest one.

## Before

```
  arm                                    stop() took
  1 peers, close takes 300ms             316ms
  5 peers, close takes 300ms             1512ms
  20 peers, close takes 300ms            6057ms
  CONTROL 20 peers, close is instant     1ms
```

Bench `../probes/P-163-is-shutdown-linear-in-connections.md`.

CONFIRMED, and exactly linear. The control at 1 ms is what says the cost is the close and not
per-endpoint bookkeeping — without it, a change that sped up the bookkeeping would have
looked like the fix.

**The per-peer cost is a stand-in, chosen deliberately.** The real one is dart:io's close
timeout for a peer that never answers, which is seconds; driving that needs a raw TCP peer
that completes a handshake and goes quiet, and it makes every arm slow. What is under test is
the serialisation, so the rig fixes the per-peer cost and varies N. At dart:io's real timeout
the same shape puts twenty dead peers around a hundred seconds.

## Mechanism

`for (final endpoint in ...) { await endpoint.close(); }`. A socket close is a handshake with
the peer, so each iteration waits on a different remote party — and nothing about those waits
is sequential.

## After

```
  1 peers    316ms
  5 peers    304ms
  20 peers   304ms
```

`Future.wait` over the snapshot, with the failure caught PER endpoint rather than by the
group: `Future.wait` abandons the remaining futures on the first error, which would leave
endpoints open with nothing left to close them.

## Canary

Put back to `await` in a loop: the witness fails `Expected: a value less than <1228> /
Actual: <6054>`, quoting both arms. The control passes in that state.

The witness carries a second assertion the probe cannot: every sink must record that its
close was CALLED. Fast is also what abandoning the endpoints looks like, and that arm is what
tells the two apart.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package:
220 passed.

## Not fixed

**No real socket was involved.** The dart:io close timeout is read from the lead and from the
shape, not measured; the probe's 300 ms is a stand-in. A round wanting the real magnitude
would build a raw TCP peer that completes the WebSocket handshake and then ignores the close
frame.

**`drainTimeout` is untouched and unmeasured.** Every arm passes null, so the drain that runs
BEFORE this loop — itself a polling wait — was not examined. Whether a drain and a
concurrent close interact well is a separate question.

**The same shape may be elsewhere.** `dispose()` goes through `stop()` so it is covered, but
no sweep was done for other teardown loops that `await` per peer. `stop()` on the HTTP server
is filed separately as part of B-151.

## Links

Lens RPC-14. Bench P-163 (new). Lead B-134 closed. B-151 carries the HTTP server's own
lifecycle items, including a polling drain.
