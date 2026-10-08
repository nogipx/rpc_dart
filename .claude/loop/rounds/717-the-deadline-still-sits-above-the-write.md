---
round: 717
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http]
lens: RPC-09
bench: P-233 — new
commit: yes
release: none
---

# Round 717 — the deadline still sits above the write

## Target

`next` reported no open leads and one swept lens whose paths moved: RPC-09,
59 files since round 434. Among them the message credit of rounds 709-711,
which is a new way for a sender to park, and some forty `rpc_dart_http`
commits. Both halves of the lens's `paths:` were taken: core (P-10 re-run,
wake paths recounted) and HTTP/1.1 (no bench had ever covered the upload
phase there).

## Hypothesis

1. Core: message credit added a parking reason with a wake path the P-10
   ablation does not cover, or a frame that is debited and never credited, so
   a sender parks for good.
2. HTTP/1.1: `_fireRequest` writes the whole body before it can see a
   response. Against a server that stops reading, the call's deadline either
   does not fire, or fires and leaves the client writing into an abandoned
   socket.

## Before

Core. Wake paths recounted from the code, every `_wake` / `wakeAll` call in
`flow_controller.dart`:

```
:373  legacy grace timer
:454  _onGrant               per-stream bytes and messages
:662  handleInbound          connection credit
:694  _noteMessagesLegacy    a peer granting bytes without messages   NEW (709)
:741  forget
:754  close
```

Debit and credit of message credit are symmetric: `_sendMetered` is the only
caller of `tryConsume`/`awaitCredit`, reached only for a payload or a direct
object, and the receiver credits by the same predicate
(`RpcFlowController.carriesMessage`). The one site that returns bytes without
the message, the refused branch at `channel_transport.dart:1042`, runs only on
a stream already failed.

P-10, `parked_sender_learns.dart`:

```
                          normal                     _onGrant refuses all
  CONTROL drains     completed, 0.2 s, 2000 pulled   HUNG 20 s, 16 pulled
  CASE answers early completed, 0.4 s, 19 pulled     completed, 0.4 s, 19 pulled
```

HTTP/1.1. Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/r717_upload_into_a_deaf_server.dart`.
A raw `ServerSocket` reads one chunk and stops reading, never answers.
Observed for 5 s after resuming the reads:

```
  arm                           call               server total  closed by client
  8 MiB, deadline 1 s           status 4, 1075 ms  2432 KiB      true
  CONTROL 8 MiB, no deadline    HUNG               8192 KiB      false
  1 KiB, deadline 1 s           status 4, 1003 ms     1 KiB      true
  CONTROL dart:io abort at 1 s  -                  2432 KiB      true
```

## Mechanism

Core: the response path does not wait on the request pump, and the new
parking reason wakes through `_onGrant` like bytes do. HTTP/1.1: the unary
caller's deadline sits on the response completer, its `finally` calls
`releaseStreamId`, which completes `abortTrigger`, and `IOClient` answers that
with `HttpClientRequest.abort()` while the body pipe is still running.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. Bench sensitivity, both halves:

- P-10 with `_onGrant` returning at once: the draining call HANGS at 20 s.
  The new `_noteMessagesLegacy` wake does not mask it, since current peers
  send the messages header.
- P-233 with `abort.complete()` removed from `releaseStreamId`: the 8 MiB arm
  reads 8192 KiB total and `closed by client: false`. The client keeps
  uploading into a call that already returned DEADLINE_EXCEEDED.

## The verdict questions

1. Yes. P-10: one ablated method. P-233: one removed line; the dart:io arm
   checks the dependency apart from the library.
2. Yes. 2432 against 8192 KiB, `true` against `false`; HUNG against completed.
3. Server side, `_Deaf.bytes` and `onDone`; P-10 counts pulls at the generator.
4. Not zero. The ablation shows the mechanism can emit. The 5 s window is
   justified: a first run that observed for 2 s read `false` everywhere, since
   the release is chained after the notice (`_noticeBeforeReleaseBudget`).
5. No fix, so no witness.
6. n/a.
7. CLEAN, with a valid control on each half.
8. None. The 2 s window was a probe mistake, caught by the dart:io arm before
   it was recorded.
A1. One process, separate objects. The raw server has no policy; the caller
    uses the default `RpcSecurityPolicy`.
A2. Volume: 8 MiB against the loopback socket buffers. No latency is needed.
L1. The status comes from the caller's own deadline (status 4). No limit fired.

## Gate

No library change. Both ablations were reverted, and `git status` was clean
before the record was written. `license:check` is green over the new journal
files (2520 / 2520), and `loop.py lint` reports 0 errors.

## Not fixed

Nothing found. The upload phase has no regression test of its own: the
existing `an_abandoned_call_stops_downloading_test` kills the same line,
`abort.complete()`, but reaches `IOClient`'s after-response branch, not the
`ioRequest.abort()` one. That branch is dependency code.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md` — `applied: [..., 717]`,
`swept here (round 717)`. Bench `../probes/P-10-parked-sender-learns.md`
re-run; new `../probes/P-233-upload-into-a-deaf-server.md`.
