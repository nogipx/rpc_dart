---
round: 736
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-04
bench: none — a sweep of every wrapper against every capability marker added since round 659; the one gap is filed, not measured
commit: yes
release: none
---

# Round 736 — capability markers through the wrappers

## Target

RPC-04, last applied in round 659. Since then two capabilities found by `is`
checks have been added, `IRpcNoMessageCredit` (round 715) and
`IRpcConnectionBufferTotal`. A wrapper that declares neither erases them in
silence. The same round checks `test:wasm` against rounds 729 and 732's core
changes, since the ordinary gate never runs it.

## Hypothesis

A transport wrapper in the library erases one of the two markers.

## Before

Every decorator holding an inner transport, against the markers:

```
  wrapper                                  inner declares            wrapper declares
  RpcHttp2Server's capability wrapper      IRpcNoMessageCredit       yes (round 715)
  RpcWebSocketResponderTransport           IRpcConnectionBufferTotal yes, forwarded to _inner
  _ReconnectingTransportProxy              IRpcConnectionBufferTotal NO
  RpcWebSocketCallerTransport              (caller side, no marker read there)
```

`test:wasm`: 51 passed against the local core (`rpc_dart 6.3.0 from path ...
(overridden in ./pubspec_overrides.yaml)`).

## Mechanism

`_ReconnectingTransportProxy` declares five capabilities, and
`IRpcConnectionBufferTotal` is not among them. Behind it, a responder
pipeline, as in an `RpcPeerEndpoint` on `RpcClientConnection`, bounds its own
buffers separately from the transport's.

## After

n/a — deferred.

## Canary

n/a.

## The verdict questions

1. n/a — a sweep.
2. n/a.
3. n/a.
4. The wrappers were found by grepping for an inner transport, not by reading.
5. n/a.
6. n/a.
7. DEFERRED, reason risk: the obvious forwarding releases charges against the
   wrong connection after a reconnect (B-267).
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change. `test:wasm` green.

## Not fixed

B-267, as above.

## Links

Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` — `applied: [..., 736]`.
Lead `../backlog/B-267-the-reconnecting-proxy-hides-the-connection-total.md`.
