---
round: 230
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-01
bench: P-11 — reused
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record and the ablation. Approved 10 of 10
commit: yes
---

# Round 230 — the last round

## Target

The lead round 229 left behind: `_fcSendGrant` swallows every failure behind
"a lost grant only matters if the connection is still alive, and a throw here
means it is not". U-01 says that is a lead, not a closed door.

Chosen over `next`'s RPC-01 re-run because it is the same lens, one round in
size, and discharges a thread this journal opened rather than starting one at
the cap.

## Hypothesis

If a grant can fail to send while the connection lives, the peer never learns it
may send more, and the comment is wrong about which failures reach that `catch`.

## Before

The premise holds, by construction. Following what can throw on a grant's way
out — a metadata frame with one header, name and value both `String`:

```
  encodeMetadata -> _encodeMetadataPayload   json.encode over Strings; no throw
                                             path. Every RpcFrameException in
                                             that file is in the DECODE half
  RpcFrameMultiplexedChannel.send            `if (_closed) return;` — a closed
                                             channel is a silent no-op, no throw
  the byte channel                           websocket `_ws.sink.add` throws
                                             only after close; isolate
                                             SendPort.send throws on an
                                             unsendable object, and a Uint8List
                                             always is
```

So the only way to reach that `catch` today is a channel already failing, which
is exactly what the comment claims.

## Mechanism

Nothing is wrong. What the comment gets right is the premise; what it does not
say is that the premise belongs to the CHANNELS rather than to this function,
and nothing enforces it.

## After

n/a — nothing changed. `git diff` empty.

## Canary

n/a — no fix. The ablation is the instrument, and it prices the invariant:
a throw planted at the top of `_fcSendGrant`, on an in-memory pair where the
connection is provably alive.

```
                                 normal        every grant throws
  receiver drains              3072 KiB          64 KiB, wedged at call 0
  receiver never reads         3072 KiB          64 KiB, wedged at call 0
  receiver binds and pauses    1024 KiB          64 KiB, wedged at call 0
  per-stream window OFF        3072 KiB        3072 KiB, never wedged
```

64 KiB is `initialSendWindowBytes` exactly: the sender spends its seed and then
wedges for good, in silence. The fourth row is the control that names the
mechanism — with no per-stream window there are no per-stream grants to lose,
and that arm does not move.

The unablated run reproduced round 228's numbers exactly (3072 / 3072 / 3072,
CASE C wedging at call 4), which is what says the bench had not drifted.

## Gate

No code changed — the plant was reverted in place and `git diff` is empty. The
gate proper is the one HEAD passed at round 229.

## Not fixed

**The trade is a log, and the bar forbids it.** The only remedy for a swallowed
grant failure is to report it, and the config rules diagnostics out as a round's
product. Recorded as [C-26](../checked/C-26-swallowed-grant-failure.md) so the
trade is visible rather than implicit — together with B-05's logging half, this
is the second place in the same subsystem where the honest answer is "it should
say something" and the bar says no. **If the bar is ever lowered, those two are
the first candidates.**

## The cap

This is round 230, the cap set in `config.md`. `status` will now compute
Stop: YES and the recurring job should be cancelled.

Left for whoever picks it up, in the order I would take them:

- **[B-22](../backlog/B-22-paused-consumer-never-repays-the-pool.md)** — awaiting
  the owner, and the only measured unfixed defect: a wedged connection, 4 calls
  against a 1024 KiB pool.
- **[B-06](../backlog/B-06-websocket-lead-list-is-stale.md)** — rescan the
  websocket package, the owner's stated priority transport, whose lead list went
  stale off-journal.
- **[B-11](../backlog/B-11-endpoint-reachability-needs-latency.md)** — needs a
  bench with real latency; three shapes failed on an in-memory pair.
- **[B-21](../backlog/B-21-reconnectable-transport-type.md)**, next major.
- **[B-10](../backlog/B-10-layers-without-lenses.md)** — deferred by the owner
  until core and transport are exhausted; 234 files with no lens.

## Links

Negative `../checked/C-26-swallowed-grant-failure.md` — new.
Bench `../probes/P-11-connection-debt-with-a-paused-consumer.md` — reused, and
its unablated numbers reproduced round 228's.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [230]`.
Round `229-a-zero-grant-is-not-silence.md` — which left this lead.
