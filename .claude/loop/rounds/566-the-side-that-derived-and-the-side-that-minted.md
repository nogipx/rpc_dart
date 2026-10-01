---
round: 566
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-188 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 566 — the side that derived and the side that minted

## Target

`B-220`, filed in the round-565 owner review and the thread that review opened: the caller
derives its trace id from the request id it already has, and the responder mints one. Taken
ahead of anything larger because it is one line with a witness already specified, and because
finishing what the previous round opened is the judgement rounds 234-238 paid for.

Lens RPC-08: one rule, two sides, applied on one of them.

## Hypothesis

A peer that sends no `x-trace-id` sends no `x-request-id` either — both are this library's
headers, not gRPC's — so the responder mints TWO tokens where an rpc_dart peer costs it none,
and the second is derivable from the first.

## Before

```
  neither header (a foreign gRPC peer)
      tokens minted 2
      requestId=req_ZbE6pxfSlttsABpVAAAABA (mint 4)
      traceId=trace_UpSsG7zi7untof4sAAAABQ (mint 5)

  both headers (what rpc_dart sends)
      tokens minted 0

  a foreign x-request-id, no trace id
      tokens minted 1
```

Two mints, and the distinct mint numbers — 4 and 5 — are what makes it two tokens rather than
one count read twice. At `~42 us` a token (`P-179`) that is the whole of a second draw of OS
entropy, on every call from a non-rpc_dart peer. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b220_responder_mints.dart`.

## Mechanism

`responder_pipeline.dart:2356-2361` adopts the caller's `x-request-id` at construction and then,
when no `x-trace-id` arrived, calls `generateTraceId()` — a whole `_uniqueToken`. The caller side
of the same question calls `RpcContextUtils.traceIdFor(context.requestId)`
(`caller_pipeline.dart:143-144`) and mints nothing.

## After

```
  neither header (a foreign gRPC peer)
      tokens minted 1
      requestId=req_axmmTRiORcAUjGuOAAAAAw (mint 3)
      traceId=trace_axmmTRiORcAUjGuOAAAAAw (mint 3)

  both headers (what rpc_dart sends)      tokens minted 0   unchanged
  a foreign x-request-id, no trace id     tokens minted 1   unchanged
```

**Both ids now carry mint 3** — the same token, which is the observable that distinguishes
"derived" from "a count that happened to fall". The two control arms do not move.

**Breadth, swept rather than assumed**: three `generateTraceId()` call sites in every package's
`lib/`. This was the only defect. `context.dart:549` is `traceIdFor`'s own fallback, correct by
construction; `context.dart:634` is `RpcContextBuilder.withGeneratedTraceId()`, a public method
whose NAME promises a fresh id, so deriving there would break a documented contract rather than
save a token.

## Canary

```
1 > 0 ? generateTraceId() : traceIdFor(context.requestId)

  WITNESS  Expected: trace_pV7hJPUNKn ...
             Actual: trace_trBHYz44u1 ...
                           ^ Differ at offset 6
           the trace id must come from the request id just minted, not from a
           second token
  CONTROL  still passes, and so do the file's four existing tests
```

The failure shows two different token bodies, which is the defect itself rather than a
mismatch of shape. **The control is load-bearing**: `traceIdFor` can only derive from an id of
ours, so the foreign-`x-request-id` arm MUST still mint — if it ever stops, the witness is
passing because nothing mints at all.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   rpc_dart +1865 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2164 / 2164, REUSE compliant
melos exec --scope=rpc_dart -- fvm dart test -p node test/endpoint/request_id_is_adopted_test.dart
                                 SUCCESS
```

**The full core node target did NOT produce a verdict, and is reported as that rather than as
a pass or a failure.** It read `-159`, every one a LOAD failure (`Node exited before connecting
to the test channel`), and the machine is the cause: an earlier sweep died with
`read ENETDOWN` on loopback across an untouched package too, and `rpc_message_parser_test.dart`
alone went FAIL / PASS / FAIL **with the code held constant** across the ablation and back.
`load averages: 6.89 13.99 14.30` — the condition `config.md` names for batches of failures
that look like flakes. The file covering this change passes on node, and the change contains no
construct from the dart2js list (no `async*` cancel, no int above 2^53, no clock, no
`Random.secure` that was not already there).

## Not fixed

**`base_processor.dart:1302` still builds a whole `RpcContext.empty()` to read one id off it**,
on the null-context branch that sends no trace header. The TOKEN count there is already minimal
— one id, one token — so it is not this round's mechanism; the waste is two `Map.from` copies,
which belongs to `B-120`'s context half. Unreachable through `RpcCallerEndpoint`, since
`_ensureCallerContext` always supplies a context.

**`P-179`'s mint decoder is wrong about half the time**, found while reusing its instrument:
`token.split('_').last` takes the body, and base64url's alphabet CONTAINS `_`, so any token
whose body holds one decodes to the wrong length and reads `null`. Its recorded numbers stand
(every row shows a mint, and `_counterNow()`'s `!` would have thrown rather than lied), so what
the defect cost is reliability. `P-188` uses `indexOf('_')`. Noted on P-179's record.

**One more datum for `B-215`**: the same test file flipping PASS/FAIL on node with `lib/`
byte-identical is the cleanest instance yet of what that lead is about, and it was observed
here at a 15-minute load average of 14.30 rather than the 20.5 round 543 recorded.

## Links

Lead `../backlog/B-220-the-responder-mints-a-trace-id-it-could-derive.md` — CLOSED; all three
of its parts are done, including the stale doc comment.
Lead `../backlog/B-120-per-call-context-and-id-cost.md` — takes `base_processor.dart:1302`'s
construction cost, which belongs to its context half.
Lead `../backlog/B-215-the-chrome-suites-fail-differently-every-run.md` — one more observation.
Bench `../probes/P-188-what-the-responder-mints-for-a-foreign-peer.md` — new.
Bench `../probes/P-179-how-many-tokens-one-call-mints.md` — its decoder defect recorded.
Round `565-the-canary-that-reported-a-pass.md` — the review that filed this lead rode in with it.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [566]`.
Lesson: none. This is RPC-08's ordinary shape — a rule applied on one side of a two-sided
protocol — and the lens already carries it.
