---
refines: U-05
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**]
applies: there are caller/responder wrappers around the transport
breaks: "security hole: limits silently switched off with the tests green."
applied: []
status: confirmed (round 094, off-journal)
---

# RPC-04 — Transport capabilities hidden by a wrapper

On websocket and isolate the capabilities were checked as reaching the check
site — round 205, filed separately in `../checked/`.

## Shape

`is IRpcSecurityPolicyAware` / `is IRpcFlowControlled` does not fire, because
the caller or responder does not forward the interface to `_inner`.

## Detector

Grep both type checks; for every transport package, walk the wrapper chain from
construction to the check site.

## Ask

Does the capability survive as far as the check IN THIS package?

## Evidence

200/200 streams against a ceiling of 3; separately, 30/30 handlers against a
ceiling of 3 on HTTP/1.1, whose responder did not declare the interface — five
rounds after the knob shipped.
