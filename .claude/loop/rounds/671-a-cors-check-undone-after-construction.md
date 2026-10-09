---
round: 671
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-22
bench: none — a direct read of applyTo/handlePreflight output for each claim; the file is `rpc_dart_http/.dart_tool/probe/b153_cors_claims.dart`
commit: yes
release: changelog
severity: S2
---

# Round 671 — a CORS check undone after construction

## Target

B-153, http1 in the owner's order. Six claims from the audit's static read;
each measured against the policy's actual output before deciding.

## Hypothesis

The policy validates `allowedOrigins` once and then reads the caller's list on
every response, so the list can be changed under it.

## Before

```
mutate     credentials + ['https://a.example'], then '*' added to that list
           evil origin -> allow-origin=*  credentials=true
case       configured 'https://App.Example.com', request lowercase -> no allow-origin
duplicates 12 Allow-Headers entries, {content-type, x-request-id, x-trace-id} twice
max-age    not sent (browsers fall back to ~5 s: a preflight per call)
```

The first is the security half: the constructor refuses `*` with credentials,
and that refusal could be undone with one `add`. The websocket sibling already
lower-cases its origins once.

## Mechanism

`allowedOrigins`, `allowedHeaders` and `extraExposedHeaders` were the caller's
lists, kept as given; matching was `List.contains`; the header values were
rebuilt by concatenation per response, defaults overlapping the required set.

## Fix

- The three lists are copied unmodifiable; origins are also kept as a
  lower-cased set and matched case-insensitively, the request's own origin
  reflected.
- Header values are de-duplicated and joined once in the constructor; the
  default `allowedHeaders` no longer repeats the required ones.
- `preflightMaxAge` defaults to 10 minutes -- the owner's choice in this
  session; `null` still means "do not send".
- The warning flag's doc now says what it is, one bool per process. The
  `print` fallback stays: without a logger it is the only place the opt-in
  shows.

## After

```
mutate     allow-origin=null  credentials=null
case       allow-origin=https://app.example.com
duplicates 9 entries, none twice
max-age    600
```

## Canary

`packages/transport/rpc_dart_http/test/cors_policy_reads_its_inputs_once_test.dart`,
four tests, one per half, all four ablated at once and each red on its own
assertion: `Expected: null Actual: '*'`; `Expected:
'https://app.example.com' Actual: <null>`; `Expected: an object with length of
<10>`; `Expected: '600' Actual: <null>`. Restored: 4 of 4 green.

## The verdict questions

1. Yes: each ablation is one half of the fix.
2. Yes: every before value differs from its after.
3. Yes: the policy's own emitted headers.
4. Not zero-valued.
5. Yes, quoted.
6. Four halves, four canaries.
7. Yes.
8. None.

## Gate

`analyze` green; `format:check` clean; `license:check` compliant. `test:unit`:
one red, in `rpc_dart_http2`, which this change cannot reach --
`stream_ids_survive_reconnect_test` WITNESS, the first call after
`reconnect()` refused with "connection ... no longer active". Green alone; a
probe of that scenario read 608 of 608 clean, quiet and beside the gate. Filed
as `B-247`, not called a flake. The next quiet gate: green in all 15 packages
(rpc_dart_http +221).

The gate run as LOAD for that probe (16 servers beside it) went red in
`handler_concurrency_limit_test` "a handler keeps its slot after its call is
abandoned", `Expected: <2> Actual: <0>` running handlers: the call's 50 ms
deadline against a machine this round had deliberately overloaded, so the
calls likely died before dispatch. Green in every quiet gate.

## Not fixed

Nothing on B-153.

## Links

Lead `../backlog/B-153-http1-cors-policy-items.md` closed.
Lead filed `../backlog/B-247-a-call-after-reconnect-saw-an-inactive-connection.md`.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` -- `applied: [..., 671]`.
