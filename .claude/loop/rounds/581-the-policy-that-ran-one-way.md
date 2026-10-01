---
round: 581
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-08
bench: P-201 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
---

# Round 581 — the policy that ran one way

## Target

`B-145`, the HTTP/1.1 mirror of what round 567 fixed on http2: there the caller validated a peer's
trailers too strictly and destroyed the status; here the claim is that it never validates at all. The lead
is graded **medium-low** confidence, which `C-61` says predicts nothing either way.

Scope decided before the fix: the HTTP/1.1 site is the target, and the shared RULE gets one home instead
of a third copy — round 567 left it in two places.

Lens RPC-08: one rule, three transports, applied on two of them.

## Hypothesis

This transport is not an `RpcChannelTransport`, so core's `_validateInbound` never runs on it and the
response headers reach the application unchecked.

## Before

```
WITNESS  1000 extra response headers
    headers delivered  1007
    grpc-status        9
    errors             none

CONTROL  2 extra response headers
    headers delivered  9
    grpc-status        9
```

**1007 delivered against a `maxHeaders` of 128.** Probe:
`packages/transport/rpc_dart_http/.dart_tool/probe/b145_response_headers_unchecked.dart`.

## Mechanism

`RpcMetadata(initialHeaders)` and `RpcMetadata(trailerHeaders)` are built straight from the response and
emitted. Nothing on this path calls `validateMetadata`, and the one place that would —
`RpcChannelTransport._validateInbound` — belongs to a class this transport is not.

## After

```
WITNESS  headers delivered 2, grpc-status 9
CONTROL  headers delivered 9, grpc-status 9    unchanged
```

**One home for the rule**: `RpcSecurityPolicy.statusOnly` now owns "what a caller keeps from metadata that
breaks the policy", carrying round 567's measurement. Core's `_statusOnly` and the http2 caller's
`_peerStatusOnly` both delegate to it — the http2 one still reads RAW headers, because its converter
throws mid-walk, but the DECISION is no longer its own. Three copies would have been two too many for a
decision about what a caller is told.

## The first fix reproduced the defect it was guarding against

Reducing an offending frame to its status is right for a TRAILER and wrong for an INITIAL frame, because
this transport routes `grpc-status` into the trailers — so an initial frame has no status to keep. The
first version answered it with this side's INVALID_ARGUMENT, which reached the caller BEFORE the server's
real 9 and won:

```
WITNESS, first attempt   headers delivered 4, grpc-status 3
```

An offending initial frame is now reduced to NOTHING and the trailers answer the call. That is what the
`isTrailer` argument is for, and canary B is that reading.

## Canary

```
A. the check switched off
     a response with more headers than the policy allows is reduced
       Expected: a value less than <128>
         Actual: <1007>

B. the `isTrailer` distinction removed
       Expected: '9'
         Actual: '3'
     the SERVER's status must be the first one the caller sees; answering the
     offending initial frame with our own INVALID_ARGUMENT puts a manufactured
     status ahead of the real one
```

Each fires on its own half.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +183
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2205 / 2205, REUSE compliant
```

The core and http2 suites are what cover the extraction: `rpc_dart +1876 ~1`, `rpc_dart_http2 +275`, both
unchanged.

## Not fixed

**The REQUEST direction on this transport was already checked** and is not part of this: `sendMetadata`
calls `validateMetadata` at `:323`. What was one-directional is the response.

**The responder half of this package is untouched.** `rpc_http_responder_transport.dart` validates inbound
request metadata (two call sites), so it is not an instance; whether its own RESPONSE path has the mirror
gap was not read.

**No arm drives a character violation.** The witness uses a header COUNT, because `HttpServer` will not
emit a CR inside a value — the lead's "a CR in a value (raw server)" needs a hand-rolled socket server, and
`isValidHeaderValue` is the same check on both paths, so what it would add is coverage of the policy rather
than of this fix.

**The 1000-header response is a server a user chose to talk to**, not an attacker on the path. The lead's
severity line — "the security policy is one-directional on this transport" — is about the asymmetry, and
that is what the round establishes; it does not establish a reachable attack.

## Links

Lead `../backlog/B-145-http1-response-headers-are-not-validated.md` — CLOSED.
Round `567-our-limit-on-their-answer.md` — the same rule's other two sites, and the measurement
`statusOnly` now carries.
Bench `../probes/P-201-what-the-http1-caller-lets-through.md` — new.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [581]`.
Lesson: none, and the candidate is worth declining out loud: "a reduction that is right for one frame type
is wrong for another". That is `canary.md` item 6 — if the fix has a flag or a mode that can be set
wrongly, canary THAT — and canary B is exactly it.
