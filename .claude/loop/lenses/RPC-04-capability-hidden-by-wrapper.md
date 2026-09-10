---
refines: U-05
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**]
applies: there are caller/responder wrappers around the transport
breaks: "security hole: limits silently switched off with the tests green."
applied: [209, 289, 290]
status: confirmed (round 209)
---

# RPC-04 — Transport capabilities hidden by a wrapper

**The wrapper chain only exists where a wrapper HOOK does.** Round 209 swept it:
`transportWrapper` is on `RpcHttp2Server` alone — the websocket and http servers
have no such parameter, isolate hands back a `RpcChannelTransport` directly, and
the websocket caller/responder forward both interfaces. So http2 is the entire
surface, which is a much smaller sweep than the paths list suggests.

The line that used to sit here — "on websocket and isolate the capabilities were
checked as reaching the check site, round 205, filed separately in
`../checked/`" — was wrong on its own terms: round 205 was RPC-08 (policy fields
biting on the channel transports) and no such negative was ever filed. Corrected
in 209.

## Shape

`is IRpcSecurityPolicyAware` / `is IRpcFlowControlled` does not fire, because
the caller or responder does not forward the interface to `_inner`.

## Detector

Grep both type checks; for every transport package, walk the wrapper chain from
construction to the check site.

## Ask

Does the capability survive as far as the check IN THIS package? And — round 209
— once it arrives, is the object it is routed TO the one that can actually
perform it?

## Evidence

200/200 streams against a ceiling of 3; separately, 30/30 handlers against a
ceiling of 3 on HTTP/1.1, whose responder did not declare the interface — five
rounds after the knob shipped.

Round 209, the second question. `_CapabilityPreservingTransport` restores a
dropped capability, and then routes it to whichever object declares it,
preferring the wrapper. But a wrapper can only ever report CONSUMPTION; the
charge lives in the transport that sees the bytes. A decorator declaring
`IRpcFlowControlled` and swallowing it therefore left the inner accounting
switched off — a deaf client-stream handler took 160900 KiB against a 4 MiB
window, against 4176 KiB with no wrapper. Fixed by always deferring on the inner
transport too; the discharge is deliberately not doubled the same way, or a
FORWARDING decorator would discharge twice and lose the bound the other way.

> **Restoring a capability is not the same as routing it somewhere that can
> honour it.** Ask which object owns the state the capability manipulates.
