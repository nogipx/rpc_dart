---
status: open
round: 863
commit: 911fe219
paths: [packages/transport/rpc_dart_http2/test/tiny_messages_are_weighed_test.dart]
probe: none — the full gate, `melos run test:unit --no-select`
reason: bench — intermittent: timed out once in the full gate, passes alone in 7 s
rank: 3
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

Rounds 877-879 (2026-10-16): the full gate went red on one or two tests in
five of nine runs, every time green alone and green on the next run. The
machine's load average was 25 (another application building), and
`fast_cbor_encoder_test`'s map encode took 81 ms against its usual 18. One
run with a report per package named the reds:

```
conformance  i1 every call ends, peer normal: http | unary  status 4, 300 ms deadline
http         graceful_drain_on_stop_test   'status 14' (300 ms wait before stop)
http2        tiny_messages_are_weighed_test  WITNESS, refusal list empty
rpc_dart     audit_frame_reassembly_linear_test  ratio 3.58
```

A later full gate named three more, all green when run alone:

```
conformance  i3 an oversized message that never finishes: socket
http2        graceful_drain_on_stop_test  a second stop during a drain
isolate      isolate_verification_test    several isolates run in parallel
```

Each has a fixed wall-clock budget (300 ms, a 300 ms head start, a 20 s
queue phase, a timing ratio). This is a class of tests, not one test.

Round 880 (P-335) fixed the conformance `i1 ... peer normal` red. The
load was made with spinning processes, and at 24 of them on 8 cores a
working peer's 300 ms unary call failed status 4 in 3 of 60 calls. Both
working-peer rows in i1 now use a 10 s deadline. The other six tests
above are still open.

Round 884's gate runs named two more, all green when run alone, at a 5-minute
load average of 10 to 49:

```
http2        graceful_drain_on_stop_test  a restart during a drain: 'status 14'
conformance  i9 online again after the server restarts: websocket
             (still RpcClientConnecting after 5 s)
```

The first passed 3 of 3 runs under 12 spinning processes
(`packages/transport/rpc_dart_http2/.dart_tool/probe/r884_under_load.dart`,
P-335's load for any package's test file).

Round 885 ran the quiet gate eight times (5-minute load average 8 to 26,
desktop apps taking ~2.5 cores). Every run was red on exactly one test, and
the test rotated:

```
runs  tree                                   red
4     the fix, the I-3 websocket deaf cell   conformance i3 an oversized message that never
      running                                finishes: socket ('a message at the limit:
                                             status 14 ... stream closed before the peer
                                             sent a status')
1     the same                               conformance i9 websocket server restart (still
                                             RpcClientConnecting after 5 s)
1     the same                               conformance i1 many calls on one connection:
                                             http, working peer (clientStream status 14,
                                             'Connection closed before full header')
1     the fix, the deaf cell skipped         conformance i9 websocket server restart
1     no fix, the deaf cell skipped          http policy_reaches_endpoint_test
                                             maxConcurrentHandlers ('unsolicited response')
```

Each passed when run alone; the conformance package passed whole alone, whole
next to rpc_dart_websocket's suite, and whole under 10 spinning processes
(`packages/test/rpc_dart_conformance/.dart_tool/probe/r885_under_load.dart`,
P-335's load for that package); the i3 oversized row passed 3 of 3 under 12
and its socket cell 3 of 3 under 16. CPU load alone did not reproduce any of
them; only the whole workspace at once did.

## Next step

Drive each remaining test with `P-335 test <burners> <file>`, starting
from 24 burners, the gate's observed load. For each one, check whether its
budget covers work that grows with load and not with the defect it
witnesses.

## Owner decision

—
