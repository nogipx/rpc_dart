---
round: 670
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-15
bench: none — the lead's own probe, `refused_upgrade_flake.dart`, run beside the gate; a second probe for the callback case
commit: yes
release: none
---

# Round 670 — the body no upgrade carries

## Target

B-241, the only open websocket lead, next in the owner's order. Two tests went
red once each under gate load (rounds 640, 645). The lead owed one thing: the
refused-upgrade probe's frequency under the gate's own load, with and without
the body bytes the test sends after its upgrade request.

## Hypothesis

`closed` instead of the 403 appears only with the body bytes: dart:io does not
read a body on an upgrade request, so closing with them unread sends RST, which
can beat the 403 to the client.

## Before

`refused_upgrade_flake.dart`, 8 concurrent refused upgrades per round, run while
`melos run test:unit` ran in the background (load average 15):

```
with body bytes      150 rounds   1199 x 403, 1 closed
                     300 rounds   2392 x 403, 8 closed
without body bytes   150 rounds   1200 x 403
                     300 rounds   2400 x 403
```

9 of 3600 against 0 of 3600.

The callback-throws red (round 640) did not reproduce:
`b241_throwing_callback_ready.dart`, an `onEndpointCreated` that throws, the
client awaiting `ready`, under the same load: 1000 of 1000 `ready`.

## Mechanism

The test's `_slowBody` sent `content-length: 100000` and five bytes on every
request, the upgrade-shaped ones included. No websocket client sends a body on
an upgrade; the race is the test's.

## Fix

The test sends the body only on the POST arm. No library change.

## After

The test now sends exactly the probe's no-body request, the arm that read
`403` 3600 of 3600 under gate load. The file is green alone and in the gate.

## Canary

The probe's two arms are the ablation: body bytes back in, 9 of 3600 sockets
read `closed`; out, 0 of 3600. The test itself cannot show it reliably -- 8
sockets per run is about a 2% failure rate -- which is the reason it flaked
instead of failing.

## The verdict questions

1. Yes: the two arms differ by the body bytes alone.
2. Yes: 9 against 0, 3600 each.
3. Yes: what the client socket read.
4. The zero arm ran 3600 sockets beside the same gate that produced 9.
5. No failing witness in the usual sense; the probe's body arm is the
   ablation, quoted above.
6. One half.
7. Yes.
8. None.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check` green on a quiet run.
The background gate used as load went red twice while the probes ran beside
it -- `rpc_dart_log` "disconnect event when client disposes" and `rpc_notify`
"automatic cleanup of inactive streams" (`Expected: <2> Actual: <0>`) -- both
timing tests, both green in every quiet gate this session. Recorded, not filed:
the variable was the extra load this round added on purpose.

The first gate after the load runs (load average 11 at its start) went red once
more, in `a_timed_out_connect_releases_its_socket_test` WITNESS. Its message was
not captured -- the output was filtered to test names. Green alone, green in the
package suite (279 of 279), green in the next full gate. Unnamed, so not called a
flake; if it recurs, capture the assertion before anything else.

## Not fixed

The callback-throws red stays unexplained: 0 of 1000 under load. If it recurs,
the probe is in place.

## Links

Lead `../backlog/B-241-websocket-answers-lost-under-gate-load.md` closed.
Lens `../lenses/RPC-15-remeasure-own-record.md` -- `applied: [..., 670]`.
