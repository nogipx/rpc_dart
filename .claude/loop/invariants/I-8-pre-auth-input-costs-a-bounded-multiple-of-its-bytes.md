---
across: —
test: —
severity: S1
---

# I-8 — pre-auth input costs a bounded multiple of its bytes

## Statement

Decoding before authentication (CBOR, gzip) allocates at most K x the wire
size. K is the owner's decision, pending in B-275; until it is set this
invariant is not enforced.
