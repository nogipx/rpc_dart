---
round: 705
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-21
bench: none — by reading, with the existing Chrome death test as the gate; neither change is observable through the public API
commit: yes
release: changelog
---

# Round 705 — a dead worker is terminated, and not restarted

## Target

B-161 and B-162, isolate on the web.

- B-161: the host closes the transport on any worker `error` or `messageerror`.
  The lead reads an uncaught error as "one stray async error ends every call"
  and sketches failing only on termination.
- B-162: the worker's `onDone` fallback starts the user entrypoint when its
  message stream ends -- on a dead channel.

## Hypothesis

B-161 is a design question, and the parity answer differs from the lead's:
on the VM the isolate is spawned with `errorsAreFatal` and an uncaught error
kills it, so closing on `error` is the same contract on both. What does
differ: on the web the death listener closed the transport and left the worker
running.

## Before

Read, `isolate_transport_web.dart`: the death listener called
`transport.close()` only; `kill()` is the only `worker.terminate()`. The
existing Chrome test "a worker that dies after startup is noticed" sees the
transport closed and does not see the worker, which no public API exposes.

B-162, read: the stream that `onDone` listens to ends only when the channel
does; `RpcIsolateTransport.spawn` always sends `init`, so the fallback can only
ever fire too late.

`messageerror` (B-161's other half) is unreachable from this library: both
sides send maps of strings, numbers and lists, which always clone.

## Mechanism

As read.

## Fix

- The death listener terminates the worker as well, so an uncaught error ends
  it as it does an isolate on the VM, instead of leaving a worker with nobody
  to talk to for the life of the page.
- The `onDone` fallback is gone.
- The lead's sketch for B-161 (survive an uncaught error) is not taken: it
  would make the web and the VM disagree on what an uncaught error means.

## After

`worker_startup_failure_test.dart` in Chrome: 4 of 4; `test:web` green.

## Canary

None: neither change has an observable through the public API.

## The verdict questions

1. No canary; by reading.
2. Yes, both leads, with the B-161 sketch declined for parity.
3. Not measured.
4. -
5. -
6. Two causes.
7. One design choice, stated above.
8. None.

## Gate

As round 704's.

## Not fixed

Nothing in scope.

## Links

Leads `../backlog/B-161-isolate-web-any-worker-error-closes-the-connection.md` and
`../backlog/B-162-isolate-web-ondone-starts-the-entrypoint.md` closed.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` -- `applied: [..., 705]`.
