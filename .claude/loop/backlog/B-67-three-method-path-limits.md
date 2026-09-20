---
status: open
round: (not re-measured) — filed from a READ sweep the owner handed in, re-verified against ff930001 before filing; no round took it
commit: ff930001
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: none — READ, not measured
reason: cost — three limits at three layers; the configured one is not the effective one, and deciding which layer owns the grammar is a design call, not an edit
---

# B-67 — three method-path limits, and the configurable one can only lower

`/Service/Method` is length-checked in three places, with three different
numbers, none of which references another:

```
  responder_pipeline.dart:2085   _parseMethodPath       > 512        hardcoded
  security_policy.dart:331-338   isValidMethodPath      > maxMethodPathLength
                                                        default 1024
  metadata.dart:414-420          _isValidMethodPath     > 258
                                 (_maxMethodTokenLength * 2 + 2, = 128*2+2)
```

## The policy knob is real but cannot be raised past 512

The sweep reported `maxMethodPathLength` as having no effect. That is wrong and
worth writing down so nobody re-derives it: the policy check **is** enforced, by
every transport that validates inbound metadata —
`rpc_http2_caller_transport.dart:809,1295`,
`rpc_http2_responder_transport.dart:593,852`,
`rpc_http_caller_transport.dart:294`,
`rpc_http_responder_transport.dart:244,448` — through
`RpcSecurityPolicy.validateMetadata` (`security_policy.dart:373`).

What is true is narrower and still a defect: **the knob is monotone downward
only.** Raise `maxMethodPathLength` above 512 and nothing changes, because
`_parseMethodPath` refuses the path afterwards with a hardcoded 512 and returns
`null`. Lower it and it bites. A setting that silently ignores half its range is
the shape.

## The 258 is a third answer, on the outbound side

`RpcMetadata.forClientRequestWithPath` (`metadata.dart:75`) refuses anything
over `_maxMethodTokenLength * 2 + 2` = 258 before it goes out. So a client built
through that constructor can never send a path that either of the other two
limits would have accepted, and the policy's 1024 default describes a path this
library cannot construct.

## What also differs, beyond the number

The three do not agree on the grammar either:

- `_parseMethodPath` requires exactly three `/`-separated parts and matches each
  token against `^[A-Za-z0-9_.-]+$`.
- `isValidMethodPath` checks only non-empty, leading `/`, and no CR/LF.
- `_isValidMethodPath` splits and applies its own per-token rules.

So the layer that can be configured is the loosest, and the strictest is the one
with no configuration at all.

## What a round has to settle

Which layer owns the grammar. The plausible answer is that `RpcSecurityPolicy`
owns it — it is the only one the embedder can reach, and the transports already
call it — with `_parseMethodPath` reduced to a split that trusts the check
upstream. That needs confirming rather than assuming: `_parseMethodPath` runs on
the responder pipeline, which also serves transports that may not validate.

## Adjacent, same shape, NOT verified here

`RpcContext._sanitizeHeaders` was reported as a second home for the policy's
defaults, hardcoded, so that raising `maxHeaders` leaves the context truncating
at the old value. Same "the knob does not reach the code" shape as above and
filed in B-70 rather than here, because it was not re-checked at `ff930001`.

## Owner decision

—
