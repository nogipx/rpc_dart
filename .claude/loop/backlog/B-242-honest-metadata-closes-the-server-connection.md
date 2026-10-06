---
status: closed (round 660)
release: changelog
round: 658
commit: 7718fac6
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/lim_meta_edge.dart
reason: "owner decision — B-209's consequence, priced: metadata the sender's own policy accepts can close the whole server connection. B-209 was decided as 'keep the text count and document it' on the premise that the gap is per-header framing; it is also content-dependent escaping, and on a server the frame bound closes the connection"
---

# B-242 — metadata within the policy closes the server connection

## Seen (limits review, round 658)

`validateMetadata` counts header text; the channel multiplexer bounds the
JSON-ENCODED metadata frame by the same `maxMetadataBytes`; a server channel
has `closeOnOversizedFrame: true`. Default policy, limit 65536:

```
AT      text=65536 headers=9   sent | server closed the connection, another open call ended `done`
NEAR    text=65436 headers=9   sent | server got it
OVER    text=65537             refused by the sender (RpcMetadataViolation)
QUOTES  text=34000 headers=5   sent | server closed the connection
PLAIN   text=34000 headers=5   sent | server got it
RESPONSE AT      text=65536    client saw status 8 instead of the server's own 5
RESPONSE CONTROL text=61536    client saw status 5
```

QUOTES against PLAIN differs only in the fill character: a JSON value in a
header, full of `"`, kills the connection at 52 % of the limit.

## Why this is the owner's

B-209 (round 544) chose to keep the text count and document it, after
measuring that the wire's per-header framing differs by transport and that
JSON size depends on content. That record priced the gap as `maxHeaders` times
framing and did not drive what the receiving bound DOES with it: on a server
it is a connection close, which takes every other call along, for metadata the
sender's own check passed.

## Options

1. **The sender checks the encoded frame** before sending it on a channel
   transport, and fails the call locally (RpcMetadataViolation) when it would
   exceed the receive bound. Keeps the text count as the policy's meaning;
   adds one encode-size check where the frame is built. The connection
   survives; the honest sender gets a local error naming the limit.
2. **The receiver bounds metadata frames with headroom** for JSON escaping
   (worst case `\u00XX`, 6x). Loosens a peer-controlled bound; not
   recommended.
3. **Leave it**, documented: a value with many escapable characters can close
   the connection well below the limit.

Recommended: 1.

## Outcome (round 660)

Carried out: `RpcFrameMultiplexedChannel.send` compares the encoded payload with
the receiver's own ceiling and throws `RpcMetadataViolation`. AT and QUOTES now
fail at the sender with nothing closed; NEAR and PLAIN unchanged. P-227,
`../rounds/660-metadata-the-policy-accepts.md`.

## Owner decision

**Option 1: the sender checks the encoded frame.** On a channel transport,
metadata whose encoded frame would exceed the receiver's bound fails the call
locally with `RpcMetadataViolation`; the policy keeps counting text. Taken in
the owner review after round 659.

Both directions: the RESPONSE row (status 8 instead of the server's 5) is the
same gap from the server's side. Release `changelog`, not breaking: everything
the check refuses fails today, only with a closed connection. The per-frame cost
of the check is unmeasured; the round prices it.
