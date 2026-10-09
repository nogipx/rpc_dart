---
round: 533
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-14
bench: P-166 — new
commit: yes
severity: S2
---

# Round 533 — the timeout that only stopped waiting

## Target

B-137, next in rank order: the websocket connect timeout abandons the wait, not the TCP attempt.

Lens RPC-14, its canonical shape. The file's own comment already says
`Future.timeout` abandons the AWAIT and not the WORK — and then handles only the half where the
work SUCCEEDS late.

## Hypothesis

The connect keeps running until the OS gives up, holding a descriptor for minutes against a
black-holed address.

## Before

```
  baseline TCP fds                      0

  arm                                   settled as        TCP fds after
  CONTROL 40 opens that SUCCEED and close   40 opened         1
  40 opens to a BLACK HOLE             40 timed out      40
```

Bench `../probes/P-166-does-a-timed-out-connect-hold-its-descriptor.md`.

CONFIRMED, exactly one descriptor per abandoned attempt. Counted with `lsof` from outside Dart,
because the process keeps working, the socket is invisible to Dart, and the attempt reports
failure on time — every indirect reading sits behind a retry schedule the OS owns.

The arm asserts its own premise (all forty settled as `TimeoutException`), and a missing `lsof`
exits 2. A count that measured nothing must not read as a pass.

## Mechanism

`WebSocket.connect` uses a process-wide `HttpClient` unless given one. A `Future.timeout` over it
has nothing to cancel: the client keeps the connect, and the SYN retries.

## After

```
  40 opens to a BLACK HOLE             40 timed out      0
```

A bounded open gets its OWN `HttpClient`, closed on both exits: forced on failure, plain on
success — where the upgraded socket has already been detached from it, so the live connection is
untouched.

## Canary

**Three ablations, and the first two were wrong about which change matters.** Reverting the forced
close to a plain one: witness still passes. Removing `connectionTimeout`: still passes. Passing
`null` for the client — the shared one — fails `Expected: a value less than <10> / Actual: <20>`.

So the fix is OWNING the client, not either of the settings on it. Each of the first two ablations
left the other mechanism in place, which is why both read green.

> A canary has to remove the FIX, and "the fix" is not always the line that looks newest.

Two guards bound it: a connect that SUCCEEDS still answers an RPC after its client is closed
(which is what says the detachment is real), and an unbounded open — which gets no private client
— is unchanged.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package: 232
passed.

## Not fixed

**`connectionTimeout` is unmeasured.** It states the same bound inside the client that the outer
timeout states outside it, and since both are the same duration nothing here can separate them.
Kept because it makes the client's own behaviour match the contract; recorded as belt-and-braces
rather than as the fix.

**One `HttpClient` per bounded open, not pooled.** Irrelevant for websockets — every connection is
upgraded and detached, so there is nothing to pool — but it is an allocation per connect that did
not exist before, and nothing measured it.

**The probe is not portable.** `lsof` is not everywhere, and "that address is a black hole" is a
property of the network the run is on. Both are asserted rather than assumed, so the arm skips or
warns instead of passing quietly.

**The sibling transports were not swept.** RPC-14 has the same question for `rpc_dart_http` and
`rpc_dart_http2`, whose connect paths also take a timeout; nothing here looked.

## Links

Lens RPC-14. Bench P-166 (new). Lead B-137 closed. Round 530 applied the same lens from the other
end. The late-arrival half of this file was already handled, which is why the round's finding is
about the half a correct-looking comment did not cover.
