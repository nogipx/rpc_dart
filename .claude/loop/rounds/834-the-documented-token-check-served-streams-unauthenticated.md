---
round: 834
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — the witness test is the measurement; the probe is below
commit: yes
severity: S2
release: changelog
---

# Round 834 — the documented token check served streams unauthenticated

## Target

Network-audit KV-R-13 asks that "the framework's docs and examples teach
reading identity from the authenticated context". Reading the shipped
skill's one auth example for that, the question became a different one:
does the example's check cover every call?

## Hypothesis

The skill's `RequireTokenInterceptor` overrides `interceptUnary` only;
`IRpcInterceptor`'s other three methods pass through by default, so a server
built from the example serves streaming calls without a token.

## Before

Probe `packages/core/rpc_dart/.dart_tool/probe/r834_auth_interceptor_shapes.dart`,
the example copied verbatim, one method per shape:

```
  with token: unary served | serverStream served | clientStream served | bidi served
  no token:   unary 16     | serverStream served | clientStream served | bidi served
```

## Mechanism

As hypothesised. The surrounding text added "Defaults pass through; override
only what you need", which for a check is the wrong advice.

## Fix

- The example checks in all four methods through one `_check`.
- The text: a check must override all four, or the shapes it skips are
  served unchecked; the same sentence on `IRpcInterceptor`'s dartdoc.
- A test copies the example and pins it: four shapes refused without a token,
  served with one.

The API itself still makes the unsafe version the short one: B-291 (owner).

## After

```
  no token:   unary 16 | serverStream 16 | clientStream 16 | bidi 16
```

Witness `packages/core/rpc_dart/test/endpoint/a_token_check_covers_every_call_shape_test.dart`
(+8).

## Canary

The probe's default arm is the old example in place: three streaming shapes
served without a token, against all four refused with the rewrite
(`everywhere` arm).

## The verdict questions

1. Only the interceptor differs between the arms.
2. Yes: three shapes served against none.
3. At the caller: the status or the served value per shape.
4. Four shapes each.
5. The old example serves the streams, quoted above.
6. n/a (one example).
7. From the probe.
8. KV-R-13's own question (identity from the body) is not addressed by this
   example; no doc example reads identity from a request body (searched the
   skill, the READMEs and docs/ for request.userId / tenantId and the like).
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`check:skills` green (the example compiles), `melos run analyze` green, the
witness green. `test:unit` not re-run: besides the new test the commit
changes a dartdoc and the skill only, and the full suite ran green for
round 833 just before.

## Siblings

- caller endpoints: the same interface; a caller-side check (adding a token)
  has the same shape trap, covered by the same sentence
- transports: n/a, the interceptor chain is core's

## Not fixed

- B-291: an API that covers every shape by construction.

CHANGELOG line: "rpc_dart docs: the token-check interceptor example now
checks all four call shapes; one that overrides `interceptUnary` alone
serves streaming calls unchecked."

## Links

Lens `../lenses/RPC-23-the-narrative-beside-the-code.md`. Lead
`../backlog/B-291-a-check-interceptor-covers-only-the-shapes-it-overrides.md`.
