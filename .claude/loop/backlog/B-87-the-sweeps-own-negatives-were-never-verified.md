---
status: closed (round 450)
round: 444 — never checked at all, by anyone
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**]
probe: —
reason: cost — nine claimed negatives, each cheap to check and none of them checked; the value is in the ones that turn out false
---

# B-87 — the duplication sweep's own "already shared" list was never verified

## CLOSED (round 450). Eight held, one did not — `checked/C-49`.

All nine checked in one pass. Eight are one implementation in core with the
transports calling it, including the two that looked most likely to hide a second
copy: `drainUntilIdle`'s COUNT is extracted as well, and http2's `ensureGrpcFrame`
CALLS `RpcMessageFrame.parseHeader`/`.encode` rather than re-deriving them.

**"Parity alignment in `RpcStreamIdManager`" is false as written.** True of the
manager — and http2 does not use the manager at all, keeping its own counters and
its own parity rules in both the caller and the responder. Three homes for one
rule, where the sweep's word implies one. Filed as **B-89**, at its real strength:
nothing has been shown to bite.

`bufferedBytes` is worth one line, because it nearly read as a second false
negative: it IS core-only, and its absence in http2 is B-79's finding. Duplication
and coverage are different questions and the sweep's claim was about the second.

The `ff930001` sweep listed what it believed was ALREADY shared and therefore
not worth reporting:

```
  grpc-timeout                          the 5-byte frame and its parser
  percent-encoding of grpc-message      backoff
  -bin base64                           wireStatusFor
  drainUntilIdle                        bufferedBytes
  parity alignment in RpcStreamIdManager
```

**Nothing has ever checked this list.** It is the one part of B-70 that was
never even re-read, and it is the half where being wrong is most expensive: a
false positive in the sweep's findings costs a round, a false negative here
means a divergence nobody will look for again, because it is written down as
settled.

Two reasons to take it seriously rather than as tidy-up:

- **B-63's "Already extracted" list is the checked version of roughly the same
  set** and should be preferred wherever the two overlap. Where B-63 does NOT
  cover an entry, nobody has looked.
- **`drainUntilIdle` is the precedent for why this matters.** It was extracted
  and shared; the COUNT feeding it was not, which is B-63 item 2 — both servers
  take it from a stringly-typed map, so renaming one key makes every graceful
  drain complete instantly with no error. "The loop is shared" was true and
  hid that.

This is a read, not a bench: nine greps, each asking whether the thing is one
implementation or several. Cheap per entry, and the deliverable is a negative in
`checked/` for the ones that hold — which is what stops the list being re-read a
fourth time.

Entries that turn out NOT to be shared get their own numbers and their own
measurements; do not fold them back in here.

## Owner decision

**Take it. Nine greps, all nine, in one pass.**

Prefer B-63's checked "Already extracted" list wherever the two overlap, and
check only what B-63 does not cover — that is the cheap half.

Two rules for the pass:

- Write the negative for every entry that holds. A verified negative is the
  deliverable; without it this list gets re-read a fourth time.
- Verify the WHOLE list before reporting. A partial pass on a list whose defect
  is "nobody checked it" reproduces the defect.

Entries that turn out not to be shared get their own numbers and their own
measurements — do not fold a finding back into this lead.
