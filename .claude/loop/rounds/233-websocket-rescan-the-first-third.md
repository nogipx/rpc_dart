---
round: 233
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-14
bench: none — the detector is a grep plus reading; the absence of the form is the measurement
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 9 of 10, Q2 recorded as a NO in `## Not fixed`
commit: yes
---

# Round 233 — websocket rescan, the first third

## Target

B-06 — rescan the websocket package, whose lead list went stale off-journal.
Departed from `next` (lens RPC-01, whose lead is with the owner) because the
owner asked for the backlog and this is the priority transport.

The lead's own instruction is the method: **"work by rescanning it rather than
from a list"**, since that is how the orphaned-socket defect was found.

## Hypothesis

1578 lines across nine files, last swept off-journal. Some active lens shape has
an instance here that no round has looked for.

## Before

Started with the shape that has never covered this package at all. RPC-14's
paths are `core` and `isolate` only — websocket is not in them, so "a timeout
abandons the wait, not the work" had never been asked here:

```
  .timeout( | Timer( | Timer. | Completer   across the whole package    0 hits
```

**The form does not exist here.** Not "guarded" — absent. RPC-14 cannot arise in
a package with no timeouts, no timers and no completers, and that is a stronger
statement than a sweep of guarded sites.

## Mechanism

Nothing is wrong in what was read, and the reason is worth recording: this
package carries its measurements in its comments, at every decision.

```
  channel close()            unawaited(_incoming.close()) — with the measurement
                             for why: "no listener: close() still pending after
                             3s, forever; listener: close() returns"
  closeForProtocolError()    same shape, same guard, idempotent via _closed
  onDone close-code triage   four codes measured byte-for-byte identical before
                             the fix; 1000/1001/1005/1006 deliberately excluded
                             because raising on 1005 broke three reconnect tests
  _releaseEndpoint           removes AND closes, with the history: "the responder
                             branch merely removed the endpoint from the list,
                             and the peer branch did nothing at all ... one leak
                             per client disconnect"
  _notify                    every observability callback wrapped, because these
                             run detached where a throw reaches the root zone
```

`_endpoints` looked like the best candidate for unbounded growth — a `List` that
grows per connection — and it is removed and closed on disconnect, on both
branches, with the previous defect described in place.

## After

n/a — nothing changed. `git diff` empty.

## Canary

n/a — no fix. The grep IS the instrument for the RPC-14 half, and its control is
that the same grep finds hits elsewhere: the identical pattern returned four
sites in `rpc_dart_isolate` at round 223, which is what says a zero here is an
absence rather than a broken search.

## Gate

No code changed. The gate proper is the one HEAD passed at the round-231 hotfix.

## Not fixed

**Q2 is a NO, and the scope has to be stated honestly: this covered a third of
the package.** Read in full: `rpc_websocket_channel.dart` (251) and the
resource-lifecycle half of `rpc_websocket_server.dart` (365). Covered by grep
only: `websocket_io_connections.dart` (249). **Not read at all:
`websocket_caller_transport.dart` (493 lines)** — the largest file and the one
that holds reconnect, which is where this package's last two defects were.

So B-06 stays OPEN with its scope narrowed rather than closed. What this round
buys the next one is that it need not redo the three forms above.

**A package that documents its own measurements is expensive to re-audit and
cheap to trust.** Every comment here names what was measured and what broke;
re-deriving those would cost more than the sweep and find nothing. The value is
in the file nobody has read, not in the ones that explain themselves.

## Links

Lead `../backlog/B-06-websocket-lead-list-is-stale.md` — scope narrowed, still
open, with the unread file named.
Lens `../lenses/RPC-14-timeout-abandons-work.md` — `applied: [233]`, and its
paths do NOT gain websocket: the form is absent, so adding the path would claim
a sweep where there was nothing to sweep.
Round `223-the-isolate-exception-closed-and-a-pattern.md` — the same grep, four
hits, which is this round's control.
