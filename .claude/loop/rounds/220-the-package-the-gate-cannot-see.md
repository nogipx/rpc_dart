---
round: 220
verdict: CLEAN
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the gate's own package list is the instrument
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record, and Q4 is what keeps this CLEAN rather than a finding
commit: no
---

# Round 220 — the package the gate cannot see

## Target

Not B-17, which `next` still names: its decision was measured unimplementable in
round 218 and its replacement is with the owner, so re-running it repeats that
round exactly. Two rounds have now been declined on it; that is recorded rather
than silently skipped.

RPC-11 instead — "a package outside the workspace is invisible to the gate" —
chosen deliberately because it touches NO library code. An ablation round would
leave planted defects in `lib/` for its duration, and this session has been long
enough that the risk of not finishing one is real.

## Hypothesis

`rpc_dart_wasm` is not a pub-workspace member. Every gate script is
`melos exec` over members, so the one package that ships native code and can get
an application rejected from an app store may be getting no gate at all.

## Before

```
melos list                     21 packages
packages/ on disk              22 packages
the difference                 rpc_dart_wasm

scripts mentioning wasm        test:wasm, analyze:native, test:wasm:device,
                               publish:dry, publish:release, tag:release
scripts NOT mentioning wasm    analyze, format:check, test, test:unit

so, run directly against the package:
  fvm dart analyze packages/transport/rpc_dart_wasm      No issues found!
  fvm dart format --set-exit-if-changed ...same...       18 files, 0 changed
```

## Mechanism

The gap is real and larger than "not in the test run": `rpc_dart_wasm`'s **Dart
code is analysed by no script and format-checked by no script.** `test:wasm`
runs `flutter test`, which does not analyse; `analyze:native` type-checks Swift
and Kotlin only. The compensating scripts CLAUDE.md documents cover the native
halves and the Dart tests, and leave static analysis of the Dart uncovered.

`melos run prepare` — the release gate, and the thing CLAUDE.md calls mandatory
before publishing — is `analyze` plus `test:unit` plus `format:check` over the
workspace. All three are member-scoped. So the release gate is silent about this
package's Dart source by construction.

## After

n/a — nothing changed.

## Canary

n/a — no fix. The instrument is the gate's own package list, and the two direct
runs above are the check that the gap costs nothing TODAY.

## Gate

No code changed. The two commands above were run directly and are green.

## Not fixed

**Review Q4 keeps this CLEAN rather than a finding.** The gap is structural and
real, but the measurement says it is currently free: the package analyses and
formats clean when asked directly. There is no defect to report, only a hole
where one could hide.

I did not close the hole, and that is deliberate. `analyze` and `format:check`
use melos's `exec:` form, which is member-scoped by definition; adding wasm means
restructuring both into `run:` blocks with a trailing hand-written step, the way
`publish:dry` already does. That is surgery on the main gate to fix nothing
that is broken, and the config's bar rules out coverage for coverage's sake.
The owner should decide whether the structural guarantee is worth it — filed as
B-19 with the exact shape of the change.

Recorded as C-22 so the next round does not re-derive the package list.

## Links

Negative `../checked/C-22-wasm-is-outside-every-gate-script.md` — new.
Lead `../backlog/B-19-close-the-gate-over-wasm.md` — new.
Lens `../lenses/RPC-11-package-outside-workspace.md` — `applied: [220]`.
Round `219-what-the-web-gate-actually-covers.md` — the same question one layer
out: what a gate that passes does not actually run.
