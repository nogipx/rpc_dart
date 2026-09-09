---
status: open
round: 220
commit: 9ee285ca
paths: [pubspec.yaml]
probe: —
reason: decided by owner (round 223) — close the gate; ready to implement
---

# B-19 — close the gate over rpc_dart_wasm

`analyze` and `format:check` never see `rpc_dart_wasm`, because both use melos's
member-scoped `exec:` form and that package is deliberately outside the pub
workspace. Its Dart source is therefore analysed and format-checked by nothing,
including `melos run prepare`, the release gate. Measured in round 220 and
recorded as `../checked/C-22-wasm-is-outside-every-gate-script.md`; both checks
are clean today, so nothing is broken.

## The change, if it is wanted

Convert both scripts from `exec:` to a `run:` block that does the member sweep
and then the one extra package by hand, which is exactly the pattern
`publish:dry` already uses for this same package:

    analyze:
      run: |
        set -e
        melos exec --concurrency 6 -- "fvm dart analyze --fatal-infos --fatal-warnings ."
        echo "--- rpc_dart_wasm (outside the workspace) ---"
        fvm dart analyze packages/transport/rpc_dart_wasm

and the equivalent for `format:check`. Verify by running both and confirming
they still fail correctly on a member — the risk here is turning a strict gate
into a permissive one while it still prints green.

## Why it was not just done

Restructuring the two scripts every round depends on, to fix nothing that is
currently failing, is not proportionate on the loop's own bar — which rules out
coverage for coverage's sake. But the guarantee is structural rather than
cosmetic: the one package that ships native code and can get an application
rejected from an app store currently relies on somebody remembering two
commands.

## Owner decision

**Close the gate.** (Asked and answered in round 223.)

Do the `exec:` → `run:` conversion above for both `analyze` and `format:check`.

The "not proportionate, nothing is currently broken" objection was written
before rounds 222 and 223 found the same shape twice over: a protection that is
real today and unwitnessed tomorrow. Same argument here — the checks pass, and
nothing would notice if they stopped covering the one package that ships Swift
and Kotlin.

Notes for the round that carries this out:

- **The risk is a strict gate quietly becoming a permissive one while still
  printing green.** `set -e` alone is not enough: `melos exec` and the trailing
  `fvm dart analyze` both have to be able to fail the script.
- So the verification is an ablation, not a run: plant a `--fatal-infos`-level
  lint in a workspace MEMBER and confirm the converted `analyze` still goes red,
  then plant one in `rpc_dart_wasm` and confirm it goes red too. Both arms, or
  the conversion has not been checked.
- The pattern already exists in this same file — `publish:dry` handles this same
  package explicitly right after its melos step. Follow it rather than inventing
  a second shape.
- `format:check` needs the same treatment and the same two-arm ablation.
- `melos run prepare` composes these two, so closing them closes the release
  gate as well; confirm that rather than assuming it.
