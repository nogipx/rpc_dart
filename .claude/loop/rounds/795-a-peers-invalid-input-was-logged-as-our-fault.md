---
round: 795
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: P-284 — reused
commit: yes
release: changelog
severity: S3
---

# Round 795 — a peer's invalid input was logged as our fault

## Target

The two ERROR rows round 794 left in P-287 (HTTP: a garbage body, two
messages on a unary call) are core sites, so the class was counted on the
core rig first: P-284 extended with three inputs a peer controls per call --
a prefix declaring a message over the limit, two complete messages, a valid
frame whose payload the codec cannot decode.

## Hypothesis

Requests the peer made invalid are logged at ERROR per call, sometimes more
than once, on every transport.

## Before

P-284, 200 calls each (records at warning or above; statuses sent):

```
  shape  oversized       twoMessages             badCbor
  u      200 (8)         200 (13)                200 (13)
  s      400 (8)         400 (13)                600 (13)
  c      400 (8)         legal: 0                600 (13)
  b      400 (8)         legal: 0                600 (13)
```

Sources: `parser.dart` (logged every refusal at error and rethrew it),
the processor's `message_parsing` and `request_deserialization` catches,
unary's catch (fault judged on the status code), and `sendError`, which
judges a fault from the status alone. P-287 over HTTP: garbage body 100,
two messages 100.

Probe: `packages/core/rpc_dart/.dart_tool/probe/warnings_per_peer_call.dart`

## Mechanism

Every site asks "is this a fault", and the answer it can compute is wrong
for these inputs: an over-limit message is RESOURCE_EXHAUSTED (not a fault)
but the parser logged before anyone asked; a second request and an
undecodable payload are answered INTERNAL, as gRPC does, and INTERNAL is a
fault code, so the status cannot tell them from a server failure. The error
object can.

## After

`IRpcPeerFault` marks an error raised for the peer's own input
(`RpcPeerFaultException`); `RpcStatus.isFaultError` reads false for it.
`tooManyMessages` and both decode failures raise it; the parser logs its
refusal at a guarded internal level and leaves the decision to the owner it
rethrows to; the processor's catch and unary's catch ask `isFaultError`;
`sendError` takes `fault`, which `sendWireError` and the bidi path fill from
`isFaultError(error)`, default true. Both new types are hidden from the
public barrel. P-284: 0 in every cell above except `s twoMessages`, which
keeps 200 warnings "Attempted to send response to closed controller" (a
race after teardown, round 796). Statuses unchanged; the undecodable
payload's message is "Request payload could not be decoded" (was "Internal
server error"). P-287: garbage body 0, two messages 0.

## Canary

`test/logger/a_peer_fault_is_not_an_incident_test.dart` (14 cases: 10
witnesses, 4 guards that a crashing handler is still an error on each
shape). Four halves, four canaries, each failing only its witnesses:
the marker check off (6 failed: badCbor on four shapes, second request on
two); the parser's error log restored (4 failed: oversized on four
shapes); `sendError` ignoring `fault` (4 failed: badCbor on s/c/b, second
request on s); the processor's `message_parsing` gate off (3 failed:
oversized on s/c/b). Each quoted `Expected: empty Actual: [...10 records]`.

## The verdict questions

1. Yes: per shape, each hostile input against `complete` on the same rig;
   and the guards (a handler's own crash) against the witnesses.
2. Yes: 200-600 against 0.
3. Library side: the responder's `LogController`.
4. The zeros after the fix come from the cells that read 200-600 before.
5. Yes, per canary.
6. Yes: four halves, four canaries.
7. FIXED.
8. `s twoMessages`' closed-controller warning is left for round 796: a
   different mechanism (a send racing teardown), measured here and named.
9. None.
A1. One process; a hand-built channel peer, the responder its own logger.
A2. Volume: calls per connection.
L1. The statuses are recorded per cell and unchanged by the fix.

## Gate

`fvm dart format`, then `melos run analyze` green; `melos run test:unit
--no-select` green (15 packages, rpc_dart +2144 ~1); `melos run
format:check` green; `melos run license:check` green; `melos run
check:skills` clean (the skill's `isFaultError` paragraph updated in this
commit). `fvm dart test -p node` on the new test: 14 of 14.

## Not fixed

`Attempted to send response to closed controller`, server stream, second
request: round 796.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`.
Probe `../probes/P-284-log-records-per-malformed-call.md`.
Probe `../probes/P-287-log-records-per-hostile-http-request.md`.
Round `794-every-rejected-http-request-was-a-warning.md`.
Round `515-the-rig-never-reached-the-warning.md`.
