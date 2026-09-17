---
round: 379
verdict: FIXED
packages: []
lens: RPC-15
bench: none — the observable is a gate script's exit status; the variation is removing one path from it
commit: yes
---

# Round 379 — the gate that failed on a missing file

## Target

The owner asked to bring the backlog up to date. B-48 was the entry to check
first, because I filed it myself in round 368 with `Not established: whether it
pre-dates round 368` — an admission that the round had not finished the job.
RPC-15: re-measure the loop's own record.

## Hypothesis

`melos run test:web` is red on `rpc_dart_isolate`'s Chrome arm for an
environmental reason — a cold browser start, or the IPv6-first resolution trap
round 378 met.

Both were wrong.

## Before

`melos run test:web`:

```
Failed to load "test/web_smoke_test.dart"
  BrowserManager._start  (Future.timeout)
```

Identical at `--timeout 3x` and `6x`, and unchanged after round 377 added a VM
test to the same package. Round 378's IPv4 finding does not explain it either:
`rpc_dart_websocket`'s Chrome smoke passes 4/4 on the same machine.

**The file does not exist.** `packages/transport/rpc_dart_isolate/test/` holds
no `web_smoke_test.dart`, and the `test:web` script names it anyway.

```
ls packages/transport/rpc_dart_isolate/test/
  analysis_options.yaml  audit  bidi_subscription_over_isolate_test.dart
  deeply_immutable_is_shared_test.dart  isolate  isolate_crash_isolation_test.dart
  isolate_transport_test.dart  isolate_verification_test.dart
  isolate_zero_copy_demo_test.dart  support
```

## Mechanism

`dart test` answers a path that does not exist by building a load suite for it
anyway and starting a browser, which then has nothing to connect to. The failure
surfaces as `BrowserManager._start` timing out — **which is exactly the
cold-start flake the comment three lines above it describes**, so every retry and
every raised timeout read as confirmation of the wrong theory.

That is why it survived round 368's filing, round 377's isolate work, and two
deliberate re-runs at different timeouts.

## After

The path is removed from the script, with a comment saying the package has no
such file and why its absence looks like a flake.

```
melos run test:web   ->   All tests passed! (5 in the isolate arm, all arms green)
```

The gate is green end to end for the first time in this session.

## Canary

The variation is the path itself: with `test/web_smoke_test.dart` in the list
the arm fails at `BrowserManager._start`; without it the same command passes.
Nothing else changed, and the two `web_worker` files that were always in the
list still run and still pass — so the arm was not disabled, it was corrected.

## Gate

`melos run test:web` green, which is the gate this round repairs.
`melos run analyze`, `test:unit`, `format:check` and `license:check` were green
at round 378 and no library code moved.

## Not fixed

**No `web_smoke_test.dart` was written for this package.** Every other web-tested
package has one, and this one's absence may be an oversight rather than a
decision — but writing one is adding coverage, which is a different job from
repairing a gate, and inventing it here would hide the question. Filed as the
open half of B-48's replacement note.

## Links

- RPC-15 — the lens; `applied:` gains 379
- B-48 — closed by this round; its own "not established" is what made it the
  first thing to check
- Round 378 — the IPv4 trap, which was the plausible-and-wrong explanation
- L-05 — green locally is not green clean; here the inverse, a RED that was not
  the environment
