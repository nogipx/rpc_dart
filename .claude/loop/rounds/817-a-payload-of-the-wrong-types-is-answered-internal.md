---
round: 817
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: P-302 — new
commit: yes
severity: S3
release: none
---

# Round 817 — a payload of the wrong types is answered INTERNAL

## Target

Network-audit KV-CD-08: type confusion from schemaless decoding. A peer
sends a payload with the right shape and the wrong types, and the handler's
codec casts without a check. No record measured it (`find 'type confusion
wrong type payload TypeError INTERNAL handler cast'` found zero-copy and
error-type rounds, not this).

## Hypothesis

The codec's `TypeError` escapes as an unmapped error: the peer gets the
`TypeError` text, the call shapes disagree, or the server logs an error per
call, a count the peer chooses.

## Before

```
P-302 control (right types): unary / ss / cs / bi ok, 0 server records
```

## Mechanism

n/a (CLEAN). Each responder maps a failed request decode to INTERNAL with a
fixed message and logs nothing at warning or above.

## After

```
  request {n: ...}   all four shapes                              server records
  'one'              13 "Request payload could not be decoded"    0
  missing            13, same                                     0
  [1, 2]             13, same                                     0
  {a: 1}             13, same                                     0
```

INTERNAL matches grpc-java and grpc-go for a request that fails to
deserialize.

## Canary

The bench's first version used `RpcChannelTransport.memoryPair()`, which is
zero-copy: every arm, the control included, failed with a cast of the
object itself, never reaching a codec (L-15). Moved to `pair()` (framed
bytes), where the control answers, so the arms do reach the decoder.

## The verdict questions

1. Only the field types differ.
2. Yes: ok against 13 on the same method.
3. At the caller (status, message) and in the server's log stream.
4. Four shapes, four type mismatches.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. The reverse direction is C-72, already accepted.
9. none.
10. No code changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

No code changed; the probe is outside the tree (`.dart_tool/probe`).

## Siblings

No code changed. Decoding is core's, shared by every transport.

## Not fixed

- Generated codecs (`rpc_dart_generator`) not measured separately; they
  decode through the same `_decodePeerMessage` sites.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-302-payloads-of-the-wrong-types.md`. Negative
`../checked/C-75-a-request-of-the-wrong-types-costs-the-server-nothing.md`.
