---
status: awaiting owner
round: 783
commit: 8471b02c
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart, packages/core/rpc_dart/lib/src/codec/codec.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/cbor_amplification_e2e.dart
reason: owner decision — the fix is a new default bound on decoded items, and any value refuses some legitimate payload
rank: 5
---

# B-275 — the CBOR decoder has no item budget

P-278: one call within the default `maxMessageLengthBytes` (16 MiB), whose
body is 16 million one-byte empty maps, takes the responder from 75 MiB to
1309 MiB and blocks its isolate for about 1 s. The request is decoded before
any interceptor or middleware runs (they receive the decoded `TRequest`), so
an interceptor that refuses every call does not prevent it: authentication
built that way comes after the cost. RPC-27: the message is bounded in bytes,
and what a byte costs once decoded (up to about 72 heap bytes) is chosen by
the peer. `_maxDepth` bounds nesting, not breadth.

Round 785: with message-level gzip, which the responder accepts with
nothing configured on the VM, the same 1296 MiB and one second cost 15 KiB
on the wire, about 86,000:1. One such request per second keeps a
responder's isolate busy.

The shipped rpc_dart-core skill's own auth example
(`RequireTokenInterceptor`, in its contracts-and-endpoints reference) is the shape
the probe's refusing interceptor stands in for. The only checks that run
before the decode are transport-level ones, such as the websocket upgrade's
`allowUpgrade`. The caller decodes responses with the same codec, so a
hostile server reaches a client the same way (not measured).

Reachable by any peer that can open a call to a method whose request codec
is `RpcCodec` (the default, and what generated contracts use; not checked
for the generator here) over any transport. The web was not measured.

Options for the owner:

1. An item budget in `CborCodec.decode`: every decoded item counts one, and
   the decode refuses (`FormatException`, so INVALID_ARGUMENT or
   RESOURCE_EXHAUSTED) past a limit. A static default in the codec, cheapest
   to ship; the value is the decision (at 1 Mi items the worst case is about
   70 MiB and 60 ms; a legitimate list of more than 1 Mi ints is refused).
2. The same, as an `RpcSecurityPolicy` field reaching the codec, so a server
   that receives bulk lists raises it. Wider plumbing: `RpcCodec` has no
   policy today.
3. A budget in heap bytes estimated per item kind, instead of an item count.
   Closer to the real cost, harder to explain.

## Owner decision

—
