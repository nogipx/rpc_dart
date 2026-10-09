---
round: 788
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-18
bench: P-282 — new
commit: yes
release: none
---

# Round 788 — autobahn finds nothing of ours

## Target

The network-audit skill's methods §5: the protocol's own conformance suite,
never run here (`loop.py find "autobahn conformance websocket
fuzzingclient"` names no record; round 786 had to skip it with no Docker
daemon). RPC-18 is the lens: the websocket transport puts its own frame
guard (`websocket_bounded_upgrade.dart`, `connectBounded`) in front of
dart:io, and a guard that parses frames can break legal framing or pass
illegal framing.

## Hypothesis

rpc_dart's accept path or its bounded connect fails Autobahn cases that bare
dart:io passes.

## Before

P-282, 247 cases (9.*, 12.*, 13.* excluded):

```
  agent               OK    NON-STRICT  FAILED  close not OK
  server (rpc_dart)   233   4           7       2
  server (bare io)    233   4           7       2
  client (rpc_dart)   226   11          7       3
  client (bare io)    224   13          7       2
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/autobahn_echo_server.dart`

## Mechanism

None of ours. The seven FAILED are the same cases on all four agents
(3.4, 5.6, 5.7, 5.8, 5.19, 5.20, 7.1.5), dart:io's. The one client
difference, 2.5, ends an oversized ping's connection without a Close frame.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: each rpc_dart agent against its bare-io twin differs only in
   rpc_dart's path being present.
2. The bench sees differences when there are any: the two client agents
   differ on three cases (2.5, 4.1.5, 4.2.5), so identical server columns
   are a result, not a blind bench.
3. Counted by Autobahn on the wire, against the library's own process.
4. 247 cases each, every one run; no timeouts reported.
5. n/a.
6. n/a.
7. CLEAN: the hypothesis failed against a control that can differ.
8. 9.* not run (performance, not conformance), 12.*/13.* not run
   (compression is off by default; C-70 says when to re-open). The 2.5
   difference is recorded, not fixed: below the bar, connection ends either
   way.
9. None.
A1. Separate processes: Autobahn in Docker, each agent its own binary.
A2. Neither: protocol cases.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

The 2.5 Close frame on the client, below the severity bar (C-70).

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
Probe `../probes/P-282-autobahn-on-both-websocket-paths.md`.
Negative `../checked/C-70-the-websocket-paths-add-no-conformance-failures.md`.
Round `786-late-cancels-on-websocket-meet-the-documented-bound.md`.
