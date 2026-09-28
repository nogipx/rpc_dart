---
round: 468
commit: 9e9fcd67
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
scope: [rpc_dart, rpc_dart_http2]
---

# C-54 — the three parity rules never meet

Bench: P-117,
`packages/transport/rpc_dart_http2/.dart_tool/probe/where_the_parity_rules_meet.dart`.

> **Scope**: the http2 caller's `resumeStreamIdsAfter` driven directly at every
> parity, and `RpcClientConnection` driven across three transport swaps. It does
> not cover the websocket transport, which uses `RpcStreamIdManager` and is the
> first home rather than a fourth.

## The claim that was checked

B-89: the stream-id parity rule has three homes — core's `RpcStreamIdManager`
parameterised by side, the http2 caller's hard-coded client-odd, and the http2
responder's bare `2`. The lead files it rather than fixing it and names two
questions that decide whether anything bites.

## Question 1 — can the responder's counter be handed a watermark? NO

`RpcHttp2ResponderTransport implements IRpcTransport, IRpcSecurityPolicyAware,
IRpcFlowControlled` — **not `IRpcStreamIdSequence`**. It has neither
`resumeStreamIdsAfter` nor `lastIssuedStreamId`; `_nextStreamId = 2` is written
once and only ever incremented by 2.

So there is no entry point, nothing can hand it a wrong-parity value, and by the
lead's own criterion there is nothing to align. Its `2` is not a third
implementation of a rule — it is an initialiser with no rule attached.

## Question 2 — can a wrong-parity watermark reach the http2 caller? Not from here

Driven at its own boundary, every parity:

```
watermark=  1 (odd )  -> 3, 5     both ODD
watermark=  2 (even)  -> 5, 7     both ODD
watermark=  7 (odd )  -> 9, 11    both ODD
watermark=  8 (even)  -> 11, 13   both ODD
watermark=100 (even)  -> 103, 105 both ODD
watermark=101 (odd )  -> 103, 105 both ODD
```

Correct at every input, and never rewound.

Through the one path where two of the rules meet — `RpcClientConnection`'s
`_idWatermark`, three swaps, three ids minted between each:

```
ids = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
even ids = NONE   strictly increasing = true
```

## Control

It measured more than it was aimed at.

`final aligned = streamId;` in place of the round-up:

```
watermark=  2 (even)  -> 4, 6     PARITY BROKEN
watermark=  8 (even)  -> 10, 12   PARITY BROKEN
watermark=100 (even)  -> 102, 104 PARITY BROKEN
```

So the bench sees a break, and a clean row is about the code.

**The proxy arm stayed CLEAN under the same ablation** — still `[1, 3, 5, …]`,
no even ids. That is a stronger result than the unablated run: the alignment is
not merely correct on that path, it is never exercised on it, because
`lastIssuedStreamId` is `_nextStreamId - 2` and odd by construction.

## What this leaves

The alignment in the http2 caller is reachable only by a third party calling
`resumeStreamIdsAfter` directly with an even value. That is the public transport
surface, so it is not dead code — but nothing inside this library reaches it, and
the two rules therefore never disagree in practice.

## The `## Ask`, answered

Not the manager. `RpcStreamIdManager` also computes a max-assignable bound and
tracks release, and http2 delegates real id assignment to `package:http2`'s
`makeRequest` — its `_nextStreamId` is rpc_dart's own handle, not the wire id.
Adopting the manager would put a bound and a release ledger on a transport that
needs neither, for a rule that is four tokens long and has no reachable
disagreement. RPC-25's "What a no-drift candidate earns: nothing".
