---
status: open
round: 863
commit: 911fe219
paths: [packages/transport/rpc_dart_http2/test/tiny_messages_are_weighed_test.dart]
probe: none — the full gate, `melos run test:unit --no-select`
reason: bench — intermittent: timed out once in the full gate, passes alone in 7 s
rank: 6
---

# B-297 — the tiny-messages witness times out under the gate

Round 863's first full gate failed `WITNESS a queue of tiny messages is
refused at the connection total` with `TimeoutException after 0:00:20`
(line 113). Alone it passes in 7 s, with round 862's change and with it
switched off, and the next full gate passed. The same run also failed one
rpc_dart test next to `audit_frame_reassembly_linear_test`, the config's
known wall-clock flake.

7 s alone against a 20 s cap leaves less than a 3x margin for a machine
running four packages at once; B-293 (round 860) was the same shape on the
isolate package.

Round 868 (P-334): 13 runs at 1, 4 and 8 copies at once, no timeout. The
post-release wait stays at 91-222 ms; the queueing phase grows (6.2 s
alone, up to 14.3 s at 8x) and has its own 20 s deadline, after which the
test releases the handlers with the uploads still running.

## Next step

Time the test under load (P-327's way: several copies at once) and see
whether its 20 s covers work that grows with load and not with the
defect it witnesses.

## Owner decision

—
