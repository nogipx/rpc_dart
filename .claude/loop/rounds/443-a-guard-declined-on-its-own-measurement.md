---
round: 443
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-13
bench: none — the decision was already measured in round 431; this round
  re-ran the tripwire and closed the lead
commit: yes
---

# Round 443 — a guard declined on its own measurement

## Target

**B-39**, closed on the owner's decision. Round 431 shipped its documentation
half and REFUTED its guard half; the guard needed a word that only the owner
could give, and it has been given: accept it, close the lead.

## Hypothesis

n/a — the measurement was made in 431 and is not re-litigated here. What this
round had to establish is that closing is SAFE: that the lead leaves a working
detector behind rather than a claim nobody can re-check.

## Before

B-39 sat `decided by owner (round 415)` with half the decision deliberately
unexecuted for twelve rounds, because round 431 found the decided guard does
not reach the defect:

```
who built the socket   raw socket reachable   crash reachable   guard helps
the library            no -- never handed out  NO               nothing to help
the application        yes                     YES              cannot reach it
```

## Mechanism

Not a code change. A lead whose fix was measured to cost more than it buys,
left open because declining a decided fix is the owner's call and not a
round's.

## After

`status: closed (round 443)`, with the reasoning in the lead so a later reader
meets the measurement rather than an unexplained close.

**The tripwire was re-run before closing**, which is the whole basis for
closing safely:

```
test/send_after_raw_socket_close_test.dart    4 tests, green
```

It pins that the throw still happens and still lands in the construction zone,
and its three GUARD rows pin what is NOT broken — a live send, a send after our
own `close()`, and a peer close. **The day `package:web_socket_channel` changes
its behaviour, that test goes red and the question comes back on its own.**

That is what makes this different from abandoning the lead. The defect is real
and remains unfixed; what was accepted is that the only fix reaching it reroutes
every async error from every library-built channel to catch a throw that cannot
occur there.

## Canary

The close itself is the risky move, so the check is aimed at it: **does
anything still detect the defect once the lead is gone?**

Yes — and it is a test in the ordinary suite, not a probe under `.dart_tool/`,
so it runs on every `melos run test:unit` without anyone remembering it exists.
A lead closed with its detector left in the gate is a lead that can re-open
itself.

The probe path recorded in the frontmatter
(`.dart_tool/probe/send_into_a_dead_socket.dart`) is NOT that detector and is
not run by anything; it is kept as the reproduction, which is a different job.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

No source changed this round, so the gate is a regression check on the journal
edit rather than on behaviour.

## Not fixed

The defect. A send racing a raw-socket close still throws into the zone the
socket was constructed in, and an application that builds its own raw
`WebSocket` and hands it to this library still sees that throw reach its root
zone.

Options 2 (ship the guard as defence in depth) and 3 (report upstream: a sink
refusing an add should reject a future rather than throw into a foreign zone)
were **declined, not forgotten**, and are written into the lead as declined.

## Links

- B-39 — closed; the tripwire stays in the ordinary suite
- round 431 — the measurement this decision rests on
- RPC-13 — the unhandled-async-error class, to which this is a bounded
  exception rather than a fix
