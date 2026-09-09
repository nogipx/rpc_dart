---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/wrapper_keeps_the_bound.dart
round: 209 — the validating round
commit: 906437a2
paths: [packages/transport/rpc_dart_http2/lib/**]
status: stale (906437a2) — rpc_http2_server.dart changed since; repeat the control before reusing
---

# P-03 — does a transport bound survive `RpcHttp2Server.transportWrapper`?

A real server, a client-stream upload into a handler that consumes nothing, and
a raw TCP relay counting client-to-server bytes. Four runs, differing only in
what the `transportWrapper` returns.

Run it with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/wrapper_keeps_the_bound.dart`. To test another capability,
add a decorator shape: the four in the file are the whole matrix that matters —
declares nothing, declares and forwards, declares and swallows, plus no wrapper
at all.

## Measures

Bytes that reach the server, on the WIRE, in 8 s. Not what the caller produced:
sends are fire-and-forget, so the sender's count is ~157 MiB in every run and
hides the bound completely. That trap is recorded in this package's
`upload_backpressure_test`.

## Control

Three of the four runs ARE the control, which is what makes the fourth
attributable: no wrapper at all, and two decorators that keep the capability
reachable. If any of those drifts upward the bench is measuring wrapping in
general rather than the capability. At validation:

```
                                    before      after
  no wrapper                        4176 KiB    4177 KiB
  plain decorator                   4177 KiB    4176 KiB
  declares and forwards it          4177 KiB    4176 KiB
  declares and SWALLOWS it        160900 KiB    4187 KiB
```

4176 KiB is the 4 MiB default `flowControlWindowBytes`, which names the control
under test. 160900 KiB is simply everything the generator produced in the
window — it was still climbing, so read it as "unbounded", not as a ceiling.

The `forwards` row is doing a second job: it is the guard against fixing this by
doubling the DISCHARGE instead of the defer, which would discharge twice for a
forwarding decorator and remove the bound again.
