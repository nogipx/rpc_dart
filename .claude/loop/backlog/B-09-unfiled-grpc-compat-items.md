---
status: decided by owner (round 415)
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
probe: —
reason: decided — the three survivors were read out of memory, verified against current code in the backlog review, and each given an answer; what is left is three concrete edits
---

# B-09 — Unfiled "documented, not fixed" items from memory

The private memory corpus held separate "documented, not fixed" items about gRPC
compatibility. None of them existed as files.

**The original objection — that filing them would be inventing content with no
number and no probe — turned out to be wrong about its own subject.** The note
declares its own list empty as of round 139, and the three items that survive
each carry a commit and a measurement. They were read, verified against the code
as it is now, and answered.

## What survived, and what the code says today

### 1. HTTP/1.1 cannot round-trip a metadata value containing `", "`

Live at `rpc_http_caller_transport.dart:418` — `value.split(', ')`. The trade has
since moved out of memory and into the code, which documents it as a KNOWN
LIMITATION where "both choices lose something".

**The standard says only one of them is conformant, so the comment is wrong.**

- RFC 9110 s5.3 permits a recipient to combine repeated field lines *"without
  changing the semantics of the message"*, and forbids a sender from repeating a
  field name *"unless that field's definition allows multiple field line values
  to be recombined as a comma-separated list"*.
- gRPC PROTOCOL-HTTP2 defines Custom-Metadata as exactly that field: *"Duplicate
  header names may have their values joined with ',' as the delimiter and be
  considered semantically equivalent."*

So splitting is not a loss, it is the recombination the field's own definition
provides for, and NOT splitting would collapse values the spec calls equivalent.
A metadata value that must carry a comma has a specified home: a `-bin` key,
base64, whose alphabet contains no comma.

**What IS wrong is the delimiter.** gRPC names `","`; RFC 9110 only *recommends*
`", "` ("For consistency, use comma SP"). rpc_dart splits on `", "` alone, so a
peer that joins the way gRPC's own text describes is never split at all.

**And the same narrowness reaches a spec MUST.** *"Implementations must split
Binary-Headers on ',' before decoding the Base64-encoded values."*
`metadata.dart:214` `statusDetailsBin` normalises but never splits. A comma is
in neither base64 alphabet, so `base64.normalize('AAA,BBB')` throws, the `catch`
returns null, and the structured details of an error vanish silently — the exact
failure the comment above that line was written to fix, arriving by another
route. Reachable through any combining intermediary whose join used a bare comma.

**READ, NOT MEASURED.** A round taking this owes a witness for the `-bin` path
before changing it.

### 2. Two HTTP-to-gRPC status tables that disagree

Both read in full:

```
HTTP   rpc_dart_http (1.1)        rpc_dart_http2 (the gRPC table)
400    invalidArgument            internal
429    resourceExhausted          unavailable
504    deadlineExceeded           unavailable
409/410/412/413/415/499/501   mapped        unknown
other >=500   internal            unknown
other >=400   invalidArgument     unknown
```

Most rows differ only in meaning. **One differs in behaviour**:
`RpcRetryInterceptor` retries `unavailable` and `resourceExhausted` and nothing
else, so **a 504 from a gateway is retried over http2 and is not retried over
HTTP/1.1**. The richer table costs a retry on one of the most ordinary answers a
proxy gives.

### 3. Truncation on the channel transports — the blocker is dead

Memory records the fix as written and REVERTED in round 89, because it broke
`endpoint_ping_exchange_errors_test`'s *"fails when stream ends without
trailers"*, which pinned `StateError` — the ping exchange deliberately ends
without trailers.

That test pins `RpcStatusException(unavailable)` today, and says so in its own
comment: *"UNAVAILABLE, not StateError ... Strictly better than what this used
to pin: a StateError is unclassifiable, so retry and circuit-breaker logic slid
straight past it."*

Some later round removed the obstacle and nothing re-read the deferral. **This
is the lesson the memory note itself carries, applied to the note**: when
deferring for blast radius, verify the specific thing you claim would break, or
the deferral is a guess wearing a reason's clothes.

Precision: that test covers "no message, END_STREAM, no status", which was
already UNAVAILABLE. The defect was shape **(d)** — messages delivered, then the
stream cut off with no status, giving `CLEAN END, 2 items, NO ERROR`. So what is
established is that the named blocker is gone, not that the fix now lands clean.

## Owner decision

Taken, one per item:

1. **Split, and widen the delimiter.** The standard decides it: keep splitting,
   accept `","` with optional whitespace rather than `", "` alone, and split
   `-bin` values before decoding, which is a MUST. Rewrite the code comment — it
   currently describes a symmetric loss that the spec does not agree exists.
2. **Fix the 504 row only.** Align it to `unavailable` so a gateway timeout is
   retryable on both transports. The other rows diverge in meaning alone, and
   HTTP/1.1 carrying rpc_dart's own protocol rather than gRPC-over-HTTP/2 makes
   a richer table defensible there.
3. **Measure before fixing.** One probe for shape (d) on the channel transports,
   no fix in the same round. Decide on the number.
