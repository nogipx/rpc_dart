---
round: 809
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: none — the matrix row is the bench: I-7's four "channel | ... oversizeRequest" cells, KNOWN FAILING before
commit: yes
severity: S2
release: changelog
---

# Round 809 — an oversized request is answered before the close

## Target

B-281 (S2, the highest-ranked open lead, STALE): an oversized request on a
channel ended UNAVAILABLE instead of RESOURCE_EXHAUSTED. Re-measured first,
since the lead was stale.

## Hypothesis

A server frame channel closes the connection on an oversized frame without
answering the call, and a channel with no close code gives the caller only
"the stream closed", UNAVAILABLE, which it retries.

## Before

```
i7 --run-skipped -n oversize, at 8effc3e6:
  channel | unary         status 14 "The stream closed before the peer sent a status"
  channel | clientStream  status 14 "Stream closed before the server completed the call"
  channel | serverStream  status 14   (same)
  channel | bidi          status 14   (same)
  http, http2, websocket, isolate: 8
```

## Mechanism

`RpcFrameMultiplexedChannel` with `closeOnOversizedFrame` (every server)
skipped the header check a client makes, so the oversized frame reached
`decodeAll`, which threw, and `_failChannel` closed. Only a channel that can
carry a close code (`IRpcChannelOversizeClose`, websocket's 4413) told the
peer why.

## Fix

A server now refuses an oversized declared frame from its header, like a
client, and answers that frame's stream with a RESOURCE_EXHAUSTED trailer
before the close (`_failChannel(..., refusedStreamId:)`); the close itself
is unchanged. Nothing more is decoded once the receive path has failed
(`_failed`). The refusal keeps `decodeAll`'s wording for metadata and data
frames. The skill's limit table says the call is answered, then the
connection closed.

## After

```
i7 at the fix: +80 ~16, the four channel oversizeRequest cells pass (8),
  KNOWN FAILING marks removed
whole matrix: +510 ~152
```

## Canary

The answer switched off (`refusedStreamId != null && !_closed && 1 < 0`):
exactly the four channel cells fail `Expected: <8> Actual: <14>`, the other
members pass. Restored: green.

## The verdict questions

1. The four cells differ from their siblings only in the member.
2. Yes: 14 against 8.
3. The caller's status, at the caller.
4. n/a.
5. Quoted.
6. One mechanism, one canary.
7. From the numbers.
8. B-281 was STALE and re-measured before the fix.
9. none.
10. Siblings below.
A1. The matrix rigs build server and caller policies apart.
A2. Volume.
L1. Yes: the trailer's message names the frame payload ceiling.

## Gate

`melos run analyze`; the unit suites (`melos exec` with test:unit's filters
and `--file-reporter`, 16 packages green, conformance +510 ~152);
`format:check`, `license:check`, `check:skills`, `test:web` (15),
`test:wasm` (53): green.

Two existing tests failed on the first gate run and were read before being
touched:

- websocket `oversized_message_is_refused_test`, "the refusal names the
  limit it hit", expected `frame buffer overflow`: the server now refuses
  from the header before buffering, so the close names the payload ceiling.
  The test's point is that the SIZE limit is named, not
  `maxMessagesPerChunk`; it now expects `frame payload too large`.
- http `a_cancel_reaches_the_handler_test` (round 804) WITNESS failed under
  the parallel gate. Not called a flake: varied the variable (cancel at 0 ms
  instead of 200 ms) and it failed the same way with `handler entered:
  false` -- the request had not reached the handler when cancelled, so there
  was nothing to tell. The test now cancels once the handler has entered.

## Siblings

- channel: fixed here
- http: clean — its own server; the I-7 oversizeRequest cells read 8 before
  and after
- http2: clean — its own server; 8 before and after
- websocket: fixed here as well (the same frame channel); it already read 8
  through its 4413 close code, and now also gets the trailer first
- isolate: clean — 8 before and after
- wasm: not in the matrix; `test:wasm` (53) green against the changed core

## Not fixed

- Other calls on the connection still end UNAVAILABLE when the server
  closes it; that close is the server's defence and unchanged.
- The ~2.1 s close latency behind B-284 was measured once more here: the
  same 2.1 s with the client in another process and with a `RawSocket`
  server, so it is below `Socket` and below rpc_dart (P-295, B-284).

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Lead
`../backlog/B-281-an-oversized-request-on-a-channel-ends-unavailable.md`,
closed. `../backlog/B-284-the-http-cancel-arrives-after-the-i6-bound.md`.
