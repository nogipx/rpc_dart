---
round: 284
commit: e7cd2d9b
paths: [packages/core/rpc_dart_grpc_reflection/lib/**]
scope: [core]
---

# C-33 — the reflection service against hostile requests

`rpc_dart_grpc_reflection` answers UNAUTHENTICATED peers and decodes their
protobuf by hand, and until round 284 it appeared in exactly one round file
(219, and only as a gate census). Seventeen malformed requests through
`processRequestForTest`, the entry point the reflection method uses:

    CONTROL  well-formed list_services            answered 5 bytes

    empty                                         answered      26
    a lone continuation byte                      answered      26
    varint with 12 continuation bytes             answered      38
    varint of all 0xFF (never terminates)         answered      89
    length declares more than is present          answered      50
    length 0x7FFFFFFF                             answered      53
    truncated 64-bit field                        answered      52
    truncated 32-bit field                        answered      51
    wire type 6 (reserved)                        answered      52
    wire type 7 (reserved)                        answered      52
    field 0 (illegal)                             answered      30
    invalid UTF-8 in file_by_filename             answered      30
    invalid UTF-8 in symbol                       answered      30
    a 1 MiB symbol name                           answered 1048629
    symbol full of NUL                            answered     156
    list_services set                             answered       5
    every field at once                           answered      19

**Zero leaked Errors and zero leaked Exceptions.** Every case becomes a gRPC
error response. `_processRequest`'s `catch (_)` is deliberately un-typed and
that is what makes it hold: a bare `on Exception` would let an `Error` through
to the zone, which on a server is a process kill from one request.

`_readVarint` is bounded twice over — `pos < bytes.length` and a
`shift >= 64` throw — so the all-0xFF case terminates rather than spinning.

## The one row worth reading twice

`a 1 MiB symbol name -> answered 1048629 bytes`. The response ECHOES the request,
because the reflection proto requires `original_request` in every reply. So the
peer's request size dictates the response size.

That is 1:1, and RPC-17's rule is that a bomb is defined by AMPLIFICATION rather
than absolute size — the attacker must send every byte it wants back. The
inbound side is bounded by `maxMessageLengthBytes`, so the ceiling is one
maximum message in each direction. Recorded rather than pursued.

## What this does NOT cover

The recursive descriptor parser. `_collectAllTypeNames` in `proto_parser.dart`
recurses on `nested_type` with NO depth limit, and a `StackOverflowError` is an
`Error`. It is not reachable from a peer: its only caller is
`RpcReflectionRegistry.addFileDescriptor`, which takes bytes the DEVELOPER
generated. A malformed or deeply-nested descriptor is therefore a robustness
question about generator output, not an attack surface — which is why this round
stopped at the request decoder.

## Control

A well-formed `list_services` request through the identical call: answered in 5
bytes. So every refusal above is attributable to the content rather than to the
harness.

Bench `../probes/P-33-hostile-reflection-requests.md`.
