---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**]
scope: [core]
---

# C-17 — Message-level gzip (`grpc-encoding: gzip`)

The decompression path is bounded. Recorded separately in the documentation: a
decompressing codec MUST honour `maxOutputBytes` — not "should".

## Control

A stream that decompresses within `maxOutputBytes`: it passes, so the refusal
comes from the limit.
