---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/policy_violations_have_no_backstop.dart
round: 342 — the validating round
commit: 13fc66c3
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-40 — what bounds a peer that only sends frames the policy refuses

Feeds N policy-violating metadata frames at the default policy and reports
whether the connection is still open afterwards, plus the RSS delta. Two arms:
`RpcChannelTransport` driven by a hostile channel stub, and a real HTTP/2
connection against `RpcHttp2Server`.

Change `_violations` for the volume. The violating shape is 200 headers against
`maxHeaders: 128` — each header individually legal, so the refusal is the one
under test and not an incidental limit.

## Measures

Connection still open or not, after N violations at
`closeOnProtocolError: false`. RSS alongside, because the cost is what makes an
open connection a problem rather than a curiosity.

## Control

The shared-layer arm. It carries `_maxPolicyViolations = 256` and is what the
http2 arm is being compared against.

```
2000 violating header blocks, DEFAULT policy

                  before                                      after
shared layer      delivered=301  CLOSED by the transport      unchanged (control)
                  RSS 235->233 MiB
http2 responder   opened=2000    STILL OPEN  RSS 234->261     opened=601  closed
                                                              RSS 233->222 MiB
```

301 and 601 rather than 257: frames are fed in batches between event-loop turns,
so both arms overshoot the counter by the batch in flight. The overshoot is the
same shape on both sides, which is what makes them comparable.

## The trap the control cost

`RpcChannelTransport.pair()` cannot drive this. Since round 340 every transport
validates OUTBOUND metadata, so a well-behaved sender refuses to emit the frame
and the control arm reads `refused after 0 sends` — which looks like the shared
layer having no inbound check at all. **A hostile peer is not a well-behaved
sender**, so the arm needs a channel stub that injects directly.
