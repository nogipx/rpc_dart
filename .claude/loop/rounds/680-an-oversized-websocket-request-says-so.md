---
round: 680
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-25
bench: none — the parity matrix filed with the lead (`.dart_tool/probe/parity_matrix.dart`, 5.request-over-limit), as a test
commit: yes
release: changelog
severity: S2
---

# Round 680 — an oversized websocket request says so

## Target

B-251, decided by the owner: a dedicated close code for "message too large",
mapped to RESOURCE_EXHAUSTED on the caller. The connection still closes.

## Hypothesis

The server's multiplexer fails the channel for a size the same way as for
malformed bytes: `_failChannel` calls `closeForProtocolError`, so the websocket
closes with 4400, which the caller maps to UNKNOWN.

## Before

A 66560-byte request against a 65536-byte limit, over websocket:

```
Expected: 'status 8'
  Actual: 'status 2'
```

## Mechanism

As hypothesised. Both size sites in `RpcFrameMultiplexedChannel` -- the buffer
overflow check and a size `RpcFrameException.limit` from `decodeAll` -- went to
the one protocol close.

## Fix

- Core: a new opt-in capability `IRpcChannelOversizeClose.closeForOversize`,
  beside `IRpcChannelProtocolClose` (a new interface rather than a parameter,
  so no implementer breaks). `RpcFrameMultiplexedChannel` implements and
  forwards it; `_failChannel(error, oversize: ...)` picks it for the two size
  sites. The metadata-flood failure, also a `.limit`, stays a protocol close: it
  is abuse, not a size. A byte channel without the capability gets the protocol
  close, as before.
- websocket: `RpcWebSocketChannel.closeForOversize` closes with 4413 (echoes HTTP
  413; 1009 cannot be sent by an application, as 1002 cannot);
  `grpcStatusFromWebSocketCloseCode` maps 4413 to RESOURCE_EXHAUSTED, which is not
  retried without pushback since round 669.

## After

`packages/transport/rpc_dart_websocket/test/oversized_request_close_code_test.dart`:
`status 8`; the under-limit GUARD answers.

## Canary

- Mapping removed (4413 back to UNKNOWN): `Actual: 'status 2'`.
- `_failChannel` always protocol-closing: `Actual: 'status 2'`.
- Restored: 2 of 2 green.

Three existing tests pinned 4400 for a size and were moved to the decided
contract: two in `oversized_message_is_refused_test.dart` now expect 4413. The
GUARD "a framing violation still closes 4400" in
`policy_violation_close_code_test.dart` sent a header declaring 0xFFFFFFFF bytes
-- a size, under the new split -- so it now sends metadata that is not JSON, and
still gets 4400.

## The verdict questions

1. Yes: two canaries, one per half.
2. Yes: the caller's status, which is what the lead was about.
3. Yes: the status a caller sees.
4. Not zero-valued.
5. Yes, quoted.
6. Two halves, two canaries.
7. Yes; the owner's option.
8. Three tests pinned the old code; each named above.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check` green.

## Not fixed

The connection still closes, by decision, so every other call on it fails too.
Their status was not re-measured here.

## Links

Lead `../backlog/B-251-one-oversized-websocket-request-fails-the-connection.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 680]`.
