---
round: 817
commit: 0b53e9ea
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart]
scope: a request that is valid CBOR of the right shape with wrong field types (string, list, map for an int; a missing field), all four call shapes, RpcCodec over the framed channel pair; not zero-copy, not generated codecs measured separately
---

# C-75 — a request of the wrong types costs the server nothing

Network-audit KV-CD-08. A peer that sends the right shape with the wrong
types gets INTERNAL "Request payload could not be decoded" on every call
shape, which is what grpc-java and grpc-go answer for a request that fails
to deserialize. The `TypeError` text never reaches the peer, and the server
writes no warning or error record, so the peer cannot choose the log volume.
Bench `../probes/P-302-payloads-of-the-wrong-types.md`.

The reverse (a server answering with the wrong types) costs the caller two
ERROR records per call; that is C-72, accepted there.

## Control

The right types: all four shapes answer, no record.
