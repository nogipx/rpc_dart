---
round: 695
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-21
bench: none — two new tests, `a_protocol_close_is_reported_by_health_test.dart` and `an_overrun_reaches_the_caller_as_a_status_test.dart`
commit: yes
release: none
---

# Round 695 — two responder claims measured clean

## Target

B-190, the http2 responder's lifecycle. Two of its claims have a direct
witness:

1. `_closeForProtocolError` terminates without setting `_isClosed`, so
   `health()` says ready.
2. `_fcRefuseOverrun` sends its RESOURCE_EXHAUSTED trailer unawaited and
   `endStreamNow` then drops it.

## Hypothesis

Both by reading.

## Before

1. `closeOnProtocolError: true`, a raw client sends `:path` without a leading
   slash; the server ends the connection (`conn.isOpen` false, the premise)
   and the endpoint's `transport.health()` is read.
2. A 64 KiB `flowControlWindowBytes`, a client stream of 64 x 16 KiB into a
   handler that never reads.

```
1. health after a protocol close   not healthy
2. caller's outcome                status 8: Request exceeds the un-consumed window (65580 > 65536 bytes)
```

## Mechanism

Neither defect shows. For 1, something past `terminate()` already moves the
transport out of `healthy` -- not traced. For 2, the trailer reaches the
caller.

## Fix

None. Both tests stay as guards.

## After

As Before.

## Canary

None for a clean result; each test asserts its premise (the connection did
close; the call was refused with the window message, not timed out).

## The verdict questions

1. A clean round; the premises are the controls.
2. Yes, two claims as stated.
3. Yes: `health()` and the caller's status.
4. Not zero-valued.
5. Yes, quoted.
6. Two claims, two checks.
7. Not a policy question.
8. None.

## Gate

The two tests, `analyze` of them; the suite in round 694's gate, unchanged
code.

## Not fixed

B-190's other claims stay open on the lead: the unowned `incomingStreams`
subscription (a race at the close window, not built), status-less endings on
`close()`/`releaseStreamId` (UNAVAILABLE for a server shutting down may be the
right answer -- a design question), and missing error handling in
`_closeIfDrained` and the sequential cancels.

## Links

Lead `../backlog/B-190-http2-responder-lifecycle-defects.md` -- two claims
clean, open.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` -- `applied: [..., 695]`.
