---
round: 369
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-25
bench: P-60 — new
commit: yes
---

# Round 369 — OK over three of seventeen

## Target

The owner named **client-stream and server-stream** as the priority, then gave
the use that decides what "correct" means: resumable upload of large,
CDC-chunked files, where re-sending the whole file is the cost being avoided.

RPC-25's detector, as in round 368: ask the SAME question of both shapes and
treat the divergence as the defect. The question the upload use makes decisive —
*can the caller tell that the other side read everything it sent?*

## Hypothesis

One of the two shapes reports a partial read as a complete one.

## Before

17 messages sent, three controls in the same run:

```
                    sent  handler got  caller told          DROPPED logged
shortRead            17        3       OK                         0
shortHold            17        3       OK                         0
fullRead  (control)  17       17       OK                         0
throws    (control)  17        0       RpcStatusException         0
server-stream: consumer read 3 of 17, handler stopped
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/client_stream_short_read.dart`
(P-60).

`fullRead` differs by exactly one thing — whether the handler breaks out of its
`await for` — and answers identically. `throws` proves the bench CAN read a
non-OK ending on this path, so the `OK`s are the call really being reported
successful. `shortHold` holds its answer 400 ms after breaking, keeping the
stream state alive while the peer sends, and changes nothing.

**Server-stream is clean**: its consumer cancelling stops the handler, which is
the right answer, and it is what makes this a divergence rather than a blunt
bench.

## Mechanism

A client-stream handler that stops reading ends the call, and the pipeline
answers `grpc-status 0` — byte-identical to a full read. The later frames are
discarded as trailing frames of a torn-down stream (internal level), so nothing
is logged either. For an upload the caller records the file as stored.

Found alongside, and separable: `RpcResponderStreamState.droppedRequests`
documents itself as *"The pipeline reads it when the call ends, so a handler that
was fed less than the peer sent cannot finish quietly."* `grep` over the
workspace returns the declaration and two increments and **no reader**, and
neither measured path reached it (0 `DROPPED` records on both arms).

## After

n/a — nothing changed. See the verdict.

## Canary

n/a — no fix.

The controls ARE this round's variation: `fullRead` against `shortRead` differ in
one line of handler code and the caller cannot tell them apart; `throws` shows
the same caller CAN be told something other than OK.

## Gate

n/a — no code change. `melos run analyze`, `test:unit`, `format:check` and
`license:check` were green at the end of round 368 and nothing in `lib/` has
moved since.

## Not fixed

**The behaviour, because the fix is a wire change and the choice is the
owner's.** Written up as B-50 with the design argument rather than left as a
bare question, since the owner asked how to do it right for uploads:

- *Resumption is the application's, and its place already exists.* The library
  knows how many messages it HANDED OVER, never how many the handler COMMITTED —
  a handler can be given 17, write 3 and fail. A library-side "accepted" count
  would look authoritative and not be. The response message is where
  `nextOffset` belongs.
- *Honesty of the status is the library's, and is what is missing.* An error is
  the wrong shape: an early answer is USEFUL mid-upload ("I already have this
  chunk"), so failing it breaks a legitimate pattern. A trailer such as
  `x-rpc-requests-consumed`, surfaced to the caller, makes `OK, consumed=3`
  distinguishable from `OK, consumed=17` without breaking anything.
- A mid-upload disconnect is already honest (368 EC2: the caller gets
  `RpcStatusException`), and "how much do you have" afterwards is an application
  round trip — S3 multipart's ListParts, tus's HEAD — not a transport concern.

**Whether `droppedRequests` is reachable at all.** Two paths tried, neither
reached it. The probe budget (3) was spent establishing the caller-visible
numbers, and `measurement.md` item 10 says a bench past its budget makes the
question open, not answered. The false promise in its doc comment is a rule-one
divergence and is the one half of B-50 that needs no owner decision.

**Server-stream got no second look.** It came back clean on this question and on
368's four, and the owner left the choice to the measurements, which pointed at
client-stream.

## Links

- RPC-25 — the lens; `applied:` gains 369, status unchanged (one question, not a sweep)
- P-60 — the bench, three controls
- B-50 — the lead, with the design argument and the owner's decision
- Round 368 — EC2, the disconnect case this one leans on; C-40, the four-shape agreement
- Round 366 — the same class of failure reached from the consumer's side
