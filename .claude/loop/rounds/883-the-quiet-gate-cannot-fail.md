---
round: 883
verdict: FIXED
packages: []
lens: RPC-23
bench: P-338 — new
commit: yes
severity: S0 — "not a product defect: the loop's tooling, gates, tests"
release: none
---

# Round 883 — the quiet gate cannot fail

## Target

Lead B-302 (filed by round 882, rank 1), taken by the owner in a manual
session ahead of the agreed order because every later commit relies on the
gate. Not chosen by `select`.

Root `pubspec.yaml`, melos script `test:unit:quiet` (lines ~164-181): a
`run:` string with `exec:`. Its `s=$?` and `exit $s` appear to be expanded
by the outer shell before `melos exec` runs the per-package command, so the
script exits 0 over failing tests. Round 882 saw it once: two `[E]` lines and
`SUCCESS`. `.claude/loop/config.md` names this script as the gate's quiet
command and claims it has the same exit status as `test:unit` — that claim
is the narrative beside the code (lens RPC-23).

Breadth: every other melos script in the root `pubspec.yaml` that combines
`run:` + `exec:` with a `$` inside the per-package body has the same shape —
count them all.

No bench yet. The lead's next step is the control: the quiet script over one
package with a deliberately failing test (scoped with `MELOS_PACKAGES` or
`--scope`), read the exit code; then fix (escape the dollars, or move the
body into a script file) and run the same control again. A deliberately
failing test must not be committed.

Class count, measured before the fix: six scripts combine `run:` with
`exec:` (`test`, `test:unit`, `test:unit:quiet`, `coverage`,
`coverage:collect`, `gen`); three carry a `$` in the body. `analyze`,
`format` and `format:check` call `melos exec -- "..."` from a plain `run:`
block with no `$` inside the quotes.

## Hypothesis

`melos run test:unit:quiet` over a package with a failing test exits 0; after
the fix it exits non-zero, and a green package still exits 0.

## Before

```
one planted expect(1, 2) in rpc_dart_compression, --scope=rpc_dart_compression
                         exit   melos verdict   per-package command melos echoes
test:unit                1      FAILED          -
test:unit:quiet          0      SUCCESS         ... 2>&1; s=0; grep ...; tail -n 1 ...; exit
coverage                 -      -               ... --base-directory="" --packages="/Users/.../rpc_dart/..."
```

Probe: `packages/core/rpc_dart_compression/.dart_tool/probe/gate_control_test.dart`
(P-338), copied into the package's `test/` for the run.

## Mechanism

melos (7.8.2, `Script.command`) turns a `run:` with `exec:` into
`melos exec -- "<body>"`, escaping only `"`, and runs that through
`/bin/sh -c 'eval "$MELOS_SCRIPT"'`. The outer shell expands every `$` in the
body once, before any package runs: `$?` became `0`, `$s` became empty, and
the bare `exit` returned `tail`'s status. MELOS_* variables are a second path:
melos substitutes them as text at the level that defines them, and `melos run`
defines only `MELOS_ROOT_PATH`, so `$MELOS_PACKAGE_PATH` reached the outer
shell and became `""`.

## After

```
                         exit   melos verdict   per-package command melos echoes
test:unit:quiet, failing 1      FAILED          ... 2>&1; s=$?; grep ...; exit $s
test:unit:quiet, green   0      SUCCESS         (same)
coverage                 -      -               ... --base-directory="$MELOS_PACKAGE_PATH" --packages="/Users/.../rpc_dart/..."
```

`coverage`'s lcov output itself was not measured: the globally activated
`coverage` package refuses Dart 3.10.1 ("coverage as globally activated
doesn't support Dart 3.10.1") before and after, so the chain stops at
`format_coverage`. The per-package command line is the measurement.

Control on the class: escaping `$MELOS_ROOT_PATH` in `coverage:collect` gave
`--base-directory="\/Users/..."` — melos's text substitution leaves the
backslash. So root-path references stay bare; only shell variables and
`MELOS_PACKAGE_PATH` are escaped.

## Canary

Two halves, two canaries, each over the planted failure:

- `exit \$s` reverted to `exit $s`: melos echoed `...; exit ` and reported
  "rpc_dart_compression: SUCCESS", exit 0.
- `s=\$?` reverted to `s=$?`: melos echoed `s=0; ...; exit $s` and reported
  "rpc_dart_compression: SUCCESS", exit 0.

Restored: "rpc_dart_compression (with exit code 1)", "ScriptException: The
script test:unit:quiet failed to execute.", exit 1. The witness is the planted
test run through the script; the guard is the escape.

## Gate

`melos run analyze` green (23 packages + wasm); `melos run test:unit:quiet
--no-select` SUCCESS over 17 packages with the fixed script (rpc_dart +2265 ~1,
conformance +621 ~158, no failures); `melos run format:check` green;
`melos run license:check` compliant (3011/3011).

## Siblings

—

## Not fixed

- `test:unit:quiet` prints `tail -n 1` of the output, which on a failing run is
  the `--chain-stack-traces` hint rather than the result line. melos's own
  summary names the failing package, so the gate's verdict is unaffected.
- The global `coverage` activation is stale for Dart 3.10.1 on this machine
  (environment, not repository), so `coverage`'s output was not measured.

## Links

RPC-23, P-338, B-302 (closed), L-04, L-05.
