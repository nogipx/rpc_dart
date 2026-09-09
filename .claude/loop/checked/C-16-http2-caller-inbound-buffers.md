---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_http2/lib/**]
scope: [http2]
---

# C-16 — The http2 caller's inbound buffers

The class "a limit that fires too late is not a limit" does not reproduce on
this path.

## Control

A body within the limit: it is read in full, so the refusal comes from the bound
itself.
