---
round: 660
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-227 — new
commit: yes
release: changelog
severity: S2
---

# Round 660 — metadata the policy accepts

## Target

B-242, the one owner decision written and not carried out: option 1, the sender
checks the encoded frame and fails the call locally, both directions. Scope:
every site that bounds a metadata frame by its encoded size -- one, the frame
channel's receiver (`frame_multiplexed_channel.dart`); its only encoder is
`RpcFrameMultiplexedChannel.send`. HTTP/1.1 and http2 do not JSON-frame metadata.

## Hypothesis

A sender check on the encoded frame, at the one place the frame is built, makes
every metadata frame the receiver would refuse fail locally, with no change to
frames the receiver accepts.

## Before

```
default policy, maxMetadataBytes 65536, one other call open on the pair
AT      text=65536 headers=9  sent | server closed, other call [done]
NEAR    text=65436 headers=9  sent | server got it
OVER    text=65537            refused by sender (RpcMetadataViolation)
QUOTES  text=34000 headers=5  sent | server closed, other call [done]
PLAIN   text=34000 headers=5  sent | server got it
RESPONSE AT      text=65536   client saw status 8
RESPONSE CONTROL text=61536   client saw status 5
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/lim_meta_edge.dart` (P-227).

## Mechanism

`validateMetadata` counts header text; the receiver bounds the JSON frame by the
same number and a server closes on it. JSON escapes a quote to two bytes, so the
encoded frame can be twice the text. Nothing on the sending side ever compared
the frame it built with the bound.

## After

```
AT      refused by sender (RpcMetadataViolation) | nothing closed
NEAR    sent | server got it
OVER    refused by sender (RpcMetadataViolation)
QUOTES  refused by sender (RpcMetadataViolation) | nothing closed
PLAIN   sent | server got it
RESPONSE AT      refused by sender (RpcMetadataViolation)
RESPONSE CONTROL client saw status 5
```

`send` compares the encoded payload with the receiver's own `_refuses` ceiling
and throws `RpcMetadataViolation` before writing. No second encode: the frame was
already being built, so the cost is one comparison. At the endpoint the caller
gets `RpcMetadataViolation` and the call already open on the connection answers.

## Canary

Check disabled (`1 < 0 &&`): the endpoint witness failed with
`Expected: '300' Actual: 'RpcStatusException' -- the call already open on the
connection must survive`, and the trailer witness with `Expected: throws
<Instance of 'RpcMetadataViolation'> Actual: <Instance of 'Future<void>'>
emitted <null>`. The GUARD (same text, no escapes, reaches the handler) stayed
green both ways. Restored: green.

`metadata_size_policy_test` went red on the fix: it tested the RECEIVER's bound by
sending through this library's sender, which now refuses the frame. Split: the
receiver arm feeds the encoded frame as raw bytes, and a new arm pins that the
sender refuses the same metadata.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart +2052 ~1); `format:check` clean; `license:check` compliant. The two
changed test files also on `-p node`: +7.

## Not fixed

Nothing in scope. The transport-level response arm now throws to whoever drives
the transport directly; through the endpoints a trailer's values are built by the
library and each is bounded by `maxHeaderValueBytes`, so this direction is
reachable only by a custom responder.

## Links

Lead `../backlog/B-242-honest-metadata-closes-the-server-connection.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 660]`.
Bench `../probes/P-227-metadata-at-the-policy-edge-over-a-channel-pair.md`.
Tests `packages/core/rpc_dart/test/transports/metadata_the_policy_accepts_keeps_the_connection_test.dart`,
`packages/core/rpc_dart/test/transports/metadata_size_policy_test.dart`.
