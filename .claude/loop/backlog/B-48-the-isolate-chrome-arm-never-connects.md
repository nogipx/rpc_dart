---
status: closed (round 379)
round: 368
commit: e897128e
paths: [packages/transport/rpc_dart_isolate/test/**, pubspec.yaml]
probe: —
reason: bench — the failure is in the browser harness, before any Dart runs, and this round could not establish whether it pre-dates the round
---

# B-48 — `melos run test:web` is red on the isolate package's Chrome arm

`melos run test:web` fails on one arm:

```
packages/transport/rpc_dart_isolate
  fvm dart test -p chrome -j 1 --timeout 3x test/web_smoke_test.dart ...
  -> Failed to load "test/web_smoke_test.dart"
     BrowserManager._start  (Future.timeout)
```

Chrome never connects back to the test channel. It fails the same way at
`--timeout 3x` and at `6x`, so it is not the cold start the script's own comment
predicts.

## What rules out the obvious causes

- **Not Chrome in general.** `rpc_dart_websocket`'s `-p chrome`
  `websocket_web_smoke_test.dart`, same machine, same session, resolves the same
  local core: **4 passed**, including two caller/responder round trips.
- **Not the dart2js node arm.** Every node arm inside `melos run test:web` is
  green. A bare `fvm dart test -p node` dies `ENETDOWN` on all 115 files because
  only the repo's `test:web` script sets
  `NODE_OPTIONS=--dns-result-order=ipv4first` — the trap already written up in
  private memory, and not this.
- **Not round 368's diff.** The failure is at browser load, before any Dart from
  this package or from core executes, and the control above exercises the changed
  core through the same Chrome path.

## Not established

Whether it pre-dates round 368. `git stash` is forbidden by rule zero and no
control run on an earlier tree was taken, so this is open rather than closed.

## What would close it

Run the same arm on a tree without round 368's commit. If it is red there too,
the lead becomes a harness question about that package alone — it is the only
one whose Chrome arm compiles a Web Worker entry point
(`test/web_worker/echo_worker.dart.js`) before the suite, which is the one thing
its Chrome invocation does that no other package's does.

## Closed — round 379

**The file does not exist.** `packages/transport/rpc_dart_isolate/test/` holds no
`web_smoke_test.dart`, and the `test:web` script named it anyway. `dart test`
answers a missing path by building a load suite for it and starting a browser
that then has nothing to connect to — so the failure surfaces as
`BrowserManager._start` timing out, **which is exactly the cold-start flake the
comment three lines above it describes**. Every retry and every raised timeout
read as confirmation of the wrong theory, which is why it survived this filing,
round 377's work in the same package, and two deliberate re-runs.

Both theories in the record above were wrong: not Chrome (websocket's arm passes
on the same machine), and not round 378's IPv4 trap. The question this record
left open — whether it pre-dates round 368 — is answered by the cause: the path
was wrong for as long as it has been in the script, independent of any round.

Path removed, comment added saying the package has no such file. `test:web` is
green end to end.

**Left open, deliberately**: no `web_smoke_test.dart` was written for this
package. Every other web-tested package has one, so its absence may be an
oversight — but writing one is adding coverage, a different job from repairing a
gate, and inventing it here would have hidden the question.

## Owner decision

—
