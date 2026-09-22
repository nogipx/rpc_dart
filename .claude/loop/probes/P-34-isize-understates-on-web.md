---
file: packages/core/rpc_dart_compression/test/audit/isize_understates_on_web_test.dart
round: 286
commit: ae723c08
paths: [packages/core/rpc_dart_compression/lib/**]
status: valid
---

# P-34 — the same gzip bomb on both runtimes

**A bench that is also the regression test**, because the thing being measured is
a platform difference and the only honest way to show one is to run the
identical code on both. `fvm dart test` against `fvm dart test -p node`.

It forges the ISIZE trailer rather than wrapping it: gzip 64 MiB of zeros, then
overwrite the last four bytes to declare 4096. Arithmetically that is what a
4 GiB wrap does to the pre-check, without compressing 4 GiB — which is what lets
it run on web at all, where `dart:io`'s encoder does not exist.

## Measures

Milliseconds to REFUSE. Not RSS: node does not expose `ProcessInfo.maxRss` the
way the VM does, and the difference here is three orders of magnitude, so a
clock is enough.

The time is printed, never asserted. A threshold would pin the platform
difference; the test asserts the CONTRACT — over the limit is refused — which
must hold on both.

## Control

The GUARD test: an honest 1 MiB payload still round-trips, so the witness cannot
pass on a codec that refused everything. And the first assertion checks the
forged trailer reads as harmless, so the pre-check is not what does the
refusing — without it the test would prove nothing about the path after it.

```
runtime          round 286   round 427   mechanism
VM                   12 ms       13 ms   boundedInflate aborts at the limit
dart2js / node    15980 ms    13463 ms   no bounded inflater: 64 MiB inflated,
                                         then rejected
ratio                1332x       1036x
```

Round 427's web figure is the median of three (13606 / 13094 / 13463). **The
finding is intact across 141 rounds and the figure moved 16%**, which is why the
public documentation it fed carries the shape and points here for the number
rather than quoting one.

## What this bench CANNOT do

**It cannot canary `boundedInflate`.** Disabling it and re-running this fixture
reads 22 ms on the VM, which looks like the abort still working and is not:
`dart:io`'s gzip filter rejects the FORGED trailer outright, one layer upstream
of the limit. The ablation is absorbed before it reaches the code under test.

For that, use `isize_wrap_bomb_test.dart` — VM-only, builds a true 4 GiB wrap
the filter accepts, and with `boundedInflate` disabled reads **RSS +2072 MiB**
against its 400 MiB bound. The two fixtures look interchangeable and are not.

> **Run the identical test on both runtimes and print, do not assert, the
> number.** The VM half of this was already covered by `isize_wrap_bomb_test`,
> which is `@TestOn('vm')` because it needs `dart:io` to build a true wrap — so
> the platform without the defence was the one the test could not reach. Making
> the fixture buildable everywhere is what turned a reading into a measurement.
