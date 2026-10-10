---
round: 819
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http]
lens: RPC-09
bench: P-10 — reused
commit: yes
severity: S3
release: none
---

# Round 819 — the deadline still sits above the write, again

## Target

`loop.py stale`: the RPC-09 sweep (round 774, 8d804d9f) had 37 changes
along its paths, among them the http caller (rounds 806-807) and core's
stream processors (rounds 803-805).

## Hypothesis

A change since round 774 made a caller's answer wait on its parked send, or
removed a wake path, so a call against a server that stopped reading hangs.

## Before

Wake paths by `find_callers` on `RpcFlowController._wake` and `wakeAll`:

```
  _armLegacyGrace, _onGrant, handleInbound (connection credit), forget,
  _noteMessagesLegacy, close        six, the same six as rounds 717 and 758
```

## Mechanism

n/a (CLEAN).

## After

P-10 (`parked_sender_learns.dart`), both columns; the ablation returns at the
top of `_onGrant`, restored after:

```
                          normal                   grants refused
  CONTROL drains     completed 'drained'       HUNG, 20.0 s, 16 pulled
                     0.2 s, 2000 pulled
  CASE answers       completed 'early'         completed 'early'
  early              0.4 s, 19 pulled          0.4 s, 19 pulled
```

P-233 (`r717_upload_into_a_deaf_server.dart`):

```
  8 MiB, deadline 1 s        status 4, 1070 ms, closed by client
  CONTROL no deadline        HUNG, 8192 KiB written, not closed
  1 KiB, deadline 1 s        status 4, 1004 ms
  CONTROL dart:io abort      closed by client
```

## Canary

The ablated column is the control: starving the stream grant still hangs
the draining call, so the bench still sees a credit hang.

## The verdict questions

1. The columns differ in the stream grant path only; P-233's rows in the
   deadline only.
2. Yes: HUNG against completed.
3. At the caller.
4. 20 s against 0.4 s; 1070 ms against a hang.
5. n/a.
6. n/a.
7. CLEAN: all cells as in round 774 and 717.
8. Nothing dismissed.
9. none.
10. No code changed.
A1. One policy. A2. Volume. L1. n/a.

## Gate

No code changed; the ablation was reverted.

## Siblings

No code changed. websocket and isolate share core's flow controller; http2
not re-measured (low priority).

## Not fixed

none.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md`. Benches
`../probes/P-10-parked-sender-learns.md`,
`../probes/P-233-upload-into-a-deaf-server.md` (also re-run).
