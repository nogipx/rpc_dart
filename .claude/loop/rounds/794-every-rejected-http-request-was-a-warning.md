---
round: 794
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-22
bench: P-287 — new
commit: yes
release: changelog
severity: S3
---

# Round 794 — every rejected http request was a warning

## Target

KV-R-10 on the sibling transport (L-12), after round 793 swept websocket:
the same repeated cheap inputs against `RpcHttpServer`. HTTP/1.1 is reached
by anything that can open a socket -- scanners, health checks, a browser's
cross-origin preflight -- so a per-request record is a count anyone chooses.

## Hypothesis

Some pre-dispatch rejection in the HTTP responder writes a warning per
request.

## Before

P-287, 100 requests each (excerpt):

```
  bad path               100 warnings   400
  GET                    100 warnings   405
  text/html              100 warnings   415
  no content-type        100 warnings   415
  OPTIONS preflight      100 warnings   405
  valid call (control)   0              200/0
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/log_records_per_hostile_request.dart`

## Mechanism

`RpcHttpResponderTransport._handleRequest` has six rejection exits (method,
active requests, content type, path, metadata size, metadata violation),
each calling `_logger?.warning` unconditionally. Round 604 fixed this shape
in the core pipeline; the HTTP transport refuses before the pipeline and
was not part of it.

## After

`_warnRejected(_Rejection, message)`: one warning per rejection kind per
transport, every request still answered. P-287: 1, 1, 1, 1, 1 with the same
answers.

## Canary

`test/a_rejected_request_warns_once_test.dart`, the once-guard made
always-true: both witnesses failed with `Expected: an object with length
of <1> ... has length of <10>`, the ten messages listed; the guard (two
different kinds still warn once each) green.

## The verdict questions

1. Yes: the hostile rows against the control row, same server and client.
2. Yes: 100 against 0; after, 1.
3. Library side: the server's own `LogController`.
4. n/a.
5. Yes, quoted.
6. One mechanism, one helper.
7. FIXED.
8. The two ERROR rows (garbage body, two messages) were not set aside by a
   record: they are core sites, a different mechanism (a parse failure
   logged and rethrown; a peer protocol violation classified as a fault),
   and round 795's target.
9. None.
A1. One process; raw client, server defaults.
A2. Volume: requests.
L1. The statuses are listed per row; each rejection is the transport's own
    named check.

## Gate

`fvm dart format` (1 changed), then `melos run analyze` green; `melos run
test:unit --no-select` green (15 packages, rpc_dart_http +235); `melos run
format:check` green; `melos run license:check` green. The test is
`@TestOn('vm')` (a dart:io server).

## Not fixed

The two core rows, round 795.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Probe `../probes/P-287-log-records-per-hostile-http-request.md`.
Round `793-an-advisory-error-was-an-incident-per-frame.md`.
Round `604-the-peer-chose-how-many-lines.md`.
