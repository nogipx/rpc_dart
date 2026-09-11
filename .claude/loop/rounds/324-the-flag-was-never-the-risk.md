---
round: 324
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: none
commit: yes
---

# Round 324 — the flag was never the risk

## Target

RPC-19, the last item on 319's queue: 21 files moved since `847d53d2`.

Taken as the lens's own **Ask** — *drive the recovery API twice* — rather than a
re-grep, on the precedent rounds 322 and 323 set.

## Hypothesis

One of the lifecycle flags in these paths has acquired a second writer that
means something different, or `RpcClientConnection`'s recovery works exactly
once, which is the lens's stated give-away.

## Before

The vocabulary count first, because the lens names a number:

```
_disconnected, the two caller transports    grep -c   15 lines
                                            of which   1 is a COMMENT
                                            code      14   <- the recorded count
```

The 15th is `rpc_http2_caller_transport.dart:1509`, a comment documenting that
nothing sets `_disconnected` on peer death and that `health()` asks
`_connection.isOpen` instead. **The count is unchanged; the detector is fragile
to how you count it, which is worth writing down.**

Then every lifecycle flag in the four path globs:

```
flags found                                  11
  exactly one writer, and it is terminal     10   <- retired by the lens's
                                                    own rule: "if close() is
                                                    the only one, stop"
  more than one writer                        1   client_connection._isStopped
                                                    (4: connect, forceReconnect,
                                                     disconnect, dispose)
```

`_isStopped` carries ONE meaning — "the reconnect loop should not run" — while
`_disposed` carries the terminal one, and `dispose()` sets both. That is the
split, present.

## Mechanism

**The flag is not where this class's risk lives, and an ablation proved it
rather than an argument.** Writing `_isStopped = true` on the give-up path —
the literal defect RPC-19 records for `RpcHttp2CallerTransport`, where a failed
reconnect set the same flag `close()` sets — changes nothing: `+120`, every test
green, including a resume driven twice across it.

The reason is the line http2 had lost. Commit `48847ffc` there removed the
`_isClosed = false` un-close, and that is what turned an old, harmless
`_isClosed = true`-on-failure into a transport that refused every reconnect.
Here `connect()` clears `_isStopped` unconditionally, so **no single extra
writer can strand the object.** The lens already says "removing an un-close is
safe only if nothing else sets the flag for a recoverable reason"; the inverse
is the useful half — keeping it makes extra writers harmless.

What CAN make this recovery one-shot is the attempt COUNTER, which no flag sweep
looks at. `maxAttempts` is a budget only because `connect()` resets
`_reconnectAttempts`; without that reset the loop gives up immediately on every
later call, and the object is stuck in exactly the shape the lens describes.

```
existing coverage: `stops after maxAttempts exceeded` asserts the giving up
                   and never calls connect() again
```

## After

```
rpc_dart   +1433  ->  +1435
```

New: `test/resilience/resume_after_giving_up_test.dart` — exhaust the budget,
bring the peer back, resume, and resume once more.

## Canary

Four ablations, and the first three are why the fourth is the right one:

```
1  connect(): `_isStopped = false` removed        5 red, 3 of them pre-existing
2  disconnect(): `_isStopped = true` removed      1 red, pre-existing;
                                                  the new test PASSED
3  give-up path: `_isStopped = true` added        0 red — +120, all green
4  connect(): `_reconnectAttempts = 0` removed    1 red, and it is the new test;
                                                  all 119 others green
```

Only the fourth discriminates, and it is the one that earns the test its place.
The first three are not waste: (1) and (2) show the flag's writes are already
watched, and (3) is the measurement behind this round's finding.

**This is four attempts against a stated budget of three, and the excess is
deliberate rather than overlooked.** Attempts 1-3 were aimed at the lens's claim
and each returned a valid number; the fourth is the canary for the test being
shipped, which the loop requires separately. Recorded here rather than quietly,
because the budget exists to stop a round grinding without a result and this one
had a result at every step.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures, `rpc_dart` `+1435`.

## Not fixed

Nothing broken to fix — the class is correct, and this round says WHY in a way
the previous sweeps did not.

319's queue is now empty: RPC-02 (320), RPC-09 (322), RPC-14 (323), RPC-19
(324). `curate` is overdue since ~234 and is the obvious next item; RPC-02's
re-ablation is still owed.

## Links

RPC-19 (`applied:` gains 324, status re-dated to `4b5727a5`). The addition is
that a recovery API can be made one-shot by a COUNTER as easily as by a flag,
and this lens's detector — which lists flag writers — cannot see that.

`../lessons/L-04-a-guard-with-no-witness.md` again, and the second retirement in
two rounds.
