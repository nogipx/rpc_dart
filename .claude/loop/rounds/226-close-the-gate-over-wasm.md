---
round: 226
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the instrument is a planted lint and the gate's own exit code, run on both arms
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 9 of 10, A1 not applicable (no attacker/victim; this is a build gate)
commit: yes
---

# Round 226 — close the gate over wasm

## Target

B-19, the owner decision: convert `analyze` and `format:check` from melos's
`exec:` form to `run:` blocks that sweep the members and then handle
`rpc_dart_wasm` explicitly, because `melos exec` only ever sees workspace
members and that package is deliberately not one.

## Hypothesis

The one package that ships Swift and Kotlin — the only one that can get an
application rejected from an app store — is analysed and format-checked by
nothing, and nothing would notice if a violation landed in it.

## Before

An unused import and a format violation planted in
`packages/transport/rpc_dart_wasm/lib/src/rpc_wasm_transport.dart`:

```
  melos run analyze        SUCCESS over 21 packages
  melos run format:check   SUCCESS over 21 packages
```

Both green with two live violations in the tree. The control is the member arm,
which does go red — measured in round 224, when an `unnecessary_import` in
`rpc_dart`'s test failed `analyze`.

## Mechanism

`exec:` is member-scoped by construction, so no amount of configuration reaches
a non-member. Converted all three scripts to `run: |` blocks with `set -e`: the
melos sweep first, then the package by hand — the shape `publish:dry` already
used for this same package.

**`format` was converted too, which B-19 did not ask for.** `prepare` runs
`format` and then the checks, so a member-only `format` would leave the release
gate able to FAIL on wasm's formatting and unable to fix it. Fixing one without
the other would have been a worse state than before.

## After

Same two violations, same commands:

```
  melos run analyze        FAILED — 2 issues found in rpc_dart_wasm
  melos run format:check   FAILED — Changed .../rpc_wasm_transport.dart
```

And the arm that actually matters, because the risk here is a strict gate
quietly becoming a permissive one while still printing green — the same two
violations planted in a MEMBER instead:

```
  melos run analyze        FAILED (in 1 packages) rpc_dart, exit code 2
  melos run format:check   FAILED (in 1 packages) rpc_dart, exit code 1
```

Both halves can fail the script: `set -e` catches `melos exec`'s non-zero, and
the trailing `fvm dart analyze` fails on its own. Four arms, all four as they
should be.

Worth knowing: on a member failure the script aborts **before** the wasm step —
the `--- rpc_dart_wasm ---` line never printed. The two halves are sequential,
not independent, so one run cannot report both. Fix the member, re-run.

## Canary

The ablation IS the canary here and is the four-arm table above: the fix is a
gate, so switching it off means planting the violation somewhere the gate should
see. Before/after on the wasm arm is the witness; before/after on the member arm
is the guard that the conversion did not loosen anything.

## Gate

```
melos run analyze                No issues found!    21 packages + rpc_dart_wasm
melos run format:check           0 changed           21 packages + rpc_dart_wasm
melos run test:unit --no-select  All tests passed    14 packages
```

Both plants reverted; `git diff` is `pubspec.yaml` only. The wasm step is now
visible in both outputs, which is the difference from every previous round's
gate.

`prepare` composes `melos run format` and `melos run analyze`, so it inherits
the coverage — by composition, not by running it: `prepare` calls
`license:sync` and `format`, which rewrite files, and that is not a thing to do
mid-round.

## Not fixed

**Only the Dart half is closed.** `test`/`test:unit` still do not run
`rpc_dart_wasm`'s tests, and `analyze` still does not compile a line of its
Swift or Kotlin. Both are by design and have their own scripts (`test:wasm`,
`analyze:native`); this round changes neither, and CLAUDE.md now says so
explicitly rather than leaving "the ordinary gate never touches it" to cover
both cases at once.

**Rule one, two documents corrected.** `CLAUDE.md` described a gate that reached
21 of 22 packages while claiming "analyze all packages", and
[C-22](../checked/C-22-wasm-is-outside-every-gate-script.md) recorded the hole as
open. Both updated in this round; C-22 is kept rather than deleted because its
measurement is what the conversion was checked against.

## Links

Lead `../backlog/B-19-close-the-gate-over-wasm.md` — closed by this round.
Negative `../checked/C-22-wasm-is-outside-every-gate-script.md` — superseded for
the three scripts, kept for the measurement.
Lens `../lenses/RPC-11-package-outside-workspace.md` — `applied: [226]`.
Round `220-the-package-the-gate-cannot-see.md` — where the hole was found.
