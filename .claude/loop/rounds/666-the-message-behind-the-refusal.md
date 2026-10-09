---
round: 666
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-230 — new
commit: yes
release: changelog
severity: S2
---

# Round 666 — the message behind the refusal

## Target

B-186, from the audit's static read: on a window overrun the caller delivers
the error before the message that caused it. RPC-25 because the meter exists
twice -- the caller's `_fcOnDelivered` and the responder's -- so both copies are
the scope. Two sites; each refuses from inside `_emit` and then delivers.

(Round 665 is another session's, uncommitted in this tree; this one skips it.)

## Hypothesis

Both `_emit`s charge, refuse, then deliver the charged message anyway.

## Before

```
caller     [headers, data, data, data, ERROR, data, done]   data after the error 1
responder  [data, data, data, CANCEL, data, CANCEL, ...]    data after the cancel 1
```

## Mechanism

`_emit` calls `_fcOnDelivered` before delivering. On the caller the overrun
emits RESOURCE_EXHAUSTED and starts `resetStream`, whose controller removal is
behind an await; on the responder it emits the cancellation frame. Either way
`_emit` then adds the overrunning message to the same stream.

## Fix

Caller: `_emit` drops a message for a stream in `_resetStreams` -- the same set
`_emitStreamError` already uses to silence a stream we reset. Responder: drops a
payload for a stream in `_fcRefused`; metadata still passes, because the
cancellation itself goes through `_emit`.

## After

```
caller     [headers, data, data, data, ERROR, done]         data after 0
responder  [data, data, data, CANCEL, CANCEL, ...]          data after 0
```

## Canary

`packages/transport/rpc_dart_http2/test/an_overrun_error_is_the_last_event_test.dart`,
one test per half:

- caller guard off: `Expected: 'overrun' Actual: 'data' -- the overrunning
  message must not arrive after the error`.
- responder guard off: `Expected: not contains 'data' Actual: ['cancel', 'data',
  'data', 'cancel'] -- the overrunning payload must not follow the
  cancellation`.

Both restored: 2 of 2 green.

## The verdict questions

1. Yes: the guard alone differs. The pause is the control for the overrun
   itself: without it, no refusal.
2. Yes: 1 payload after the refusal before, 0 after, on both sides.
3. Yes: the transport's own per-stream stream.
4. Yes: the before column shows the mechanism emitting; 500 ms covers a 40 ms
   send.
5. Yes, quoted above.
6. Yes, two halves, two canaries.
7. Yes.
8. None.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart_http2 +282); `format:check` clean after formatting the new test;
`license:check` compliant.

## Not fixed

Nothing on B-186.

## Links

Lead `../backlog/B-186-http2-overrun-error-arrives-before-data.md` closed.
Bench `../probes/P-230-what-follows-an-overrun.md`.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 666]`.
