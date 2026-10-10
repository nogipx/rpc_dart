# mutants

Mutation testing for one library file. It changes one operator on one line,
runs the tests, and reports the changes the tests did not notice.

## What a result means

- **SURVIVED**: the tests pass with the line changed. Nothing constrains that
  line. This is a hypothesis for an evidence-loop round, not a finding: the
  mutant may be equivalent (the change cannot be observed), or the behaviour
  may be wrong and untested. A round decides which, with a probe.
- **KILLED**: at least one test failed. A **TIMEOUT** counts as killed and is
  listed separately.
- **STILLBORN**: the mutant did not compile. It says nothing about the tests.

## Run

From the repo root:

```
fvm dart run tool/mutants/mutants.dart \
  --file packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart \
  --tests packages/core/rpc_dart/test/transports/flow_controller_test.dart,packages/core/rpc_dart/test/transports/flow_control_test.dart \
  --limit 40 --report /tmp/mutants.json
```

- `--tests` takes files or directories, comma-separated, all in the package
  that owns `--file`.
- `--limit N` runs N mutants sampled evenly across the file. Without it, the
  tool runs as many as fit in about 15 minutes at the baseline test time.
- `--timeout SECONDS` per mutant. Default: 3x the baseline, at least 60.
- `--list` prints every mutant and runs nothing.
- `--report PATH` writes the results as JSON.

`melos run mutants` prints the usage. The tool is not part of `prepare`,
`test` or CI, and must not be.

## How it works

The run happens in a detached git worktree of HEAD under the system temp
directory, so the main working tree is never written to. Uncommitted changes
are not tested: commit a new test first. The tool runs
`fvm dart pub get --offline` there, then runs the tests once without a
mutation. A red baseline aborts the run, because every mutant would then read
as killed. The worktree is removed at the end, also on an exception, Ctrl-C or
SIGTERM. If a run was killed outright, the next run removes its worktree.

Operators, applied one at a time (the table is `_operators` in
`mutants.dart`; add a row to add one):

| operator     | change                                                  |
| ------------ | ------------------------------------------------------- |
| relational   | `<` and `<=`, `>` and `>=`                              |
| equality     | `==` and `!=`                                           |
| logical      | `&&` and `\|\|`                                         |
| boolean      | `true` and `false`                                      |
| negation     | `if (!x)` to `if (x)`                                   |
| off-by-one   | integer literal right of a comparison: `n` to `n + 1`   |
| delete-guard | delete a line that is `return;`, `continue;`, `break;`, or a one-line `if (...) return ...;` |

Comments, string literals (with their interpolations) and import, export,
part and library lines are never mutated. A binary operator must have
whitespace on both sides, which `dart format` guarantees and generic brackets
never have, so `List<int>`, `=>` and `>>` are left alone.

## Cost

One full test run per mutant, run in sequence. With 14 flow-control test
files the baseline is about 20 s, so 40 mutants take about 14 minutes. The
tool prints the estimate after the baseline run. Choose the smallest set of
tests that covers the file: the cost is per mutant.
