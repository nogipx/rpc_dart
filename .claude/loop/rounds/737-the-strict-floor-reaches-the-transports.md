---
round: 737
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-26
bench: none — one planted implicit downcast, analysed in place and removed
commit: yes
release: none
---

# Round 737 — the strict floor reaches the transports

## Target

RPC-26, last applied in round 702. A grep of each package's
`analysis_options.yaml` for `strict-casts: true` found it in `rpc_dart` alone,
and 0 in the five transports. That reads like the floor never reached them.

## Hypothesis

The transports are analysed without the strict type modes.

## Before

```
  grep strict-* in packages/*/*/analysis_options.yaml   rpc_dart 3, every other 0
  transports' file: include: ../../../analysis_options_base.yaml
  analysis_options_base.yaml:42-44   strict-casts, strict-inference, strict-raw-types: true
```

The grep read the wrong file: the floor lives in the base the packages include,
which round 328 set up.

## Mechanism

None. The lens's own rule decides it: change a setting and check that the
target obeys it. A planted `int r737Probe(dynamic d) => d;` in
`rpc_http2_common.dart` is reported by `dart analyze` as
`return_of_invalid_type`, which is an error only under `strict-casts`.

## After

n/a.

## Canary

n/a — the planted line is the check, and it was removed.

## The verdict questions

1. n/a.
2. Yes: the planted downcast is reported.
3. By the analyser itself.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None. The grep's blindness to `include:` is the case the lens already
   records for round 328.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change. The planted line was removed and `git status` showed only
the owner's `config.md`.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-26-the-gate-floor-nobody-chose.md` — `applied: [..., 737]`.
