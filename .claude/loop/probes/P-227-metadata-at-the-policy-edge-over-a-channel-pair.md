---
file: packages/core/rpc_dart/.dart_tool/probe/lim_meta_edge.dart
round: 660
commit: feaf34de
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-227 — metadata at the policy edge over a channel pair

## Why it exists

B-242: the policy counts metadata TEXT, the frame channel's receiver bounds the
JSON-ENCODED frame by the same `maxMetadataBytes`, and a server closes the
connection over it. This drives an honest sender at and around the limit over
`RpcChannelTransport.pair()` with the default policy and asks what the SERVER did.

## The harness

Request arms, each on a fresh pair with one unrelated call already open:
AT (text = limit), NEAR (limit - 100), CONTROL (limit - 4000), OVER (limit + 1),
QUOTES and PLAIN (34000 characters of `"` against `v`). Per arm: did the sender
accept, did the server get it, did either side close, what did the other call see.
Then a server trailer at the limit and under it, and `maxHeaders` at and over.

## The numbers

```
round 658 / 660 before
  AT      text=65536  sent | server closed, other call [done]
  NEAR    text=65436  sent | server got it
  QUOTES  text=34000  sent | server closed, other call [done]
  PLAIN   text=34000  sent | server got it
  RESPONSE AT         sent | client saw status 8
round 660 after
  AT      refused by sender (RpcMetadataViolation) | nothing closed
  QUOTES  refused by sender (RpcMetadataViolation) | nothing closed
  NEAR, PLAIN, CONTROL unchanged
  RESPONSE AT         refused by sender (RpcMetadataViolation)
```

## Measures

Per arm: the sender's outcome, whether the server received the frame, both sides'
`isClosed`, and the other call's events.

## Control

PLAIN against QUOTES: identical text length, only the fill character differs. And
NEAR against AT: 100 bytes of text apart. Both controls are the arm the server
accepts, so a "closed" reading is the frame, not the rig.

## What it establishes, and what it does not

Establishes what an honest sender's metadata does to a server connection at the
edge, per direction. Does NOT cover HTTP/1.1 or http2, whose headers are not
JSON-framed (P-176 sized those gaps).
