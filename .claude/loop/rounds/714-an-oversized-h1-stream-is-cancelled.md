---
round: 714
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-17
bench: none — `.dart_tool/probe/audit_h1/oversize.dart`
commit: yes
release: changelog
---

# Round 714 — an oversized h1 stream is cancelled

## Target

B-264: a server stream answered over the limit keeps its handler and its slot.

## Hypothesis

`_answerOversizedResponse` completes the HTTP response and marks the entry
answered; later sends are dropped without telling the handler, and nothing
releases the stream without a deadline.

## Before

```
call 0..3: RESOURCE_EXHAUSTED
after 2s idle: handlers active=4 finished=0, pendingRequests=4
fresh unary: UNAVAILABLE (HTTP 503)
```

## Mechanism

As hypothesised.

## Fix

After answering, the transport emits a cancellation frame for the stream
(`x-client-cancelled`), the signal the pipeline already acts on for a peer
cancel. The pipeline cancels the handler and releases the stream.

`a_server_stream_is_bounded_test` pinned the old behaviour on purpose ("the day
a reset exists this is what changes"); it now asserts the handler stops.

## After

```
after 2s idle: handlers active=0 finished=4, pendingRequests=0
fresh unary: OK
```

## Canary

The library stashed: the new witness sees 2 handlers still running.

## The verdict questions

1. Yes. 2. Yes. 3. Yes. 4. Not zero. 5. Quoted. 6. One cause. 7. Not a trade.
8. One test premise inverted, stated above.

## Gate

`analyze`, `format:check`, the rpc_dart_http suite (231).

## Not fixed

B-265: a client's own cancel still never reaches the server. Filed for the
owner.

## Links

Lead `../backlog/B-264-an-oversized-h1-stream-keeps-its-slot.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 714]`.
