# Loop settings — rpc_dart

Only what is bound to this repository. The process lives in
`.claude/skills/improvement-loop/`. Package layout, commit conventions and
style live in the root `CLAUDE.md` and are not duplicated here.

## Mode

unattended: yes

The loop runs with nobody at the keyboard, so rule zero applies in full: no
command that could raise a permission prompt.

packs: core, dart, async-io, server

`crdt` is not enabled — there are no replicas and no coordination-free merge in
this project. `flutter-ui` is not enabled — the only Flutter package is a plugin
with no screens, navigation or input.

## Language

Two independent settings; drop either line and it is English. Neither affects
the language of the loop data, which is English here.

- `commit language` — the round commit's subject and body.
- `reply language` — the round report in chat.

commit language: English
reply language: Русский

## Toolchain

`fvm dart` and `fvm flutter`, never bare `dart`/`flutter` (the SDK is pinned via
fvm). Melos as `fvm dart run melos <cmd>` or through a globally installed
`melos`; its `exec:` scripts re-invoke `melos` themselves, so those need the
global executable.

**Launch trap:** `melos run <script>` for a script with `packageFilters` opens
an interactive package picker and dies with
`StdinException: Error getting terminal echo mode`. Always add `--no-select`.
`melos exec --scope=<pkg> -- ...` never asks.

## Gate before every commit

The mandatory workspace-wide sequence, run by every round:

```gate
melos run analyze
melos run test:unit --no-select
melos run format:check
melos run license:check
```

`license:check` joined the gate after round 231, and it is worth saying why: it
had been RED on CI since `87e9d2f4 add skill` — about thirty commits and twenty
rounds — while every one of those rounds reported a green gate. Both statements
were true, because the loop's gate and CI's were different lists, and the
difference was exactly this line. A gate that is a SUBSET of CI's will report
success for work CI rejects.

On top of that, in the changed package, when a round touches it directly:

    fvm dart analyze lib test
    fvm dart test -j 8                  # 2-3 times, 15-20 s apart
    fvm dart test -p node               # dart2js, if core or web is involved
    fvm dart format --output=none --set-exit-if-changed

and every dependent package — `melos list` gives the list.

**Dependent packages resolve core from LOCAL source** through the pub workspace
(the root `.dart_tool/package_config.json`; members have none of their own).
Checked, and proven by a core change that broke two of them. The exceptions are
`rpc_dart_wasm` and the non-member generator.

**Pace the runs.** Back-to-back suites drive the 15-minute load average past 20
and produce batches of failures that look like real flakes. Check `uptime` and
name any failure before calling it a flake.

**Known flake:** `audit_frame_reassembly_linear_test` — a real wall-clock flake
that predates the loop.

## Probes

    packages/<pkg>/.dart_tool/probe/*.dart

Gitignored, excluded from analysis, inside the package so that `package:`
imports resolve. Overwrite, do not delete (`rm` is forbidden). The probe's file
name must appear in the round record.

## Targets nobody runs

- `fvm dart test -p node`, a.k.a. `melos run test:web` — dart2js traps: cancel
  in `async*`, ints above 2^53, clock resolution, `Random.secure`, VM-only
  codecs.
- `melos run test:wasm` — the Flutter package outside the workspace; covers the
  Dart bridge only. **It resolves the LOCAL core**, via
  `packages/transport/rpc_dart_wasm/pubspec_overrides.yaml`, which round 122
  added for exactly this reason — the package is not a workspace member, so
  without that file pub would take rpc_dart from pub.dev and the suite could be
  green while the core about to ship breaks it.

  The blind spot is now the INVERSE, and it is smaller: wasm is never tested
  against an older published 5.x, which its `>=5.0.0 <6.0.0` constraint allows.
  `publish:dry` says so as a hint, not a warning, so the release flow's "0
  warnings" still holds. To test that combination, remove the overrides file for
  one run — do not delete it, or the gate goes blind again.

  **A gate that cannot fail is not evidence: check what it RESOLVES.** Round 269
  claimed the opposite of all this after reading `pubspec.yaml` alone and never
  looking for the overrides file. The observable that settles it is pub's own
  resolution line, `rpc_dart 5.0.1 from path ../../core/rpc_dart (overridden
  in ./pubspec_overrides.yaml)`.
- `melos run analyze:native` — the plugin's Swift and Kotlin against the real
  frameworks. With the toolchains missing it exits 2, so "nothing was checked"
  can never read as success.
- `melos run test:wasm:device` — actually RUNS the native code; needs a booted
  simulator or emulator. Run it on BOTH platforms: two different scripts in two
  languages, and a fix to one is not a fix to the other.
- `reuse lint` — licence headers.

The `rpc_dart_generator` golden tests cannot be run from the workspace
(`build_test` needs a per-package `package_config.json`). There is NO
`test:generator` script. The manual way is documented in the root `pubspec.yaml`
next to the `test` script.

## Standing owner requirements

They hold in every round and are not about any single finding. Decisions on
individual findings live in `backlog/`.

- **`rpc_dart_wasm` must stay publishable on the App Store and Google Play.** It
  is the only package with native code and the only one that can get an app
  rejected. Checked in any round that touches the plugin, not deferred to
  release.
- **Ask before trading speed for anything else.** Mentioning the cost in the
  report is NOT asking: a round once removed a fast path for correctness and the
  owner objected.
- **Doc comments: shorter and denser.** Documentation should be sharp and to the
  point, with no bloated explanations; the search narrative goes into the commit
  and the journal, not into a comment beside the code.
- **No emoji** anywhere: code, comments, commits, documentation.
- **No mention of the assistant in commits** (`Co-Authored-By` and the like).

## Severity bar and cap

From round 191 on, only **very critical** things are taken: data loss, a crash,
a hang, a security hole, an unbounded leak. Not taken: sharper diagnostics, a
doc comment, coverage for coverage's sake.

The cap is **round 260**, raised from 230 by the owner after round 230 with the
instruction "разбирать беклог" — work the backlog. That is a cap, not a target.

**Rounds 231-260 are backlog-clearing**, and that changes what a round may
target though not what it may ship. The bar above still governs what counts as a
finding worth fixing; it does not stop a round TAKING a lead whose product is a
bench, a rescan, or a filing — B-06, B-09 and B-11 are exactly that, and they
are why the backlog stopped shrinking. A round on one of those ends CLEAN or
with a new lead, and that is the expected outcome.

## Round budget

Exhausted means the verdict is INCONCLUSIVE, not CLEAN: a bench that could not
see the defect does not prove its absence.

probes: 3
canaries: 3
round cap: 350

## Out of scope

Publishing, versions, changelog, dependency floors, `publish:dry`, tags (the
owner, round 150). If one comes up in passing — one line at most, and not up
front. The loop's target is the code.
