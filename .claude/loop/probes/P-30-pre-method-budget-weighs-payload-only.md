---
file: packages/core/rpc_dart/.dart_tool/probe/pre_method_weighs_payload_only.dart
round: 280
commit: a9cb0846
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-30 — what the pre-method budget actually charges

Parks N frames through `RpcResponderStreamState.bufferPreMethod` with the
pipeline's admission check TRANSCRIBED beside it — charge, refuse past the
ceiling, otherwise park — so the bench measures the budget as the pipeline
applies it rather than the accumulator alone.

Arms: `metadata` (one payload byte plus N tiny headers) and `payload` (the
control). A second argument, `old`, switches the charge expression back to the
pre-fix `payload?.length ?? 0`, so the ablation is one word and the library
stays as shipped.

## Measures

Frames PARKED against frames refused, what the budget was charged, what the
state reports, and `maxRss`. Parked-versus-refused is the deterministic column;
RSS corroborates and is not the verdict.

## Control

Two, and the second is the ablation.

```
arm       charge  parked  refused   charged      RSS   ceiling
metadata  old       4000        0  0.00 MiB   789.2 MiB   16.0
metadata  fixed      106     3894  15.93 MiB   27.6 MiB   16.0
payload   fixed     4000        0  15.63 MiB   11.7 MiB   16.0
```

The `payload` arm is what says the budget was ever honest: 15.63 MiB charged for
11.6 MiB resident, right at its ceiling. Against it, `metadata old` charging
0.00 MiB for 789 MiB is not "a generous bound" — it is a bound that does not
apply.

> **Transcribe the admission check, do not approximate it.** A first version
> parked every frame with no ceiling and reported 789.9 MiB for both the broken
> and the fixed library, because the thing being fixed is WHICH FRAMES GET IN,
> and a bench that admits everything cannot see it. The number only became a
> verdict once refusal was part of the bench.
