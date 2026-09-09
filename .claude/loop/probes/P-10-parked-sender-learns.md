---
file: packages/core/rpc_dart/.dart_tool/probe/parked_sender_learns.dart
round: 221 — the validating round
commit: 7d06201c
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-10 — does a parked sender learn its call is over?

Endpoints over `RpcChannelTransport.pair()`, a 64 KiB window and 8 MiB offered,
so the client fills the window and genuinely parks in `_fcAwaitCredit`. Two
handlers: one that drains everything, and one that consumes NOTHING and answers
after 400 ms while the sender is parked.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/parked_sender_learns.dart`. Written in round 210 and left
UNREGISTERED there, deliberately: that round could not show it would catch a
hang, and said so. Round 221 supplied the ablation it was missing.

## Measures

Whether the caller's call future completes, how long it took, and how many
messages the request generator was pulled for. The pull count is what says the
sender really parked: 17 against a 64 KiB window is one window plus the
overdraft, not a stream that ran to completion.

## Control

Two, and the second is what makes this a bench rather than a probe.

1. **The draining handler** — the case with the stall removed.
2. **An ablation**: `_fcOnGrant` made to refuse every grant, live or not.

```
                          normal              grants refused
  CONTROL drains     completed 'drained'   HUNG, 20 s, 16 pulled
                     0.2 s, 2000 pulled
  CASE    answers    completed 'early'     completed 'early'
          early      0.4 s, 17 pulled      0.4 s, 16 pulled
```

The ablated column is the whole point. Starve the credit path completely and the
draining call HANGS — so the rig sees a credit hang at full strength — while the
call that receives an answer still returns in 0.4 s.

That asymmetry IS the finding this bench exists to hold: **the answer path is
independent of the send path.** A parked sender cannot delay an answer, which is
why the RPC-09 shape does not arise here.
