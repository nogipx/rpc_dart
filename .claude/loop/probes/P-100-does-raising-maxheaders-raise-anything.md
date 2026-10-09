---
file: packages/core/rpc_dart/.dart_tool/probe/context_limits_vs_policy.dart
round: 446
commit: 732dc208
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-100 — does raising `maxHeaders` raise anything?

## Why it exists

`RpcContext` held four private header limits numerically equal to
`RpcSecurityPolicy`'s defaults and reachable from no policy. B-72 claimed the
knob was therefore monotone downward only. The claim is about a KNOB, so the
bench varies the knob and holds the input fixed.

## The harness

Two halves, and the second is what makes it a defect rather than a quirk.

**Static half.** Build a context with 200 headers, then ask two questions of the
same input: how many the context kept, and what `validateMetadata` would say
about all 200. Four arms: default policy, raised to 512, lowered to 16, and a
control of 10 headers under the default.

**End-to-end half.** One unary call over `RpcChannelTransport.pair`, the handler
counting the `x-h*` headers it was actually given. Run at two policies: raised
(the defect arm — the headers must arrive) and default (the loudness arm — over
the ceiling the caller must be told), plus a control of 10 under the default so
the refusal is attributable to the COUNT and not to "a default policy refuses
contexts".

## The numbers (round 446)

```
                              before fix                after fix
A1 default, 200 sent    kept 128                  kept 200
A2 RAISED 512, 200      kept 128                  kept 200
A3 LOWERED 16, 200      kept 128                  kept 200
A4 CONTROL, 10 sent     kept 10                   kept 10

E2E policy 512, 200     handler saw 127           handler saw 200
                        SUCCEEDED, 73 missing     SUCCEEDED, nothing missing
E2E policy 128, 200     SUCCEEDED, truncated      REFUSED: RpcMetadataViolation
E2E policy 128, 10      SUCCEEDED                 SUCCEEDED
```

A2 against A4 is the finding: the context keeps 128 whatever the policy says,
and at 10 it keeps 10, so the 128 is its own and not a coincidence of the input.

## Measures

The COUNT the handler was given, taken inside the handler — the far side of the
wire, not the caller's own object. The caller's `ctx.headers.length` is read too,
so the two can be compared and the truncation attributed to the context rather
than to the transport.

## Control

Three, and the third is the one that stops a wrong reading.

1. **A4 / the 10-header E2E arm** — under the ceiling every header arrives, so
   the loss at 200 is the ceiling and not the mechanism being always-on.
2. **The ablation** — the four limits restored in place, twice, once per half
   (count/bytes, then name/value length). Both witnesses flip.
3. **`validateMetadata` asked about the same input** — it accepts 200 under a
   raised policy. Without this column the context's truncation and the policy's
   refusal are indistinguishable, and the defect reads as "the limit works".

## What it establishes, and what it does not

Establishes: the context's ceiling is reachable from no policy; raising
`maxHeaders` to 512 left 73 of 200 headers behind and the call SUCCEEDED, with
no error or log on either side.

Does not establish anything about the ergonomics trade `f876d602` made. That
round preferred truncating at build time to a send-time throw it called "a
confusing ArgumentError". The send-time text is now measured —
`RpcMetadataViolation: Invalid argument: Too many metadata headers: 205 > 128` —
which names the count, the limit and the field, but WHERE a caller would rather
learn this is a judgement and not in these numbers.

## Reading

rpc_dart — varies the KNOB and holds the input fixed, which is the shape for
any "this limit is wired to nothing" claim. Four static arms plus three
end-to-end ones, the count read INSIDE the handler so the caller's own object
can be compared against what crossed. **Three controls, and the third is what
stops a wrong reading**: asking `validateMetadata` about the same 200 headers,
without which the context's truncation and the policy's refusal are
indistinguishable and the defect reads as "the limit works"
