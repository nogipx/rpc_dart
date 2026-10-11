---
round: 812
verdict: CLEAN
packages: [rpc_dart_http, rpc_dart_websocket]
lens: RPC-22
bench: P-298 — new
commit: yes
release: none
---

# Round 812 — both servers survive descriptor exhaustion

## Target

Network-audit catalog KV-WS-05 (d): run a server past its file descriptor
limit and check the accept loop recovers (the class of CVE-2023-4785). No
journal record covered it (`find 'file descriptor exhaustion EMFILE accept
loop ulimit'`). B-287, the next lead by severity, needs an API decision
(where a shared socket watcher lives), so it waits for the owner review.

## Hypothesis

An accept error (EMFILE) reaching an rpc_dart server's accept loop kills it
or escapes to the zone, so the server stays dead after the descriptors
free up.

## Before

```
P-298 control, ulimit -n 128 on the server process:
  http, no idle connections   honest call ok
  ws,   no idle connections   honest call ok
```

## Mechanism

n/a (CLEAN): both accept loops survive.

## After

```
  http, 300 idle connections   held: 14 (refused); served again 2595 ms after release
  ws,   300 idle connections   held: connect fails;  served again 2645 ms after release
  server process (runZonedGuarded)   no uncaught error
```

## Canary

The control is the attack's absence: the same honest call succeeds at once
without the idle connections and fails while they hold the descriptors, so
the bench does reach the limit.

## The verdict questions

1. Only the idle connections differ.
2. Yes: refused while held, ok without them.
3. The honest call's outcome, at the caller; uncaught errors in the
   server's own zone.
4. The recovery is polled to success (2.6 s), not read once.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. B-287 skipped for an owner question, not dismissed.
9. none.
10. No code changed.
A1. Separate processes.
A2. Volume (descriptors); the recovery is latency, measured.
L1. n/a.

## Gate

No code changed; the probes are outside the tree (`.dart_tool/probe`).

## Siblings

No code changed.

## Not fixed

- B-288 (new, S3): `RpcWebSocketCallerTransport.connect` throws a raw
  dart:io `HttpException` when the upgrade's connection is closed, where
  the http caller maps the same failure to UNAVAILABLE.
- TLS and http2 not covered.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-298-a-server-past-its-file-descriptor-limit.md`. Negative
`../checked/C-74-both-servers-recover-from-file-descriptor-exhaustion.md`.
Lead `../backlog/B-288-websocket-connect-throws-a-raw-httpexception.md`.
