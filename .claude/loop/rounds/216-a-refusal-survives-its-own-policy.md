---
round: 216
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-02
bench: P-08 — new
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and its three controls; approved 10 of 10
commit: no
---

# Round 216 — a refusal survives its own policy

## Target

RPC-02, never applied in the journal, and due: round 208 added a NEW refusal
trailer (`_fcRefuseOverrun`) to a package where this shape had never been
measured. The lens's damage is "the client gets the wrong status, and at worst
the connection closes instead of one call being refused".

## Hypothesis

A synthetic trailer carrying the diagnosis goes out through `sendMetadata`,
which validates it against the same policy that just refused the peer. So a
tight `maxHeaderValueBytes` should turn a specific refusal into something else —
the lens's own evidence is a 70-character message turning status 7 into status
13.

## Before

```
  cap    unimplemented   un-consumed window   plain call after
  8192   status 12       status 8             ok
    64   status 12       status 8             ok
    16   status 3        status 3             status 3     <- confounded
    64   status 12       ArgumentError        ok           <- ablated
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/refusal_survives_a_tight_cap.dart`
(P-08).

## Mechanism

The hypothesis does not hold on the current code: every trailer that carries a
message passes `maxMessageLength`, so `forTrailer` trims the diagnosis to
whatever the policy will accept and the STATUS always survives. The detector
sweep found 16 assembly sites in `lib/` — 12 that pass a message, all capped,
and 4 that pass none and therefore always fit.

The hand-built trailers are a separate group and the sweep had to look at them
separately, since a grep for `forTrailer` cannot see them: five sites build a
`grpc-message` header directly, all on the CALLER side, all emitted locally
through `_emit` into the caller's own controller rather than through
`sendMetadata`. Nothing validates them, so they cannot produce this shape.

> **Only a trailer that passes through a validating hop is at risk.** That is
> the distinction the detector was missing, and it cuts the surface from 21
> sites to 12.

The ablation is what makes the negative worth anything: remove the cap from one
trailer and the caller stops getting status 8 and gets a raw `ArgumentError`
instead.

## After

n/a — nothing changed. `git diff` is empty; the ablation was reverted in place.

## Canary

n/a — no fix. Three controls instead, and the second earned its place: at a cap
of 16 EVERY row read status 3, including the plain call, because rpc_dart's own
request headers do not fit — a request-id UUID alone is 36 bytes. Nothing there
could be attributed to the trailer. That cost one probe rebuild and is exactly
the pack's rule that a refusal is evidence only if it names the control under
test.

## Gate

No code changed, so the gate is the one HEAD passed at round 212.

## Not fixed

Measured, not a defect, and now a negative so it is not re-hunted: setting
`maxHeaderValueBytes` below roughly 40 makes a server refuse its own protocol
headers, and every call fails with INVALID_ARGUMENT before any handler runs.
It is a misconfiguration and it fails loudly on the first call, so it is not
over the bar — but it looks like a transport bug from the outside, and it will
confound any future bench that tightens this knob. Filed as C-21.

`rpc_dart_websocket` and `rpc_dart_isolate` synthesize no trailers of their own;
they delegate to `RpcChannelTransport`, whose two synthetic-trailer sites are
capped and were fixed in rounds 161-162. `rpc_dart_http`'s one hand-built
`grpc-message` is emitted locally, like the others.

## Links

Bench `../probes/P-08-refusal-survives-a-tight-cap.md` — new, three controls.
Negative `../checked/C-21-header-cap-has-a-floor.md` — new.
Lens `../lenses/RPC-02-refusal-trailer-violates-policy.md` — `swept here (round 216, 10ba2a93)`,
with the validating-hop refinement and the site count.
Round `208-refuse-instead-of-pausing.md` — whose new trailer prompted this.
