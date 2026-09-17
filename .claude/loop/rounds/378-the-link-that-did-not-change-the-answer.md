---
round: 378
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-15
bench: P-68 — new
commit: yes
---

# Round 378 — the link that did not change the answer

## Target

The gap round 377 left at the top of its list, and the one the loop's own data
made uncomfortable: **rounds 370, 371 and 374 each fixed a missing pause and
measured it on `RpcChannelTransport.pair()`.** P-58 exists precisely because
that harness flattens anything the size of a round trip, and back-pressure is
that kind of question. Three FIXED rounds rested on a bench the journal warns
about for their own subject.

RPC-15 — re-measure the loop's own record, including what a round claims its fix
is worth.

The owner suggested toxiproxy, and it turned out to be already installed.

## Hypothesis

The pause forwarding is a property of the in-process pair. Over a link with a
real RTT the bound is different, or absent.

## Before

A consumer that does not read, a 1 MB window, 16 KiB messages, 2.5 s, counted
inside the handler's generator:

```
arm           link              produced of 2000     MB
bidiPump      direct                  70            1.1
serverStream  direct                  74            1.2
bidiPump      toxiproxy 100ms         70            1.1
serverStream  toxiproxy 100ms         70            1.1
```

Probe:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/backpressure_under_latency.dart`
(P-68). Real websocket server on the host, client through toxiproxy with a
50 ms latency toxic on each stream.

**Every value is a good one, so the round rests on the ablation** — and the
ablation had to be run THROUGH THE PROXY, or it would only show the direct rig
is sensitive. Round 374's pause forwarding switched off:

```
arm           link              fixed   ablated
bidiPump      direct              70      2000
bidiPump      toxiproxy 100ms     70      2000
serverStream  direct              74        70
serverStream  toxiproxy 100ms     70        70
```

The defect is visible through the proxy, and the sibling does not move in any
cell. Tree restored, `git diff --stat` empty, re-measured back to 70.

## Mechanism

n/a — nothing is broken. **Latency does not change this answer**, and that is
the finding: it is the opposite of what latency did for P-58's parking question,
where the in-process pair reported `never parks` in every row a real socket
parked in.

Why the two differ is worth keeping. P-58 asked about a state that only EXISTS
while a grant is in flight, so removing the flight time removed the state. This
asks about a bound that is applied by a `pause()` on the consuming side, which
happens whether or not the wire is slow — the RTT changes how long the loop
waits, not whether the loop pauses.

So the in-process numbers in rounds 370, 371 and 374 stand, and now for a stated
reason rather than by default.

## After

n/a — no change made.

## Canary

n/a — no fix. The ablation is the variation, and its placement is the point:
run direct-only it would have proven the wrong rig.

## Gate

`melos run analyze` clean; `fvm dart test -j 8` in core **+1545 ~1**. No
executable line moved — `git diff --stat` empty before the verdict — so round
377's four-gate pass stands.

**Environment left as found**: the toxiproxy container this round created was
removed, and the other project's container, which was already running with three
toxics on its own proxy, was not touched — verified by listing its proxies before
and after.

## Not fixed

Nothing found. The rig now exists for the things it was not asked yet:

- **Bandwidth limits, packet slicing and jitter.** toxiproxy has all three and
  this round used only latency. Slicing is the interesting one for a framed
  protocol — it splits writes at byte boundaries the sender never chose.
- **http2 and isolate under latency.** Only websocket was put behind the proxy.
- `abort()`, a deadline mid-duplex, dart2js.

A trap worth carrying: **reach a docker-published port over IPv4 explicitly.**
`curl http://localhost:18474/...` returned `000` and `curl -4
http://127.0.0.1:...` returned 200 — `localhost` resolves to `::1` first. It is
the same trap the repo's own `test:web` script works around with
`NODE_OPTIONS=--dns-result-order=ipv4first`, met in a second place.

## Links

- RPC-15 — the lens; `applied:` gains 378
- P-68 — the bench; its ablation runs through the proxy, not beside it
- P-58 — the bench whose lesson prompted this, and whose answer went the other way
- Rounds 370, 371, 374 — the three fixes this re-measures
- Round 377 — named this as the largest remaining gap
