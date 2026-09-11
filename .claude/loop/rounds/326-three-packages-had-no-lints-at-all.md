---
round: 326
verdict: FIXED
packages: [rpc_dart_log, rpc_dart_compression, rpc_dart_opentelemetry, rpc_dart_framework, rpc_dart_grpc_reflection, rpc_dart_http, rpc_dart_http2, rpc_dart_isolate, rpc_dart_websocket]
lens: RPC-26
bench: none
commit: yes
---

# Round 326 — three packages had no lints at all

## Target

RPC-26's own closing line: round 325 raised the floor on `rpc_dart` and left the
other 21 packages on whatever they inherited, with the count never taken. Scope
keeps this to core and transport.

## Hypothesis

The other packages sit on `package:lints/recommended.yaml` like core did, so the
same two dials will report a similar count.

## Before

Partly wrong, and the part that was wrong is the finding. There were **three
floors, and nobody had chosen any of them**:

```
own analysis_options.yaml, lints/recommended        9 packages
own analysis_options.yaml, strict (round 325)       1   rpc_dart
NO analysis_options.yaml AT ALL                     3   rpc_dart_framework
                                                        rpc_dart_grpc_reflection
                                                        rpc_dart_websocket
```

Those three fall through to the repo-root file, which configures **only the
formatter** — no `include:`, no `linter:`, nothing. `melos run analyze
--fatal-infos --fatal-warnings` reported `No issues found!` for
`rpc_dart_websocket`, a priority transport with 137 tests, because there was
nothing switched on to find any.

Raising the shared floor over the nine:

```
rpc_dart_http2     77      rpc_dart_grpc_reflection  13
rpc_dart_isolate   40      rpc_dart_framework        12
rpc_dart_log       37      rpc_dart_websocket         8
rpc_dart_http      17      rpc_dart_opentelemetry     5
                           rpc_dart_compression       2
                                              TOTAL 211
```

**Ten of those violate `lints/recommended` itself** — not the strict extras, the
BASELINE — and all ten are in two of the three packages that had no options
file:

```
rpc_dart_grpc_reflection   6  avoid_relative_lib_imports
                           2  curly_braces_in_flow_control_structures
rpc_dart_framework         1  unnecessary_library_name
                           1  no_leading_underscores_for_local_identifiers
```

`curly_braces_in_flow_control_structures` is the lint `CLAUDE.md` records as
having once shipped into a published `rpc_dart`. It is in the tree again, and it
stayed because that package's gate has never had a rule to break.

## Mechanism

Same two shapes as round 325, and they collapse the same way: 27 type issues in
http2 went in **six edits** (untyped `onError`), and `Future.delayed` without a
type argument accounted for most of the rest, in packages whose own `lib/`
already writes `Future<void>.delayed`.

The structural fix is one floor, not twelve copies. `analysis_options_base.yaml`
at the repo root holds it; every package includes it by **relative path**,
because `package:lints/...` cannot be resolved from every context this repo is
analysed in — the generator still prints that warning during
`melos run format:check`. `analysis_options_test.yaml` is the same floor minus
`unnecessary_lambdas`, and each `test/` directory includes that.

## After

```
melos run analyze     21 packages + rpc_dart_wasm    clean
melos run test:unit   14 packages, 0 failures, every count unchanged
```

## Canary

The same file, analysed under both floors, with one `while` body unwrapped:

```
pre-326  (no options file in the package at all)   No issues found!
post-326 (the shared floor)                        1 issue found
```

That is the round: identical code, and the gate that called it clean could not
have said otherwise.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures —
`rpc_dart` `+1435 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`,
`rpc_dart_isolate` `+74`, all unchanged from before the round.

## Not fixed

**`rpc_dart_wasm` is not on the shared floor.** It is not a workspace member and
resolves standalone, so a relative include to the repo root would work but its
dependency set is the Flutter one and the count has not been taken. It keeps its
own options file.

**`rpc_dart_generator` is not on it either**, deliberately: it already cannot
resolve `package:lints/recommended.yaml` in every context (the warning
`format:check` prints on every run), and putting it behind one more indirection
before understanding that is how a gate breaks quietly. Filed as the next step
rather than guessed at.

The data packages (`rpc_data*`, `rpc_notify*`, `rpc_blob*`) are outside the
owner's current scope — core and transport only.

`curate` remains overdue since ~234; RPC-02's re-ablation is still owed.

## Links

RPC-26 (`applied:` gains 326). What this adds: the lens said "the floor is a
preset nobody chose"; the sharper case is **no floor at all**, which is
invisible in exactly the same way and reads identically in CI. Count the
packages that have no options file BEFORE counting what the preset omits.
