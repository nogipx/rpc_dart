---
round: 768
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-268 — new
commit: yes
release: changelog
---

# Round 768 — a message larger than the window stalled the stream

## Target

Found while building round 767's stall test: is the small-window stall
rpc_data's or the core's? `RpcFlowController`'s grant path, which every
channel-based transport uses (memory pair, websocket, isolate). HTTP/2
runs its own flow control.

## Hypothesis

A server stream of messages larger than the per-stream window stops for
good under the default policy.

## Before

P-268, default policy, reading throughout:

```
  5 MB  x 3   received 3   done
  6 MB  x 3   received 3   done
  7 MB  x 3   received 2   STUCK (20 s, and 90 s)
  8 MB  x 3   received 2   STUCK
  12 MB x 3   received 1   STUCK
```

16 MiB is the default message limit, so these are ordinary messages.

## Mechanism

A message is admitted while any credit remains, so one larger than the
window leaves the sender's credit below zero by up to a message. The
receiver returns everything it consumed in one grant, and the sender capped
that grant at the window BEFORE adding it, to keep a hostile grant from
lifting credit and the sum from overflowing. The cut part was lost: the
receiver had nothing more to grant, the credit stayed negative, and the
sender parked forever. Same at the connection level. Fix: `_applyGrant`
caps the result at the window instead (`window - held` bounds the grant),
which keeps both protections and loses nothing.

## After

```
  7 MB  x 3   received 3   done
  12 MB x 3   received 3   done
  16 MB x 3   received 3   done
  15 MB x 6, paused and resumed   received 6   done
```

## Canary

`packages/core/rpc_dart/test/transports/a_message_larger_than_the_window_does_not_stall_test.dart`
(3 of 3 green) and a unit test in `flow_controller_test.dart`, `a grant
returning an overdraft is not cut to the window`.

```
  old controller        Expected: <3>  Actual: <2>
                        the stream stalled once a grant was cut to the window
  old controller        Expected: <1000>  Actual: <-3000>   (unit)
  connection half only  Expected: <1000>  Actual: <-3000>   (unit)
```

## The verdict questions

1. The arms differ in message size only.
2. Yes: 2 against 3 received, STUCK against done.
3. Messages delivered to the caller, and the sender's credit in the unit
   test.
4. n/a.
5. Yes, above.
6. Two halves (stream, connection); the connection half is witnessed by
   the unit test only, since a message over the 64 MiB connection window
   is over the message limit.
7. FIXED from the counts.
8. Nothing dismissed. The hostile-grant tests (`a grant cannot lift credit
   above the window`) stay green: the cap still holds.
9. A clamp applied to an increment rather than to the resulting state
   loses whatever the state owed: clamp the state. Price: a hang on every
   message between the window and the message limit.
A1. One policy on both ends.
A2. Volume.
L1. No refusal: the stream parked on credit.

## Gate

`melos run analyze`, `format:check`, `test:unit` green; core transport
tests 356/356.

## Not fixed

The receiver's connection-total buffer bound has no room for the
documented one-message overshoot: with a 64 KiB connection window and
40 KB messages a paused caller gets `RESOURCE_EXHAUSTED ... past the
connection total` (P-268, `WINDOW=65536 SIZE=40000 pause`). The per-stream
bound carries that slack (`effectiveStreamBufferBytes`), the connection
bound (`flowControlConnectionWindowBytes`) does not. Next round.

## Links

Probe `../probes/P-268-what-a-message-larger-than-the-window-does.md`.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md`.
Round `767-a-watcher-that-stops-reading-held-every-change.md`.
