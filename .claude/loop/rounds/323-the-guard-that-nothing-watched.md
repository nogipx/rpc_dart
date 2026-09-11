---
round: 323
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-14
bench: none
commit: yes
---

# Round 323 — the guard that nothing watched

## Target

RPC-14, next on 319's queue: 33 files moved since `cd6ee68e`.

The lens ends with a section called *What the sweep does NOT establish*, and it
names its own gap in numbers: every site is guarded, and **with
`teardownStartup()` deleted the isolate suite still passes `+73`**. It even names
the remedy — the subprocess shape `close_releases_the_isolate_test.dart` uses.
Round 322 had just been the argument for ablating rather than re-reading; a
fourth re-grep of the same eleven sites is the re-read, and the witness is the
measurement.

## Hypothesis

The failure paths of `RpcIsolateTransport.spawn` are guarded but unwatched, so a
guard could be removed and nothing in 21 packages would go red.

## Before

The detector, run whole on the current tree — `.timeout(` across both path
globs:

```
rpc_dart_isolate/lib          4 sites    unchanged from 223 and 246
  isolate_transport.dart:417    first handshake
  isolate_transport.dart:545    ready ack
  isolate_transport_web.dart:329  initialization
  isolate_transport_web.dart:397  ready grace (deliberate empty onTimeout)

rpc_dart/lib                  7 sites    never listed in the journal;
                                         the core sweep was off-journal at 067
  holds something, handled deliberately              2
    client_connection.dart:514   adopts the abandoned attempt
                                 (_discardAbandonedAttempt, 334b3337)
    call_scope.dart:222          abandons a USER disposer, by design, and logs
  waits on data, so nothing to own                   5
    ping.dart:229, client/caller.dart:235,
    unary/caller.dart:452 and :532, base_endpoint.dart:203
```

`base_endpoint.dart:203` is the one that looks like the shape and is not: a
timeout around `close()`, which produces no handle, and dart:async drops a
post-timeout error rather than raising it — so there is nothing to own and
nothing to leak.

**And the gap reproduces.** With the ready path's `teardownStartup()` removed,
`rpc_dart_isolate` is `+73`, green, exactly as the lens recorded.

## Mechanism

The reachable failure is the READY deadline, not the handshake one, and the
difference is in the bootstrap's order: `hostSendPort.send(receivePort.sendPort)`
runs at line 257, **before** `userEntrypoint` at 285. So a worker that blocks
synchronously has already completed the handshake, and what expires is the wait
at 545:

```
spawn threw TimeoutException after 0:00:00.500000: ... did not become ready
```

That path releases two different things, and each needs its own canary:
`teardownStartup()` kills the isolate and closes the error and exit ports, while
`hostTransport.close()` reaches `hostReceivePort` through the channel's
`onClose`. Either one left out keeps the host's event loop alive.

The observable has to be the child process's own exit — an open `ReceivePort`
keeps the loop alive and nothing inside the same isolate can see that. No
watchdog `Timer` anywhere, since a pending Timer would keep the loop alive by
itself and report a hang unconditionally.

## After

```
rpc_dart_isolate    +73  ->  +74
guard removed       +73      +73 -1
```

New: `test/audit/startup_failure_releases_the_isolate_test.dart` and
`test/support/exits_after_failed_startup.dart`.

## Canary

Both halves of the failure path, each removed on its own, and the whole suite
run under the first:

```
teardownStartup() removed      still running (killed at 20s)   suite +73 -1
hostTransport.close() removed  still running (killed at 20s)
neither removed                exited 0                        suite +74
```

The `+73 -1` is the load-bearing number: the only red is the new test, so
nothing that already existed watched this path — which is what the lens said and
what could not be claimed for the ready deadline until now.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures, `rpc_dart_isolate`
`+74`.

## Not fixed

**The first-handshake path (line 417) still has no witness, and this round could
not build one.** The bootstrap sends the handshake before user code runs, so no
entrypoint can prevent it; reaching that path needs an isolate that dies before
line 257, which is the VM's business rather than the library's. Its teardown is
a strict subset of the ready path's (`teardownStartup()` alone), so the canary
above covers the same call — but not the same branch, and the record should not
pretend otherwise.

The web sites (329, 397) are unwitnessed for the reason B-31 already records:
`test:unit` has no browser.

RPC-19 (21 files) is what remains of 319's queue; `curate` overdue since ~234.

## Links

RPC-14 (`applied:` gains 323, status re-dated to `34f0b039`), and its *What the
sweep does NOT establish* section is now half discharged rather than open.
`../lessons/L-04-a-guard-with-no-witness.md` — this is the fourth round to pay
its price and the first to retire an instance of it.
