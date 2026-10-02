---
round: 629
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: none — the witness reads the parser's own answer and each shape's status
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 629 — a header with nothing after it

## Target

B-231, from the audit of 2026-10-02: new evidence against B-216 (round 554),
which fixed a request cut inside a message body and did not look at a cut right
after the prefix.

## Hypothesis

`holdsPartialFrame` is `available > 0`. Once the 5-byte prefix is consumed and
no body byte has arrived, nothing is buffered, so it reads false and the request
stream ends as if it were complete.

## Before

```
one whole message, then 5 bytes of a second, then the half-close
  client-stream   status 0, handler saw a clean end
  bidi            status 0, handler saw a clean end
parser fed only a prefix: holdsPartialFrame false
```

## Control

The same tail with 2 body bytes after the prefix: status 3, as round 554 made it.

## Mechanism

The parser consumes a header into `expectedMessageLength` and advances past it.
"Bytes held" and "frame unfinished" diverge at exactly that point, and the
getter asked the first question while its doc described the second.

## After

`holdsPartialFrame` is also true while a header's body is awaited. Both shapes
read status 3 and the handler no longer sees a clean end; the parser witness
holds after a bare prefix and releases on the body. A zero-length body is still a
whole frame (guard).

## Canary

The before table is the same witnesses with the old getter.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` and
`melos run test:web` green (exit 0 each).

## Not fixed

Unary also reads this getter; it now answers the bare-prefix case through the
same truncation path instead of 13. Not separately witnessed.

## Links

Lead `../backlog/B-231-a-bare-prefix-reads-as-a-clean-end.md` — closed.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 629]`.
Tests `packages/core/rpc_dart/test/endpoint/a_request_cut_after_its_prefix_is_truncated_test.dart`,
`packages/core/rpc_dart/test/core/the_parser_says_whether_it_holds_a_partial_frame_test.dart`.
