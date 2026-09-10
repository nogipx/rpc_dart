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
runtime        refused in   mechanism
VM                  12 ms   boundedInflate aborts at the limit
dart2js / node   15980 ms   no bounded inflater: 64 MiB inflated, then rejected
```

> **Run the identical test on both runtimes and print, do not assert, the
> number.** The VM half of this was already covered by `isize_wrap_bomb_test`,
> which is `@TestOn('vm')` because it needs `dart:io` to build a true wrap — so
> the platform without the defence was the one the test could not reach. Making
> the fixture buildable everywhere is what turned a reading into a measurement.
