---
round: 627
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: none — the witness reads each call's grpc-status and the slot afterwards
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 627 — a call with nothing in it

## Target

B-230, found twice by the audit of 2026-10-02: a server-stream call whose
request stream ends without a single message is never answered.

## Hypothesis

A payload frame that decodes to no message still binds the responder, and once
bound the pipeline's "closed without payload" refusal is skipped; the responder's
own `onDone` only logs.

## Before

```
maxConcurrentHandlers 4, four calls: empty DATA frame + half-close
  statuses after 3 s   [null, null, null, null]
control, no DATA frame [3, 3, 3, 3], next unary served
```

The audit's count probe: 3000 such calls under the default policy, answered 0,
`activeResponders 3000`; with 4 slots the next unary read `status 8`.

## Control

The same calls with no DATA frame at all are refused INVALID_ARGUMENT by the
pipeline, and the slot comes back.

## Mechanism

`_handleDataMessage` treats a zero-length frame as a payload, stores it and
binds a `ServerStreamResponder`. The half-close then ends the processor's request
stream cleanly with no message in it. `_handleEndOfStream` sends INVALID_ARGUMENT
only while `state.responder == null`, and the responder's `onDone` did nothing.

## After

The responder's request `onDone`, with no request handled, answers
INVALID_ARGUMENT "Request stream closed without a request message" and completes
`done`, the way its `onError` already did. `[3, 3, 3, 3]` for the empty frame,
and the next unary is served. B-231's bare prefix on server-stream reaches the
same branch and is answered too; its client-stream and bidi half is still open.

## Canary

The before table is the same witness without the answer.

## Gate

`melos run analyze`, `format:check`, `license:check`, `test:unit` (exit 0) and
`test:web` (exit 0, which also covers round 626's change on dart2js) green.

## Not fixed

Unary answers the same frames with 13 (INTERNAL), the pipeline and now
server-stream with 3 (INVALID_ARGUMENT). B-231 stays open for client-stream and
bidi, which end such a stream as clean.

## Links

Lead `../backlog/B-230-a-server-stream-with-no-request-is-never-answered.md` — closed.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 627]`.
Test `packages/core/rpc_dart/test/endpoint/a_server_stream_with_no_request_is_answered_test.dart`.
