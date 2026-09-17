---
round: 379 — where it was paid for; filed in round 382
class: toolchain
cost: eleven rounds. B-48 was filed in 368 with "not established whether it pre-dates this round", survived round 377's work in the same package and two deliberate re-runs at --timeout 3x and 6x, and the cause was that the script named a file the package does not have
paths: [pubspec.yaml]
commit: 6a3cb2c1
status: active
---

# L-14 — a red that reads like a known flake

`melos run test:web` failed on one arm with

```
Failed to load "test/web_smoke_test.dart"
  BrowserManager._start  (Future.timeout)
```

and three lines above the invocation, in the script itself, sat a comment
explaining that starting several cold Chromes at once makes them miss the
connect deadline. The failure matched the comment exactly. So it was filed as
environmental, re-run, re-run again with the timeout doubled, and left open for
eleven rounds.

**The file does not exist.** `dart test` answers a path that is not there by
building a load suite for it and starting a browser, which then has nothing to
connect to — and that surfaces as the same timeout a cold start does.

> **The tell is that it survives the remedy the flake would respond to.** A cold
> start responds to waiting longer. Three retries and a doubled timeout changed
> nothing, and that should have been the signal — not more retries.

A second tell, cheaper still: **a neighbour that should fail the same way and
does not.** `rpc_dart_websocket`'s Chrome arm passed 4/4 on the same machine in
the same session, which rules out "Chrome is unhappy here" in one command.

The trap is specifically that the codebase DOCUMENTS the flake. A comment saying
"this is known to be flaky" is a prior that makes a matching symptom read as
confirmation, and it costs nothing to check the cheapest concrete fact instead —
here, whether the path exists.

Related: the same session hit the inverse of this twice, where a plausible and
documented explanation was right about a different thing — round 380's initial
window, and round 382's `_pipelineFedRequestStream`. See
[L-13](L-13-a-decision-inherits-the-sentence-it-was-taken-on.md).
