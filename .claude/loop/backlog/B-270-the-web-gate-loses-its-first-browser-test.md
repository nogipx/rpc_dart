---
status: open
round: 747
commit: bdbfc742
paths: [pubspec.yaml, packages/transport/rpc_dart_isolate/test/web_worker/**]
probe: none
reason: bench — intermittent, not reproduced in 13 runs since, the failure text never captured
rank: 7
---

# B-270 — the web gate loses its first browser test

`melos run test:web` failed twice in about ten runs during rounds 746-747,
both times at the same step, the first chrome invocation:

```
  00:00 +0 -1: loading test/web_worker/echo_worker_test.dart [E]
  00:00 +0 -1: Some tests failed.
```

At 00:00, so not the "Timed out waiting for Chrome to connect" cold start the
script's own comment describes, which takes tens of seconds.

Not reproduced since:

```
  echo_worker_test.dart alone, 8 runs           8 passed
  the whole gate, foreground, 3 runs            3 passed
  the whole gate beside the websocket suite     passed
  the whole gate, unfiltered, round 755         passed
  the whole gate, unfiltered, round 760         5 passed, idle machine
  the whole gate beside the websocket suite     2 passed, round 760; both
                                                websocket runs 295/295, so the
                                                load was real
```

Round 760 varied the one variable the two failures share a guess about, load,
and it did not bring the failure back (L-19). The full logs are kept for a
run that does fail: `melos run test:web --no-select > <file> 2>&1`, then
the lines after `loading test/web_worker/echo_worker_test.dart`.

One of the two failures ran beside the websocket suite; the other ran alone.

**What the next occurrence must keep: the text after `[E]`.** Both failures
were seen through a grep that kept only the `[E]` line. Run the chrome step
unfiltered, or with `-A30`, so the load error itself is recorded. Do not add
a retry to the script: it hides exactly this, as the script's comment on the
cold-start flake explains.

## Owner decision

—
