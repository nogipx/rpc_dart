---
round: 848
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-317 — new
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 848 — an out-of-range status is UNKNOWN

## Target

Round 846's oracle on the channel caller (websocket, isolate, wasm and the
channel pair share it): fourteen hostile frame sequences, two call shapes,
every outcome printed.

## Hypothesis

Every malformed response ends the way gRPC says. Fails if a consumer gets a
clean end or a status no rule maps it to.

## Before

```
scenario                     unary                   stream
no message, OK               ERROR 13                OK items=[]   (legal: zero items)
two messages, OK             ERROR 13                OK [a, b]
status 99                    ERROR 99                ERROR 99
status x                     ERROR 2                 ERROR 2
status -1                    ERROR -1                ERROR -1
trailer without status       ERROR 13                ERROR 13
end on DATA, no status       ERROR 13                ERROR 13
(the other seven: as gRPC says)
```

A numeric status outside 0..16 reached the consumer as that number, while a
non-numeric one already read as UNKNOWN.

Probe: `packages/core/rpc_dart/.dart_tool/probe/r848_channel_response_oracle.dart`.

## Mechanism

`RpcCallerTrailer.statusOf` returned `int.tryParse(raw) ?? unknown`: the
fallback caught a non-number and passed any number through.

## Fix

A code outside `RpcStatus.ok..unauthenticated` is UNKNOWN too. Every caller
shape and transport reads the status through this one function.

## After

```
status 99   ERROR 2   (both shapes)
status -1   ERROR 2
every other row unchanged
```

## Canary

Witness `packages/core/rpc_dart/test/contracts/an_out_of_range_status_is_unknown_test.dart`.
Range check off: "WITNESS a code outside 0..16 is UNKNOWN" failed with
`Expected: <2> Actual: <99>`; "GUARD every code in 0..16 is kept" green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2214 ~1, http +259, http2 +318, websocket +331); `format:check`
SUCCESS; `license:check` compliant.

## Siblings

—

## Not fixed

Nothing else in P-317 departed from gRPC.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`.
Round `846-a-response-cut-mid-message-is-an-error.md`.
