---
round: 867
commit: b18da1bb
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart]
scope: client-stream and bidi over a channel pair, the handler throwing or answering after two requests of an endless upload
---

# C-95 — a failed handler stops the client's upload

When the server's handler ends a call mid-upload, by throwing (ABORTED) or
by answering, the caller ends the call and stops pulling its request
producer: one request in flight, then none, on client-stream and bidi.
Bench `../probes/P-333-does-a-failed-handler-stop-the-upload.md`.

## Control

The `reads` arm (the upload never ends): 75 pulls in the same second.
