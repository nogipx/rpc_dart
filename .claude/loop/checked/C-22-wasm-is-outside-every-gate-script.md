---
round: 220
commit: 9ee285ca
paths: [packages/transport/rpc_dart_wasm/**]
scope: [wasm]
---

# C-22 — wasm is outside every gate script, and clean anyway

> **Superseded for `analyze`, `format` and `format:check` by round 226**, which
> converted all three from `exec:` to `run:` blocks that handle this package
> explicitly. **Round 226's step was wrong on CI and was corrected in 231** —
> it needed a resolve nobody ran and it analysed `example/`, whose assets are
> build artefacts; see [L-05](../lessons/L-05-green-locally-is-not-green-clean.md). The hole below was real and is closed; the measurement is kept
> because it is what the conversion was checked against. `test`/`test:unit`
> still do not cover it — that is `test:wasm`, and it is by design.

**Do not re-derive this package list.** Round 220 measured it.

    melos list          21 packages
    packages/ on disk   22 packages
    the difference      rpc_dart_wasm

Every gate script — `analyze`, `format:check`, `test`, `test:unit` — is
`melos exec` over workspace members, and `rpc_dart_wasm` is deliberately not one
(it is the only Flutter package; including it would pin the lockfile to the
Flutter SDK's transitive deps).

The compensating scripts CLAUDE.md documents do NOT close this. `test:wasm` runs
`flutter test`, which does not analyse. `analyze:native` type-checks Swift and
Kotlin only. So the package's **Dart** source is analysed by no script and
format-checked by no script, and `melos run prepare` — the mandatory release
gate — is member-scoped and therefore silent about it by construction.

## Control

Run the two checks directly against the package, which is what the gate would do
if it could see it:

    fvm dart analyze packages/transport/rpc_dart_wasm      No issues found!
    fvm dart format --set-exit-if-changed  ...same...      18 files, 0 changed

Both clean, so the hole costs nothing today. That is why this is a negative and
not a finding.

## What would change it

Any wasm Dart change landing without someone running those two commands by hand.
Closing the hole is `../backlog/B-19-close-the-gate-over-wasm.md`; it was not
done in round 220 because it means restructuring the two main gate scripts to
fix nothing that is currently broken.
