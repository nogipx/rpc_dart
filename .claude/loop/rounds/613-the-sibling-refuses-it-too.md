---
round: 613
verdict: CLEAN
packages: [rpc_dart_http]
lens: RPC-08
bench: none — test
budget: probes 1/5, canaries 0/5
commit: yes
release: changelog
---

# Round 613 — the sibling refuses it too

## Target

B-201's measurable half: `rpc_dart_http`'s responder was assumed to inherit
round 504's grammar fix, because it calls `policy.isValidMethodPath`. Nobody
drove it.

## Hypothesis

Over HTTP/1.1, `/a/b.c` still reaches a method registered as `a.b`/`c`, in at
least one configuration.

## Before

Service `a.b`, method `c`, a real socket and a foreign client:

```
                        /a/b.c            handler    /a.b/c (control)
transport with policy   400, no status    not run    200, status 0
transport without       200, status 3     not run    200, status 0
```

## Control

`/a.b/c` is served in both configurations, so the refusal is about the path and
not about the setup.

## Mechanism

With a policy the transport refuses the path before minting a stream. Without
one, the responder pipeline parses it with the same grammar and answers
INVALID_ARGUMENT. Two layers, one rule, and neither lets it through.

## After

n/a — no change. The test stays as the sibling's pin.

## Canary

n/a — no fix.

## Gate

The new file, analyzed and format-checked; `lib/` byte-identical to the previous
commit.

## Not fixed

The upstream half is not a code defect. A proxy rule or log filter written while
both forms reached one method never covered the second. It needs a release-note
line for operators, the owner's at release.

## Links

Lead `../backlog/B-201-path-filters-upstream-trusted-the-old-grammar.md` — closed.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 613]`.
Test `packages/transport/rpc_dart_http/test/a_dotted_method_path_is_refused_test.dart`.
