---
pack: async-io
applies: "a bidirectional channel with a bound on bytes in flight: networks, pipes to a subprocess, actor queues, database cursors."
breaks: a hang that never ends, with a dead deadline.
status: confirmed
---

# U-16 — The write and the answer in one wait

**A symptom worth recognising: a deadline that provably never fires.** It means
the wait beneath it sits below another wait that blocks; the bug is not in the
deadline but in its position.

The right shape: start the write, feed its error into the same completer as the
answer, and wait on one thing.

## Shape

`await write; await answer` where the other side may answer INSTEAD of finishing
the read.

## Detector

Places where the send and the wait for the answer are sequential over a single
channel; plus deadlines that have never fired.

## Ask

Can the other side stop reading and answer on the same channel?

## Evidence

The send parked in the flow-control window while the refusal sat unread in the
same stream.
