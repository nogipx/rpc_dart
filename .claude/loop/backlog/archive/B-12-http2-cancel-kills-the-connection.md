---
status: closed (round 208) — option 2 shipped; the upstream report is still open
round: 207
commit: 1d5efdda
paths: [packages/transport/rpc_dart_http2/lib/**]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/aborted_upload_pool.dart
reason: risk — the discard is inside package:http2, and every rpc_dart-side lever trades away the upload bound this loop installed; a safety-for-safety trade is the owner's
---

# B-12 — http2: cancelling a stalled call kills the connection for good

Measured in round 207, both directions, each against a control that differs
only in how the stalled call ENDS:

    UPLOAD (bidi into a deaf handler)     ping before  ping@stall  ping after
      control: handler drains it             pong        HUNG        pong
      case:    client cancels it             pong        HUNG        HUNG

    DOWNLOAD (server-stream, paused)      ping before  ping@stall  ping after
      control: consumer resumes              pong        HUNG        pong
      case:    consumer cancels              pong        HUNG        HUNG

After the cancel, NOTHING else works on that connection — polled for 20 s. One
cancelled call is enough: 68 KiB had reached the wire, which is the HTTP/2
default connection window.

## Why

rpc_dart throttles by PAUSING its http2 subscription, which is what closes the
receive window. package:http2 then holds those bytes in
`_stream2pendingMessages` and credits the connection window only when it can
move them into the stream queue. `stream_handler._closeStreamAbnormally` drops
that queue via `removeStreamMessageQueue` with no `dataProcessed`, so the peer
is never given the window back. RFC 9113 6.9.1 requires the connection window to
be accounted for even when a stream is reset.

The trigger is the most ordinary client action there is: `.take(n)`, a timeout,
a user navigating away.

## The options, and what each costs

1. **Report it upstream to package:http2.** The correct fix, and not ours to
   make. Nothing ships in rpc_dart.
2. **Stop pausing; fail the call instead.** Always read, so the pool keeps
   flowing; count per stream; fail a stalled stream with RESOURCE_EXHAUSTED past
   its window. Bounds memory without holding the pool. Cost: a slow handler
   kills its own call instead of being throttled — visible behaviour change.
3. **Do nothing and document it.** Cost: any client that cancels a slow call
   silently loses the connection, and reconnect is the only recovery.

Not an option: a bigger connection window. The pending amount is itself bounded
by the window, so enlarging it enlarges the leak in step — measured, one cancel
kills it at the default.

An ablation removing rpc_dart's throttle makes the connection survive
(14286 / 15291 KiB on the wire, no hang anywhere), which is exactly the
round-118 unbounded upload restored. So "just don't pause" is not available.

## Owner decision

**Option 2, and report upstream as well.** Asked and answered in round 207.

Stop pausing the http2 subscription. Always read, so the connection pool keeps
flowing; count un-consumed request payload per stream; and once a stalled stream
is past its window, FAIL that call with RESOURCE_EXHAUSTED instead of throttling
it. The owner accepted the cost explicitly: a handler that stops consuming kills
its own call rather than being throttled.

Implementation notes for the round that takes this:

- The two pause sites are `_fcOnDelivered` and the `onPause`/`onResume` hop on
  `getMessagesForStream` in `rpc_http2_responder_transport.dart`, plus the same
  hop in `rpc_http2_caller_transport.dart` (the download direction, measured to
  fail the same way).
- `flowControlWindowBytes` is already the knob for "how much un-consumed payload
  one stream may hold" — keep it as the threshold, only change what happens at
  it.
- The witness is P-02: after the change, "ping after a cancelled stalled call"
  must be `pong`, and the ablation numbers (14286 / 15291 KiB on the wire) must
  NOT come back — the stalled call has to be refused, not let through. Both
  matter, so both need a canary.
- `upload_backpressure_test` asserts the throttle: it will need to become an
  assertion that the call is REFUSED past the window rather than throttled. Read
  its situation axis before editing it (methods/canary.md item 9).
