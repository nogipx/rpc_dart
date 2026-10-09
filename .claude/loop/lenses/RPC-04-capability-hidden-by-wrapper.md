---
refines: U-05
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**]
applies: there are caller/responder wrappers around the transport
breaks: "security hole: limits silently switched off with the tests green."
applied: [209, 289, 290, 291, 292, 334, 335, 352, 418, 430, 488, 539, 597, 659, 736]
status: confirmed (round 488)
rank: 12
---

# RPC-04 — Transport capabilities hidden by a wrapper

## Shape

`is IRpcSecurityPolicyAware` / `is IRpcFlowControlled` does not fire, because
the caller or responder does not forward the interface to `_inner`. The same
shape reaches a constructor argument, a declared return type, a literal getter,
a fallback, and an injected resource.

## Detector

Grep both type checks; for every transport package, walk the wrapper chain from
construction to the check site. Include wrappers the library builds itself
(`_ReconnectingTransportProxy`), not only wrapper hooks (`transportWrapper`,
http2 only). Also:

- does every branch that constructs a collaborator pass the same arguments
  (run when a class GAINS an optional parameter; read the VALUE where the text
  differs);
- `bool get supportsZeroCopy => false`-style literals, which no `implements`
  grep sees;
- factories whose return type is the bare interface;
- defaults that manufacture a required value (`?? '/Unknown/Unknown'`) and
  `x ?? Default()` on objects the class may later dispose.

## Ask

Does the capability survive as far as the check IN THIS package? And — round 209
— once it arrives, is the object it is routed TO the one that can actually
perform it? Where it is absent, can the transport honour the fallback?

## Evidence

200/200 streams against a ceiling of 3; separately, 30/30 handlers against a
ceiling of 3 on HTTP/1.1, whose responder did not declare the interface — five
rounds after the knob shipped.

- **Round 209** — the wrapper chain exists only where a hook does:
  `transportWrapper` is on `RpcHttp2Server` alone. A decorator declaring
  `IRpcFlowControlled` left inner accounting off: 160900 KiB through a 4 MiB
  window vs 4176 KiB unwrapped. Restoring a capability is not routing it
  somewhere that can honour it; ask which object owns the state. Also corrected
  a false claim that round 205 (actually RPC-08) filed a negative in `../checked/`.
- **Round 334** — `UnaryCaller` in `caller_pipeline.dart` got no `logger` while
  the sibling branch did, so codec unary calls had no caller diagnostics. Two
  branches of one `if` are two call sites, and the shorter one is the default.
- **Round 335** — swept 27 construction sites: one defect, 334's. Two textual
  differences were not defects, so read the VALUE.
  `../checked/C-36-construction-argument-parity.md`.
- **Round 352** — `RpcClientConnection`'s `_ReconnectingTransportProxy`
  declared only `IRpcStreamReset`: through it the policy fell back to
  `16777221` (16 MiB plus the 5-byte prefix, `const RpcSecurityPolicy()`),
  zero-copy refused, flow control `deferred=0`. Measure the EFFECT so the
  number names the policy; a capability can be dropped by a LITERAL; answer
  from the LAST attach (`??=` caches pin a reconnect-gap fallback).
  `RpcWebSocketCallerTransport`'s own comment states the defect (U-14).
  `../probes/P-44-capabilities-through-the-proxy.md`,
  `../rounds/352-the-wrapper-that-declared-nothing.md`.
- **Round 430** — the factory now returns `IRpcReconnectableTransport`. A
  declared type can erase a capability as thoroughly as a decorator
  (`RpcInMemoryTransport.pair`, `RpcIsolateTransport.spawn`,
  `RpcWasmTransport.fromBridge`); the cast walked past round 224's guard into a
  backoff spin, so when a compile-time check replaces a runtime one, re-run the
  runtime one's witness. `../rounds/430-the-guard-the-type-walked-past.md`,
  `../probes/P-09-watermark-survives-a-decorator.md`.
- **Round 488** — `RpcHttpCallerTransport` lacks `IRpcStreamReset` and turned
  the `endStream` fallback into a request to `/Unknown/Unknown` (2 requests
  after fire; before fire it replaced the real call). A fallback is a second
  implementation of the capability and nothing type-checks it; defaults that
  manufacture a required value convert a precondition failure into traffic.
  `../probes/P-127-what-a-cancel-puts-on-the-http1-wire.md`,
  `../rounds/488-a-frame-that-names-no-method-cannot-open-a-call.md`, B-97.
- **Round 539** — the transport closed an injected `http.Client` on `close()`
  (`ClientException: Client is already closed`; now `usable (204)`).
  `x ?? Default()` erases the ownership question, so record it where known; the
  witness USES the client afterwards; a disposal fix needs the opposite arm (an
  owned client is still released). `../probes/P-172-who-owns-the-http-client.md`, B-143.
