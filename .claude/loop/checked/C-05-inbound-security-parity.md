---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_http2/lib/**]
scope: [http2]
---

# C-05 — Parity of the inbound security controls

The responder validates inbound metadata: 200 headers against `maxHeaders: 4`
→ grpc-status 3, the handler never ran.

The trap that almost made this a false security finding: a grep under `head -12`
returned 12 lines with the responder not among them. **When grep output is
truncated, the absence of a match proves nothing** — grepping the responder file
directly showed the validation call on line 412.

## Control

A request with 4 headers against a ceiling of 4: the handler runs, so the
refusal comes from the limit rather than from the path.
