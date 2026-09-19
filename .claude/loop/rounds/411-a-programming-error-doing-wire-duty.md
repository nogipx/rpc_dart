---
round: 411
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-19
bench: none — the evidence is a classification of all 83 raw sites plus two named tests that failed on the first, incomplete fix
commit: yes
---

# Round 411 — a programming error doing wire duty

## Target

The goal's last piece: **83 raw `StateError` / `ArgumentError` sites** across
core, the framework and five transports, named in round 408's `## Not fixed` as
needing a reachability split before any of them moves.

## The classification

Read every message. The split is sharp and most of it should NOT move:

```
programmer error, keep as-is                      peer or runtime condition
  "Endpoint is closed" x4                           validateMetadata's 4 throws
  "Transport is closed" x7                          the http2 converter's walk
  "Sending already completed. Call finishSending()"
  "ServerStream allows only one request"
  "RpcApp.start() can only be called once"
  "RpcContainer: no registration found"
  "Circular dependency detected among modules"
  "viaSocket does not support reconnect"
  "Stream $id not found. Send metadata first."
  "no RpcCallScope on this context"
  "cannot deserialize without a fromJson"
  "Unsupported data type for isolate payload"
  ~60 more of the same shape
```

`ArgumentError` for a caller's mistake is idiomatic Dart and stays. What does
not belong is `ArgumentError` for **untrusted peer input**.

## Hypothesis

That distinction is cosmetic.

## Before

It is not. `RpcSecurityPolicy.validateMetadata` throws bare `ArgumentError` for
a PEER's metadata, and **five decision points read `is ArgumentError` to mean
"the peer is at fault"**:

```
rpc_http2_responder_transport.dart:460  the status: invalidArgument or internal
                               :463  the message forwarded to the peer
                               :518  CHARGE the 256-violation backstop
rpc_http2_caller_transport.dart:1221    CHARGE the 256-violation backstop
responder_endpoint.dart:95 / caller_endpoint.dart:131   rethrow
```

Two of those decide whether to **end a connection**. `ArgumentError` means "a
caller passed a bad argument" — a programming mistake — so an `ArgumentError`
raised anywhere else on that path was being charged to the peer's strike budget
as though it were hostile. A wire-security decision keyed on a Dart
programming-error type, which is the shape the owner named.

## After

`RpcMetadataViolation extends RpcStatusException implements ArgumentError`.

**Implementing `ArgumentError` is the load-bearing half.** All five sites keep
working unchanged, and so does any caller's `catch` — while the type becomes
findable by the one catch that means rpc_dart, and carries INVALID_ARGUMENT
instead of being redacted to INTERNAL.

Then the two backstop sites narrow to `is RpcMetadataViolation`, which is the
whole point: the distinction now exists, so a foreign `ArgumentError` can no
longer close a connection.

## Mechanism

The first fix converted `validateMetadata` alone and **two tests went red**:

```
policy_violations_have_a_backstop_test
  "a grinding peer loses the connection at the default policy"
     the peer sent 1500 policy violations and kept its connection
  "a grinding SERVER loses the client transport too"
     the server answered 1500 calls with metadata the client refuses
```

L-12's lesson, live: the class had a member I had not counted.
`http2HeadersToRpcMetadata` enforces `maxHeaders` **during the walk** rather
than through `validateMetadata`, so its own `ArgumentError` was the one the
backstop actually counted. Converting that site too turns both green.

`_headerValue`'s non-printable-ASCII check deliberately stays an ordinary
`ArgumentError`: its four callers all build OUTBOUND headers from our own
metadata, where a bad value is this side's bug.

## Canary

Two tests added, eleven in the file now:

- the violation is `RpcMetadataViolation` AND `ArgumentError` AND
  `RpcException`, with INVALID_ARGUMENT — asserted as a set, because dropping
  the `ArgumentError` interface would silently disarm two connection-closing
  backstops and nothing else would notice
- a foreign `ArgumentError` is neither — the distinction the narrowing exists to
  make, and worthless if untested

And the two backstop tests above are the ones that caught the incomplete fix;
they now guard the complete one.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**.

## Not fixed

The classification says the remaining ~78 raw sites are correct as they stand,
so the goal is met for everything that was mis-typed. Two items stay open and
both are recorded elsewhere rather than decided here: **B-62**, the http2
envelope whose unwrapper has no call site, and **B-58**, whether a framing
violation should COUNT toward the backstop — which this round touches the
mechanism of without answering, since narrowing WHAT counts is not the same as
deciding WHETHER it should.

## Links

- Round 408 — which named the 83 sites
- Round 410 — the frame statuses this builds on
- L-12 — count the class; the first fix here missed a member and two tests said so
