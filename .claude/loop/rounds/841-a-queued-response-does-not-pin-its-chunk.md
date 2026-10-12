---
round: 841
verdict: FIXED
packages: [rpc_dart]
lens: RPC-27
bench: P-312 — new
commit: yes
severity: S1 — "a security or limit bypass"
release: changelog
---

# Round 841 — a queued response does not pin its chunk

## Target

Round 636's `## Not fixed`: "The caller side's per-stream controllers queue
views the same way; the peer there is the server the caller chose, so it was
left." That is a round's call, not the owner's, and network-audit audits
both directions (a hostile server against the caller, as rounds 756 and 836
did). Round 840 had just paid for the same shape ("a kept view weighs its
buffer"), so this is its sweep (L-12).

Skipped on the way, each read off current code, none measured, so none is a
negative: the `IRpcCallCheck` refusal leaves through the same `finally` as an
interceptor refusal (round 733); the websocket `Origin` check is an exact
match after trim and lower-case and refuses two headers; a pong flood costs
parsing only (C-03's rule); `RpcRateLimiter.keyExtractor` reads context
values, which only `withValue` sets.

Class counted, the places a caller's response waits for its consumer:
`RpcChannelTransport`'s per-stream controllers (channel, websocket, isolate,
wasm) and `RpcStreamRouter` (http2). The http caller collects the whole body
first (round 840). Two sites, both fixed; the responder's three, from round
636, now share the helper.

## Hypothesis

A response queued behind a paused consumer holds memory near its own size.
Fails if the queued view keeps the whole inbound chunk alive.

## Before

```
arm          RSS after   peak    delivered
split  x300  +8 MiB      +100    300
packed x300  +302 MiB    +302    300
```

300 one-byte responses held 302 MiB; every buffer limit charged ~16 bytes
each.

Probe: `packages/core/rpc_dart/.dart_tool/probe/r841_caller_pinned_chunks.dart`.

## Mechanism

The frame channel decodes in place, so a response's payload is a view into
its chunk, and the caller's per-stream controller kept the view while the
consumer was paused. Frames on an id nobody opened are dropped silently, so
the filler costs the server nothing.

## After

```
arm          RSS after   peak    delivered
packed x300  +8 MiB      +25     300
split  x300  +18 MiB     +87     300
```

`ownedPayload` (moved from `responder_streams.dart` to
`src/core/owned_payload.dart`, internal) copies a payload that is a view into
a larger buffer, now also where a response waits: in the transport's
per-stream controller and in `RpcStreamRouter`, when the controller has no
listener or is paused. A response to a reading consumer keeps its view.

## Canary

Witness `packages/core/rpc_dart/test/transports/a_queued_response_does_not_pin_its_chunk_test.dart`.

- Transport copy off: "channel transport WITNESS a response queued behind a
  paused consumer owns its bytes" failed with `16 bytes held 1048610`; the
  rest green.
- Router copy off: "RpcStreamRouter WITNESS a message queued behind a paused
  consumer owns its bytes" failed with `Expected: true Actual: <false>`; the
  rest green.
- Copy always (the hot-path neighbour): both GUARDs failed (`Expected: false
  Actual: <true>`, `Expected: true Actual: <false>`); both witnesses green.

All four pass under dart2js (`-p node`).

## Gate

`melos run analyze` SUCCESS (after removing an unnecessary import in the
new test); `melos run test:unit --no-select` SUCCESS (rpc_dart +2206 ~1,
websocket +331, http2 +316, isolate +102, conformance +512 ~150);
`format:check` SUCCESS; `license:check` compliant; `check:skills` clean.

## Siblings

- channel: fixed here (`channel_transport_inbound.dart`)
- websocket: fixed here — its caller is an `RpcChannelTransport`, the transport witness's code path
- isolate: fixed here — `RpcChannelTransport`, as websocket
- wasm: fixed here — `RpcChannelTransport`, as websocket
- http2: fixed here — its caller delivers through `RpcStreamRouter`, the router witness's code path
- http: n/a — the caller reads the whole body into one buffer before splitting it, and round 840 bounds that buffer
- caller: fixed here
- responder: fixed here in round 636; this round only moves its helper, and `a_queued_request_does_not_pin_its_chunk_test` stays green

## Not fixed

- The websocket and http2 end-to-end paths were not driven with a hostile
  server; their witnesses are the shared transport and router code they
  deliver through.

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`. Bench
`../probes/P-312-a-queued-response-pins-its-chunk.md`. Rounds
`636-the-byte-that-held-a-megabyte.md` (the responder side),
`840-a-body-chunk-cannot-pin-its-read-buffer.md` (the same rule on http).
