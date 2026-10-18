---
file: packages/core/rpc_dart_compression/.dart_tool/probe/gate_control_test.dart
round: 883
commit: 73fe8093
paths: [pubspec.yaml]
status: stale (526c8d52)
promoted: no — a test that fails on purpose cannot live in the suite; every gate run would be red
---

# P-338 — the gate over a planted failure

Copy the probe file into `packages/core/rpc_dart_compression/test/` (it is one
`expect(1, 2)`), run `melos run test:unit:quiet --no-select
--scope=rpc_dart_compression`, read the exit code and melos's echo of the
per-package command, then move the file back out of `test/`. Any other melos
script with `exec:` can be run the same way to see what reaches each package.

## Measures

The exit code of the melos script over one package whose suite has one failing
test, and the per-package command line melos echoes after its outer shell.

## Control

The same package without the planted test (all green), and `melos run test:unit`
over the planted failure:

```
                         planted failure    green package
test:unit                exit 1             -
test:unit:quiet before   exit 0, SUCCESS    not run
test:unit:quiet after    exit 1, FAILED     exit 0
```
