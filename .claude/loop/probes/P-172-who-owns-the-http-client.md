---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b143_injected_client.dart
round: 539
commit: 11baa648
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
---

# P-172 — who owns the `http.Client` the caller transport uses?

## Why it exists

The question is OWNERSHIP, and the two directions need different instruments. Whether an injected
client survives is asked by USING it afterwards — not by observing whether `close()` was called, which
is right for one kind of client and wrong for the other. Whether an owned client is still closed cannot
be asked that way at all: it is unreachable from outside, so it is read as a descriptor.

## The harness

A bare `HttpServer` answering 204. Arm one hands the transport a client the probe keeps, closes the
transport, then makes a request with that client. Arm two lets the transport create its own, drives one
real call through it so a keep-alive connection exists, and counts TCP descriptors before, during and
after the close.

A missing `lsof` exits 2, because the control arm would otherwise report nothing and read as a pass.

## The numbers (round 539)

Before the fix, arm one read `BROKEN: ClientException`. After:

```
  WITNESS an INJECTED client after transport.close()
    usable (204)

  CONTROL a client the transport OWNS must still be closed
    fds 2 -> 4 during the call -> 3 after close
```

The remaining descriptor is the probe's own listening socket.

## Measures

Arm one: the status code an injected client can still obtain. Arm two: TCP descriptors across the
close, which is what says an owned client was released.

## Control

**Arm two IS the control**, and it is the one that stops the fix being a trade. "Do not close the
client" would satisfy arm one and leak on every transport that made its own.

## What it establishes, and what it does not

Establishes: `close()` closed the client regardless of who created it, so a caller sharing one client
across transports — or between this transport and its own HTTP calls — had it broken by the first
close.

Does NOT prove the descriptor count attributes to the CLIENT rather than to the socket. A closed
transport's connection could also be released by dart:io on its own; the count says the resource is
gone, not which layer released it.

Does NOT cover the responder transport or the isolate/websocket siblings, none of which take an
injected client.
