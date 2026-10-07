---
round: 694
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none — a new test, `packages/transport/rpc_dart_http2/test/proxy_and_authority_addressing_test.dart`, with a proxy that records CONNECT and a raw http2 server that records `:authority`
commit: yes
release: changelog
---

# Round 694 — the caller addresses its peer correctly

## Target

B-183, four claims about how the http2 caller addresses its peer: Basic auth
encodes the still-percent-encoded `userInfo`; an IPv6 literal is not bracketed
in CONNECT; `:authority` drops a non-default port; the negotiated ALPN is never
checked.

## Hypothesis

The first three by reading `_connectH2ViaProxy` and the request headers
(`authority: _host`).

## Before

```
Basic auth carries the decoded credentials   Expected: 'us@er:p:ss'                 Actual: 'us%40er:p%3Ass'
an IPv6 target is bracketed in CONNECT       Expected: 'CONNECT [::1]:8443 HTTP/1.1'  Actual: 'CONNECT ::1:8443 HTTP/1.1'
:authority keeps a non-default port          Expected: '127.0.0.1:<port>'           Actual: '127.0.0.1'
```

## Mechanism

As hypothesised, all three.

## Fix

- CONNECT and its `Host` use the target in authority form, an IPv6 literal
  bracketed.
- Proxy-Authorization encodes the decoded credentials, user and password
  decoded separately so an encoded `:` in the user name cannot move the split.
- `:authority` is `host:port`, the port dropped only when it is the scheme's
  default; an IPv6 host bracketed.

## After

3 of 3 green; `rpc_dart_http2` suite 293 passed.

## Canary

Before is the canary: the same three tests against the old code, one failure
each.

## The verdict questions

1. Yes: one assertion per claim, each red before.
2. Yes, three of the lead's four claims.
3. Yes: the bytes the peer receives.
4. Not zero-valued.
5. Yes, quoted.
6. Three causes, three checks.
7. Not a policy question.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, the `rpc_dart_http2` suite.

## Not fixed

The ALPN claim: an HTTP/1.1-only TLS peer getting an h2 preface. Witnessing it
needs a TLS server this client trusts, and `secureConnect` takes no security
context while macOS ignores the default context's added trust (round 692).
Left on the lead.

## Links

Lead `../backlog/B-183-http2-proxy-and-addressing-defects.md` -- three of four
claims fixed, ALPN open.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 694]`.
