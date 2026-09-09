---
status: awaiting owner
round: 220
commit: 9ee285ca
paths: [pubspec.yaml]
probe: —
reason: owner decision — it is surgery on the main gate to fix nothing currently broken, and the config's bar rules out coverage for coverage's sake
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

—
