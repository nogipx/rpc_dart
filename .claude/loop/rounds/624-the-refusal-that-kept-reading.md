---
round: 624
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: P-216 — reused
budget: probes 3/5, canaries 2/5
commit: yes
release: changelog
---

# Round 624 — the refusal that kept reading

## Target

The independent audit of 2026-10-02 (four auditors over `76b07afd~1..HEAD`)
reported that round 611's frame guard crashes a default server when the refused
frame arrives in the same TCP read as the upgrade request.

## Hypothesis

`_BoundedSocket` closes its transformer sink on refusal but keeps the source
subscription. Bytes read together with the HTTP request are replayed by
dart:http's detached subscription in a microtask that `socket.destroy()` does not
stop, and the next chunk hits a closed sink.

## Before

```
one write: upgrade request + header declaring 2^40 + 256 KiB    exit 255
  Unhandled exception: Bad state: Stream is already closed
  #0 _SinkTransformerStreamSubscription._addError
  #2 _HttpDetachedStreamSubscription._maybeScheduleData
```

Default server (`rpcWebSocketConnections(http)`, no policy, compression off), one
unauthenticated write, whole process down. The witness fails the same way, and
the socket is never closed.

## Control

Same frame sent 300 ms after the 101: the server stays up. A frame under the
limit in the same write: served.

## Mechanism

`StreamTransformer.fromHandlers` nulls its event sink on `close()`, so the next
`add` throws before the handler runs; a flag inside the handler cannot help. The
throw lands in the root zone on the accept path.

## After

The guard is a `StreamController` over an explicit `socket.listen`. On refusal it
cancels that subscription, destroys the socket and closes the controller.
Pause, resume and cancel are forwarded. The probe prints `server process still
alive (pipelined)`; the witness passes.

## Canary

1. Remove the cancel: the witness fails, the socket is never closed in 5 s.
2. Keep the cancel, drop an `out.isClosed` check: the witness still passes, so
   the cancel alone is load-bearing and the check was not kept.

## Gate

`melos run analyze`, `format:check`, `license:check` green. `melos run test:unit`
went red with its output truncated before the failure, as in round 615; every
package run separately is green (rpc_dart +1932, websocket +272, http +215,
http2 +275, isolate +93, the other ten all passed). Recorded unexplained.

## Not fixed

The same audit's other websocket finding: `rpcWebSocketConnections` takes its own
`policy:` defaulting to 16 MiB, so a server configured above that refuses larger
messages unless the policy is passed twice, and the refusal reads as a retryable
UNAVAILABLE. Filed as B-227.

## Links

Bench `../probes/P-216-an-unfinished-websocket-message.md` — extended.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` — `applied: [..., 624]`.
Lead `../backlog/B-227-the-connections-policy-is-a-second-copy.md` — new.
Test `packages/transport/rpc_dart_websocket/test/an_unfinished_message_is_bounded_test.dart`.
