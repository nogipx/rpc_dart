---
round: 582
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-25
bench: P-202 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
---

# Round 582 — two answers to one question

## Target

`B-146` — the HTTP/1.1 responder emits two `content-type` values. Filed
**medium-low** confidence from a static read, nothing measured.

Lens RPC-25 in its one-value-two-homes form (round 446): the question *who sets
the response content-type?* has two answers on this transport and one on HTTP/2,
which is the sibling and the control.

## Hypothesis

`_completeResponse` seeds its header map with a literal and then merges the
response metadata, which carries core's own `content-type` — and the merge turns
a repeated name into a `List`.

## Before

The lead asks for shelf's test handler and that is the right instrument, but it
is not sufficient: it reads what the code produced, not what a peer gets. Both
views, pre-fix:

```
HANDLER  application/grpc        2  [application/grpc+proto, application/grpc]
HANDLER  application/grpc+json   2  [application/grpc+proto, application/grpc]
WIRE     application/grpc        1  [application/grpc]
WIRE     application/grpc+json   1  [application/grpc]
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b146_two_content_types.dart`.

**The two rows grade the lead differently, and only together are they right.**

- The duplicate is real, in the code's own output: **2 values**.
- It never reached a `dart:io` peer. That adapter keeps the LAST value, so the
  wire carried **1 line** all along — and the lead's "the `+proto` ignores what
  was requested" was true of a value no peer ever saw.
- What a peer DID get is the WIRE row's real finding: `application/grpc` for a
  `+json` call. Legal — the subtype is optional — and the caller is told nothing
  about the encoding it asked for.

## Mechanism

```dart
final headers = <String, Object>{'content-type': 'application/grpc+proto'};
...
for (final header in pending.responseHeaders) {
  final existing = headers[header.name];
  if (existing == null) { headers[header.name] = header.value; }
  else if (existing is String) { headers[header.name] = [existing, header.value]; }
```

`RpcMetadata.forServerInitialResponse()` is the second home: it emits
`content-type: application/grpc` unconditionally, and core's unary responder
sends it on every call. The merge branch that exists so a repeated CUSTOM key
survives as two values (round 545) is what turns the collision into a list.

HTTP/2 answers the same question in one place — it converts the metadata and
seeds nothing — so the sibling has no second home to collide with.

## After

The transport owns the header: it is resolved from the request and any
`content-type` in the response metadata is skipped.

```
HANDLER  application/grpc        1  [application/grpc]
HANDLER  application/grpc+json   1  [application/grpc+json]
WIRE     application/grpc        1  [application/grpc]
WIRE     application/grpc+json   1  [application/grpc+json]
```

The subtype is **rebuilt, not echoed**. The 415 gate above only checks the
`application/grpc` PREFIX, so the rest of that value is peer input arriving in a
response header; anything that is not `application/grpc+<token>` degrades to the
bare form, which is legal for every body. `; charset=...` is stripped first,
because a proxy adds it and it is not part of the subtype.

## Canary

```
A. the merge-loop skip switched off
     WITNESS a response carries exactly ONE content-type
       Expected: ['application/grpc']
         Actual: ['application/grpc', 'application/grpc']
     5 of 8 fail

B. the echo switched off, seed back to the literal
     WITNESS a +json call is not told its answer is protobuf
       Expected: ['application/grpc+json']
         Actual: ['application/grpc+proto']
     5 of 8 fail
```

One arm behaves differently under each and is worth naming: *a parameterised
request keeps its subtype* PASSES canary B, because `Application/GRPC+PROTO`
resolves to the same string the old literal hardcoded. It is the one expectation
that coincides with the defect.

Canary A also surfaced a consequence the lead does not mention: with the skip
off, a `Content-Type: text/plain` in the response metadata reads back as
`['text/plain']` — shelf lowercases the name, so it REPLACED the gRPC
content-type rather than joining it.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +191
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2211 / 2211, REUSE compliant
```

`+191` against `+183` before the round: the 8 new tests, 7 reading the shelf
`Response` and 1 over a socket. Every other package unchanged, which is what says
the header map is this package's own business.

## Not fixed

**Whether any adapter emits both lines is unmeasured.** `shelf_io` is the only
server adapter in this repository's dependency set and it collapses to the last
value. The HANDLER row establishes that there is something for another host to
emit; it does not establish a host that does.

**`_reject` builds its own `Response` and was not read.** It answers 415, 400,
408 and 503 with no `content-type` of its own, which is a different question from
this one (RPC-22 is the lens for that path) and was left alone.

**An application can no longer override the response content-type**, and that is
deliberate. It is also unreachable through the supported API: core builds the
initial response metadata from `forServerInitialResponse(encoding:)` alone, with
no path for a handler to add to it, so only code driving this transport directly
could have set it. Graded `changelog` rather than breaking for that reason — the
one wire-visible change is that a `+json` caller is now told `+json`, and every
gRPC client prefix-matches, this package's own caller included.

## Links

Lead `../backlog/B-146-http1-two-content-types.md` — CLOSED.
Bench `../probes/P-202-which-content-type-a-grpc-over-http1-response-carries.md` — new.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [582]`.
Round `545` — the merge branch this fix excludes one key from, and why that branch exists.
Lesson `../lessons/L-18-the-lead-names-one-side-of-an-adapter.md` — new: the lead
prescribed one instrument, correctly, and one instrument was not enough.
