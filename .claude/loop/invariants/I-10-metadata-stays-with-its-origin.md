---
across: transport
test: —
severity: S1
---

# I-10 — metadata stays with its origin

## Statement

Call metadata is never sent to an origin other than the one dialed: redirects,
proxies. The http caller's 303 handling waits on the owner in B-276; until
that is answered this invariant is not enforced.
