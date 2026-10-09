---
round: 584
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-08
bench: P-204 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: breaking
severity: S1
---

# Round 584 — the documented setup was the unsafe one

## Target

`B-150` — `RpcHttpResponderTransport()` leaves `securityPolicy` null, which turns
off every check the transport makes, and the class's own example constructs it
that way. Filed **medium** confidence, `cost`, with `## Why it matters` reading
"The documented setup is the unsafe one".

Lens RPC-08, with the neighbour being a CONSTRUCTION PATH rather than a transport —
round 394's widening. Here the two paths are `RpcHttpServer`, which defaults the
parameter to `const RpcSecurityPolicy()`, and the bare transport, which does not.

Scope decided before the fix: the policy default is the target. The lead's second
claim, about `bodyReadTimeout`, is a different question and is filed rather than
taken — see `## Not fixed`.

## Hypothesis

Everything behind `if (policy != null)` is off in the documented construction, and
the body is fully resident before any layer refuses it.

## Before

```
CONTROL  const RpcSecurityPolicy(), measured FIRST   413   RSS +37 MiB
WITNESS  the policy parameter OMITTED                200   RSS +524 MiB
CONTROL  the same policy again, measured LAST         413   RSS +0 MiB
```

256 MiB uploaded as one declared frame. Probe:
`packages/transport/rpc_dart_http/.dart_tool/probe/b150_what_the_documented_setup_admits.dart`.

**Both orders, because RSS does not come back down between arms.** Without the
trailing control, "the second arm inherited the first's heap" explains the whole
difference; `+0` last is what removes it.

## Mechanism

Four checks sit behind `if (policy != null)`: `maxActiveStreams`, the method path,
the metadata block, and the body read. The same class's RESPONSE side reads
`securityPolicy` — the non-null getter that falls back to the default — so the
response was bounded while the request body was not, three hundred lines apart in
one file. The pipeline reads that getter too, which is why the 256 MiB body is
refused at all: by the time it is, the transport's `BytesBuilder` has all of it.

`RpcHttpServer` has had `securityPolicy = const RpcSecurityPolicy()` and the doc
sentence for it — *"Set to `null` only to disable all limits (not recommended —
this allows unbounded request bodies)"* — the whole time. The fix is that
sentence and that default, moved one file over.

## After

```
CONTROL  FIRST             413   RSS +49 MiB
WITNESS  OMITTED           413   RSS +27 MiB
ARM      securityPolicy: null  200   RSS +454 MiB
CONTROL  LAST              413   RSS +0 MiB
```

**`securityPolicy: null` is a separate arm from omitting it, and it is the control
for the fix**: the default changed and the opt-out did not. A probe with the null
arm alone measures the opt-out and reports it as the default.

## Canary

```
the default removed from the constructor
  WITNESS the documented construction bounds the request body
    Expected: <413>
      Actual: <200>
  the other checks came on with it
    Expected: <400>
      Actual: <200>
  2 of 5 fail
```

Both halves of the witness — the body and the metadata block — fire together,
which is the point: they were one `if`.

`GUARD RpcHttpServer already defaulted the same way` stays green under the canary.
That is the arm that says the sibling was right all along, and it will fail if the
two defaults ever drift apart again in either direction.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +201
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2216 / 2216, REUSE compliant
```

`+201` against `+196`, and **no other test in the package needed changing** —
nothing in the suite was relying on a bare transport having no limits.

## Not fixed

**`bodyReadTimeout` still has no default**, and that is the lead's other claim.
The round re-measured the documented objection to giving it one and it does not
hold as written: the `Expect: 100-continue` hazard is about a SHORT budget, `500 ms
-> 408` against `30 s -> 200 OK`. What does hold is a reason the doc does not
state — `readBody().timeout(...)` bounds the WHOLE read, so a finite default
refuses an honest 16 MiB upload over a slow link at the same deadline it refuses
slowloris. The right bound is per-chunk idle, which is a mechanism and not a
default. Filed as `B-223`, with the rig's own failure recorded: the steady-upload
arm deadlocks the probe at `socket.close()` once the responder has answered.

**`maxActiveStreams` and the method path are not driven.** They came on with the
same `if`, and the suite witnesses two of the four.

**The 256 MiB number is RSS, which is not a leak measurement.** It is residency
during one request, which is what the lead is about; nothing here says the memory
is not returned.

## Links

Lead `../backlog/B-150-the-standalone-http1-responder-has-no-limits.md` — CLOSED.
Lead `../backlog/B-223-a-whole-body-deadline-cannot-separate-slow-from-stalled.md` — new.
Bookkeeping: round 583's `B-216` is renumbered `B-222` in this commit. Both numbers
were already taken — B-216 by an ARCHIVED lead and B-217 by a live one — and
`loop.py lint` only caught the live collision, through the index link. **`next`
reports the highest LIVE number; the archive holds numbers too.**
Bench `../probes/P-204-what-the-documented-shelf-setup-admits.md` — new.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [584]`.
Lesson: none, and the candidate is declined out loud: "an explicit `null` is not
the same arm as an omitted parameter". That is `measurement.md` item 6 — measure
what the library does, not what the bench does — and the probe carries it as a
comment on the arm itself.
