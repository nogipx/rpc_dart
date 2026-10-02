---
round: 642
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; the coverage-review probes are cov_core_sink_pump*.dart
budget: probes 3/5, canaries 1/5
commit: yes
release: changelog
---

# Round 642 — a source that errs and stays open

## Target

A coverage-review finding (round 640) in `SinkPump`, the shared pump behind
both bidi request and response sinks: its `onError` branch.

## Hypothesis

After a source error the pump lets go of the source, as it does when the call
ends.

## Before

```
requestSink.addStream(controller), one item, then an error, then more items
control (abort, no error)   sourceCancelled=true  addStreamDone=true  caller.close()=ok
                            client {activeStreams: 0, streamControllers: 0}
error                       sourceCancelled=false addStreamDone=false
                            caller.close() THREW Bad state: Cannot add event while adding a stream
                            client {activeStreams: 1, streamControllers: 1}
shared broadcast feed       feed.hasListener=true after the call ended
```

## Control

The control row above; an `async*` source that throws ends at its error, so it
never showed this.

## Mechanism

`onError` set `_finished` and did not cancel the subscription, and `stop()` --
the only cancel -- returns early on `_finished`. `addStream` does not end at an
error, so it stayed active, the producer's `await addStream` never returned,
and `close()` then threw synchronously from `_controller.close()`, before the
processor was closed. The pump's own doc listed "cancel before closing" as a
rule; the error path skipped it.

## After

`onError` calls `stop()`. The witness reads source cancelled, `addStream`
complete, `['a']` delivered and nothing after, `close()` fine, zero streams.

## Canary

`stop()` replaced by the old flag assignment: `the source is still pulled`.

## Gate

Recorded in round 645.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 642]`.
Test `packages/core/rpc_dart/test/streams/a_source_that_errs_and_stays_open_is_let_go_test.dart`.
