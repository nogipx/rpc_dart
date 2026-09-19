---
round: 396
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-15
bench: P-84 — reused
commit: yes
---

# Round 396 — the collection nobody could count

## Target

C-37's own claim, re-measured. It says all 13 per-stream collections across the
four transports prune, and it read them from each transport's `health()`. But
round 395 hit the gap: **`health()` does not expose `_outgoingPumps`**, so for
that one collection C-37's evidence is a reading — the pump shares a line with
`_incomingStreams` in `releaseStreamId` — not a measurement.

RPC-15: re-measure the loop's own record. It is the pump that matters most of
the 13, because what it holds is a writer parked on the peer's window.

## Hypothesis

`_outgoingPumps` prunes on every path, as C-37 says — but nothing has ever
watched it do so.

## Before

The round's one code change is the instrument: `outgoingPumps` added to
`_buildHealthDetails`. Two consecutive rounds needed it, which is what makes it
a tool rather than a cosmetic.

P-84 reused, one arm added. 200 requests on ONE connection, read while it is
still open:

```
arm                      incoming  subs  parsers  pumps   peer saw
streaming, mid-answer       200      0      0      200    (mid-response)
open, never ended           200    200      0        0    -
served (grpc-status 0)        0      0      0        0    grpc-status 0
half-closed, no body          0      0      0        0    grpc-status 3
refused (:method GET)         0      0      0        0    grpc-status 3
```

**`streaming, mid-answer` is the arm that makes the rest mean anything.** 200
server-streams that answered once and then parked: their writers are live, and
the counter reads 200. Without it, four zeros and a counter wired to the wrong
field are the same output — the same trap round 395's first bench fell into, one
field over.

Its other columns are coherent too, which is a second check on the instrument:
`subs=0` while `incoming=200`, because the client half-closed so the inbound
subscription is gone while the response is still going out — exactly what the
comment at the `onDone` site says it leaves behind on purpose.

## Mechanism

n/a — nothing is broken. C-37's claim holds for the collection it could not
watch, on all four endings driven here: served, refused by the transport,
refused by the pipeline, and abandoned before any answer.

## After

n/a — no behaviour changed. The only diff is the health field.

## Canary

n/a — no fix. The variation is the `streaming, mid-answer` arm: the same
counter, the same connection, the same 200 calls, differing only in whether the
answer has finished. 200 against 0 is the instrument proving it can report
retention.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 15 packages**,
rpc_dart_http2 **+221 ~1**.

## Not fixed

Nothing found. What C-46 listed as uncovered is still uncovered, minus the pump:
the other refusal sites (`validateMetadata`, content-type, the 256-violation
backstop), and a peer that refuses to READ its own refusal.

On that last one, a note so the next round does not mis-plan it: the refusal is
a **trailers-only HEADERS frame**, and HTTP/2 flow control applies to DATA only,
so a zero receive window does not park it. Stalling that path needs TCP-level
backpressure — the peer not reading its socket at all — which is a different
experiment from the window games rounds 272 and 276 used on the other
transports.

## Links

- RPC-15 — the lens; `applied:` gains 396
- C-37 — the record re-measured; its pump claim is now watched rather than argued
- C-46 — round 395's negative, which named this gap
- P-84 — reused, one arm and one column added
