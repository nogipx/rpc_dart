---
round: 808
verdict: CLEAN
packages: [rpc_dart_conformance]
lens: RPC-18
bench: none — the matrix row is the bench; its control is round 807's fix switched off
commit: yes
release: none
---

# Round 808 — metadata stays with its origin on every transport

## Target

Severity first: `next` lists I-10 (S1, metadata stays with its origin) as
NOT ENFORCED; its statement waited on B-276, which round 807 closed. An
invariant with no test comes before a lens. The round writes its matrix row
and checks every member, rather than trusting round 807's two witnesses.

## Hypothesis

After round 807 no transport's default client sends a call, or its
metadata, to an origin a redirect names; the compressed websocket path
still does (B-286).

## Before

```
I-10 test: none; round 807 witnesses: http caller, websocket default
handshake; http2: a reading only
```

## Mechanism

n/a (CLEAN).

## After

```
i10_metadata_stays_with_its_origin_test.dart, at c1a97ff4
  http       303, 307   pass (other origin: 0 connections)
  http2      303, 307   pass
  websocket  303, 307   pass
  websocket  compressed 303, 307   KNOWN FAILING (B-286): Expected <0> Actual <1>
  channel, isolate      NOT APPLICABLE (no origin)
  wasm                  skipped (outside the workspace)
whole matrix: +506 ~156, green
```

## Canary

Round 807's `followRedirects = false` switched off in the http caller:
`http | a 303 to another origin` fails `Expected: <0> Actual: <1>, the call
went where the 303 pointed`; restored, it passes. The 307 cell stays green
with it off, because dart:io does not follow a 307 for a POST.

## The verdict questions

1. The control is the same cell with one line of the fix off.
2. Yes: 1 connection at the other origin against 0.
3. At the other origin's socket (accepted connections).
4. Each cell asserts the dialed server saw the request first (L-15).
5. Quoted.
6. One mechanism per member; the http canary stands for the row, the
   compressed websocket cells are its standing positive control.
7. CLEAN from the numbers; the one failing path is filed (B-286).
8. No target dismissed.
9. none.
10. No code changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

The new test file: `fvm dart format`, then `analyze` (L-24), then the whole
conformance package (+506 ~156). `license:check` green. No library code
changed since c1a97ff4, whose full gate is in round 807.

## Siblings

No code changed.

## Not fixed

- `invariants/I-10` still reads `test: —` and its statement still says it
  waits on B-276. Both are the owner's; the test path is
  `packages/test/rpc_dart_conformance/test/i10_metadata_stays_with_its_origin_test.dart`.
- Proxies (the invariant names them) are not in the row.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Negative
`../checked/C-73-no-transport-takes-metadata-to-a-redirected-origin.md`.
Leads `../backlog/B-276-the-http-caller-follows-a-303-with-its-metadata.md`,
`../backlog/B-286-a-compressed-websocket-upgrade-follows-redirects.md`.
