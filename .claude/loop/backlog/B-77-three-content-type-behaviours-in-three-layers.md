---
status: decided by owner (round 445)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: cost — split out of B-70 item 29; which behaviour is RIGHT is a protocol question before it is a code question
---

# B-77 — three layers, three behaviours for content-type

```
  rpc_http_responder_transport.dart:231-237
        reads `request.headers[contentType] ?? ''` and rejects anything not
        starting with application/grpc — so ABSENT is REJECTED

  responder_pipeline.dart:859-871
        guards on `contentType != null` — so absent is ACCEPTED and only a
        wrong value is refused

  the http2 responder
        validates it NOWHERE; its only mentions are two comments and the
        response header it writes at :867
```

Same request, three verdicts, decided by which transport it arrived on.

**Round 444 is adjacent and did not settle this.** It fixed the CALLER side —
`ping()` let a user context override the outbound `content-type`, so the header
reaching the responder could be anything. That made the responder's disagreement
reachable from an ordinary context; it did not make the three layers agree.

The gRPC spec is the tiebreaker and should be read before the code: it requires
`content-type: application/grpc` on a request, which argues for the HTTP/1.1
behaviour and against core's. But refusing an absent header is a compatibility
break for any peer that omits it today, so this is a behaviour decision, not a
tidy-up.

Bench: one hand-built peer, three transports, four inputs (absent, correct,
correct-with-suffix, wrong). The matrix IS the finding.

## Owner decision

**One shared validator, plus a policy key. Default keeps today's core
behaviour.**

- The three implementations collapse to ONE function, and http2 — which
  validates nowhere — starts calling it.
- `RpcSecurityPolicy` gains `contentTypeValidation: lenient | strict`.
  `lenient` is core's present rule (absent accepted, wrong value refused) and is
  the default, so nothing breaks in this release. `strict` is the gRPC-spec rule
  (absent refused) and becomes the default in the next major.

The reasoning the owner gave: the defect is three implementations with three
answers, not the strictness. Once there is one validator the strictness is a
one-line default rather than three edits, and the decision becomes reversible
and testable.

DECLINED for now: strict everywhere immediately (breaks any peer that omits the
header — major, and nothing has asked for it yet), and docs-only (leaves the
verdict decided by which transport a request arrived on).

Order of work: read the spec first as the lead says, then build the four-input
matrix over the three transports — the matrix is what tells you whether
`lenient` is describable as one rule at all before it becomes one function.
