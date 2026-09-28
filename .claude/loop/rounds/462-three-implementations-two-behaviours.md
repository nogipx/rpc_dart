---
round: 462
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: P-111 — new
commit: yes
---

# Round 462 — three implementations, two behaviours, four sites

## Target

B-77, the last owner-decided lead that is not blocked on hardware or on an
outward-facing action. The owner asked for one shared validator plus a policy
key; the lead itself says to build the matrix first, because *"the matrix is what
tells you whether `lenient` is describable as one rule at all before it becomes
one function"*.

**Scope, counted before any edit.** The lead names three sites. There are FOUR
that judge a content-type, and the fourth is on the other side of the call:

```
rpc_http_responder_transport.dart:231   `?? ''` + startsWith    absent REFUSED
responder_pipeline.dart:866             `!= null` guard          absent accepted
rpc_http2_responder_transport            no copy at all
rpc_http2_caller_transport.dart:1329    `!= null` guard, on the RESPONSE
```

`grep -rn contentTypeGrpc packages/` returns exactly these, plus three PRODUCER
sites in `metadata.dart` that are not in the class. All four are in scope, and so
is the fifth thing the count exposes: the HTTP/1.1 caller has no response check,
where its HTTP/2 sibling does.

## Hypothesis

The lead's premise is a count of implementations read as a count of behaviours.
Measure the behaviours.

## Before

The matrix, P-111, responder side:

```
                          HTTP/1.1      HTTP/2        core (channel)
(absent)                  415 REFUSED   OK            OK
application/grpc          200           OK            OK
application/grpc+proto    200           OK            OK
text/plain                415 REFUSED   status=3      status=3
```

**Two behaviours, not three, and the lead is wrong about http2 in a way that
matters.** "Validates it NOWHERE" is true of its file and false of its
behaviour: its metadata goes up to core's pipeline, so it inherits core's copy
and refuses `text/plain` with `status=3`. The divergence is ONE cell — absent, on
HTTP/1.1.

Caller side, which the lead's table does not list:

```
HTTP/1.1 caller   status=13 "Invalid compression flag in gRPC message: 60"
HTTP/2 caller     status=13 "Invalid content-type for gRPC: \"text/html\""
```

60 is `<`. The HTTP/2 check exists because it met a proxy's HTML error page; its
sibling handed the page to the parser and described the first byte of `<html>` as
a compression flag.

## Mechanism

One rule, `RpcSecurityPolicy.isAcceptableContentType(value, mode)`, static so the
HTTP/1.1 responder — which reads a NULLABLE policy field and applies this check
whether or not a policy was given — can reach it without one.

`RpcSecurityPolicy.contentTypeValidation: lenient | strict` as the owner
specified, default `lenient`, through the constructor, `toMap`, `fromMap` and the
private-default block. **[mode] is passed by the caller, not read from `this`**,
so a site with a reason of its own states it where the reason is written:

```
core responder_pipeline   policy.contentTypeValidation      the knob's subject
rpc_http_responder        strict, hardcoded                 see below
rpc_http2_caller          lenient                           trailers carry none
rpc_http_caller           lenient                           NEW — was missing
```

## The owner's default stands, and HTTP/1.1 is exempt from it — on purpose

The decision reads *"the three implementations collapse to ONE function"* with
`lenient` as the default. Taken literally on a measured surface of two, that makes
the HTTP/1.1 responder LOOSER: absent would go from 415 to accepted.

That is not a compatibility change, it is a security one, and the argument is
already written in that file thirty lines above the check. The POST-only rule
rests on it: *"a POST carrying `content-type: application/grpc` cannot leave the
origin unprompted"*. But NO content-type can — a cross-origin `fetch` with a
typeless body sends none and needs no preflight — so accepting absent puts every
unary method back within reach of an attacker's page. The site therefore passes
`strict` itself and does not read the knob, and `contentTypeValidation`'s own
doc comment says so.

**What the owner declined is untouched**: strict everywhere immediately. Core and
HTTP/2 keep `lenient`, so no peer that works today is turned away, and the spec's
rule is one word away for anybody who wants it.

## After

The responder matrix is unchanged, the caller row is fixed, and the knob moves
exactly one cell:

```
HTTP/1.1 caller, text/html    status=13 "Invalid content-type for gRPC: \"text/html\""

core / HTTP/2, strict
(absent)                      status=3 "Missing content-type for gRPC"
application/grpc              OK
application/grpc+proto        OK
text/plain                    status=3 "Invalid content-type for gRPC: \"text/plain\""
```

The refusal now names the value. `'Invalid content-type for gRPC'` with nothing
after it read the same to a peer that sent the wrong thing and a peer that sent
nothing — and under `strict` those are different rows.

## Canary

Two halves, two canaries.

**The mode, ignored** (`if (value == null) return true`) — three tests red in two
packages off one line:

    absent is the only input the mode decides
      Expected: false
        Actual: <true>
    strict refuses a request that carries no content-type
      Expected: 'status=3 Missing content-type for gRPC'
        Actual: 'ok'
    GUARD: a request with NO content-type is refused, whatever the policy
      Expected: <415>
        Actual: <200>

The third is the security-relevant one, and it is in another package: one switch
in core reaches both the knob and the HTTP/1.1 exemption, which is the evidence
that they are one rule with a parameter rather than two copies again.

**The HTTP/1.1 caller's check, removed** — the exact string the probe measured
before the fix:

    a 200 answering HTML names the content-type, not a framing byte
      Expected: 'status=13 Invalid content-type for gRPC: "text/html"'
        Actual: 'status=13 Invalid compression flag in gRPC message: 60'

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS (after `format` — two
packages needed it), `license:check` SUCCESS, `test:unit --no-select` SUCCESS
across the workspace: `rpc_dart` 1681, `rpc_dart_http2` 247,
`rpc_dart_websocket` 183.

Tests: `test/core/content_type_is_one_rule_test.dart` (the rule under both modes,
the policy witness over a channel pair, and a control proving a present value's
verdict is mode-independent), `rpc_dart_http/test/a_200_that_is_not_grpc_test.dart`
(the caller witness plus two guards — absent still accepted, because a
Trailers-Only answer carries none), and an absent arm added to
`content_type_case_test.dart` to pin the HTTP/1.1 exemption, which nothing pinned
before.

`ContentTypeRewritingTransport` joins `test/utils/transport_wrappers.dart`.

## Not fixed

**The VALUE axis is untouched, deliberately.** All four copies used
`startsWith('application/grpc')`, so `application/grpc-web` passes and is then
parsed as gRPC. Narrowing to the spec's `application/grpc[+subtype]` grammar is a
behaviour decision on a second axis, nothing measured its reachability, and
unifying the copies did not require it. Recorded in the validator's doc comment.

**`policy_defaults_agree_test.dart`'s field list is hand-maintained.** It is the
fourth place a new policy field has to be added, after the constructor, `toMap`
and `fromMap` — and the one that fails to notice rather than failing loudly, since
a field absent from `_fields` is simply not compared. `contentTypeValidation` is
in all four.

## Also, an off-schema key in five of my own records

`C-48` through `C-52` each carried a `probe:` line, which `checked-item.md` does
not declare — so `lint` named it five times on every run for thirteen rounds and
nobody acted. The fact belongs in the prose, and is now a `Bench:` line in the
body of each. **A warning that repeats and is never acted on stops being read**,
which is the only reason to fix it inside another round rather than at curate time.

## Links

- RPC-25 — three implementations, and the count of behaviours is what the lens
  actually wants; also the fourth site, which no comparison of the three could
  find
- L-12 — the axis of a count can be implementations-vs-behaviours
- Round 459 — the same shape from the other side: a duty absent from a sibling's
  file, present in the layer it shares
- Round 444 — made this reachable by reserving `content-type` against a caller
  context, which is also why the core arm has to rewrite below the endpoint
- P-111 — the matrix
- B-77 — closed
