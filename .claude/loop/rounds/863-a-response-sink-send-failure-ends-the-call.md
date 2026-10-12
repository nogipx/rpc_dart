---
round: 863
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-330 — new
commit: yes
severity: S1 — "data lost, corrupted, duplicated or delivered to the wrong call"
release: changelog
---

# Round 863 — a response-sink send failure ends the call

## Target

Round 862's "Not fixed": `BidirectionalStreamResponder.responseSink`, the
public sink a direct user of the responder drives (a `SinkPump`), was not
measured. The endpoint pumps it does not use were fixed there.

## Hypothesis

A response that cannot be serialized ends a responseSink call at that
point, as it now does on the endpoint's pumps. Fails if the client reads
responses behind it.

## Before

```
P-330:
bad      (x, bad, y, z)   client got [x, y, z], status 13
control  (x, y, z)        client got [x, y, z], ended OK
```

The `bad` response is gone, y and z read as following x, and the status
arrives only when the source ends.

## Mechanism

`SinkPump` sends each item and resumes the source when the send resolves;
a send whose response failed resolves normally, so the pump went on and
the recorded failure was answered at the half-close.

## Fix

`bidirectional/responder.dart`: the send the responseSink pump uses checks
`isAnswered` after each response and, if a response failed, finishes the
call (`finishReceiving`), which answers the failure and completes `done`,
the pump's end-of-life signal.

## After

```
P-330 bad: client got [x], status 13; control unchanged
```

## Canary

Witness `packages/core/rpc_dart/test/streams/a_response_sink_send_failure_ends_the_call_test.dart`,
check off: `Expected: '[x], status 13' Actual: '[x, y, z], status 13'`;
GUARD green. The other responseSink witnesses
(`response_sink_error_reaches_the_client_test`,
`response_sink_stops_at_the_ending_test`,
`response_sink_bounds_its_handler_test`) green with the fix.

## Gate

`melos run analyze` SUCCESS; `format:check` SUCCESS; `license:check`
compliant. `melos run test:unit --no-select`: the first run failed
`tiny_messages_are_weighed_test` (http2, a 20 s timeout; alone 7 s with
and without round 862's change, B-297) and one rpc_dart test beside the
known `audit_frame_reassembly_linear` flake; the second run SUCCESS
(rpc_dart +2231 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +512 ~150).

## Siblings

- bidirectional: fixed here
- server: n/a — `ServerStreamResponder` has no response sink; its pump is round 862's
- unary: n/a — no response sink
- client: n/a — no response sink
- responder: fixed here
- caller: n/a — the caller's request sink is a different failure (a request that cannot be sent, round 641)
- channel: fixed here — P-330 runs on `RpcChannelTransport.memoryPair`
- websocket: fixed here — `RpcChannelTransport`, P-330's path
- isolate: fixed here — `RpcChannelTransport`, P-330's path
- wasm: fixed here — `RpcChannelTransport`, P-330's path
- http2: fixed here — the responder is core's; not measured on http2
- http: fixed here — the responder is core's; not measured on http

## Not fixed

- B-297: the http2 tiny-messages witness times out under the full gate.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-330-a-response-sink-send-that-fails.md`. Round
`862-a-response-that-cannot-be-sent-ends-the-stream.md`. Lead
`../backlog/B-297-the-tiny-messages-witness-times-out-under-the-gate.md`.
