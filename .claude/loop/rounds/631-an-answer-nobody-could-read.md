---
round: 631
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness reads the type and status every shape's caller receives
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 631 — an answer nobody could read

## Target

B-236, from the audit of 2026-10-02: a response the caller's codec cannot decode
reaches the caller as the codec's own exception.

## Hypothesis

Both caller decode sites, the unary caller's and `CallProcessor`'s, forward the
codec's exception unchanged.

## Before

```
a well-framed response the codec cannot read, then OK
  unary          FormatException: Expected map, got major type: 7
  client-stream  same
  server-stream  same
  bidi           same
```

## Control

The server answers the same failure on a request with 13 (INTERNAL), through
`wireStatusFor`.

## Mechanism

RPC-25's shape: the same decision made in two places, and on the server side it
was made once, in one helper, while the caller side made it twice and neither
time.

## After

`_undecodableResponse` turns a non-`RpcException` decode failure into
`RpcStatusException(INTERNAL, 'Response could not be decoded')` at both sites;
the original stays in the error log where it is caught. All four shapes read 13.
Round 626's witness, which ends a server stream on exactly this failure, still
passes.

## Canary

The before table is the same witness without the helper.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` green (exit 0).

## Not fixed

A caller that caught `FormatException` from a call no longer sees one: a
CHANGELOG line. The codec's message is not forwarded; it is the peer's data.

## Links

Lead `../backlog/B-236-an-undecodable-response-has-no-status.md` — closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 631]`.
Test `packages/core/rpc_dart/test/streams/an_undecodable_response_is_internal_test.dart`.
