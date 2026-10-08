---
round: 711
class: process
cost: four rounds (709-711, 715) to fix one shape in four places — the depth bound against message credit, the byte buffer against the window, the first grant against the seed, the pre-bind credit against the pipeline — plus the round-708 device chase that blamed the bridges for it
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
commit: cc192d7d
status: active
---

# L-20 — a receiver limit the sender cannot see fails honest peers

## The rule

Every receiver-side bound on un-consumed data must be one the sender is paced
by, in the same unit, or the bound fails peers that are doing nothing wrong.
For each such limit, ask: what tells the sender about it? If the answer is
"nothing", a fast sender and a slow consumer reach it in ordinary use.

## What it cost

`maxBufferedMessagesPerStream` (messages) sat behind a window in bytes; the
stream buffer (`maxMessageLengthBytes + 5`) sat behind a 4 MiB window; the
seeded send window was added to the receiver's advertisement instead of being
replaced by it; a request credited on arrival was credited again on
consumption. Each failed a compliant stream with RESOURCE_EXHAUSTED. The first
showed on devices for three rounds, where it was read as a bridge being slow,
because a bridge batching frames is just a socket read that carries many.

## How to apply

When adding or reviewing a bound: write down the sender-side mechanism that
keeps an honest peer under it, and test with a consumer slower than the
producer and with all of one chunk arriving before the consumer runs. The
transport matrix's group 7 (`.dart_tool/probe/parity_matrix.dart`) is that
test across transports.
