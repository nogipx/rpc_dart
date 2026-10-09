---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b151_double_after_modules_start.dart
round: 560
commit: c500f803
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
status: valid
---

# P-184 — what two concurrent starts do to a server that is already binding

Two files, one question. The sibling half is
`packages/transport/rpc_dart_http2/.dart_tool/probe/b151_sibling_double_start.dart`.

## Why it exists

B-151 claims a start guard whose flag is assigned after the bind's await, so two concurrent callers
both pass it. Nothing had been run, and the claim named the wrong method — so the probe has to say
which method, and what the consequence actually is, rather than whether something breaks.

## The harness

A free port is taken by binding a `ServerSocket` and closing it, so the port is known and nothing
holds it. Then N concurrent starts, then one real call, then `stop()`, then a bind attempt on the
same port.

**THE PORT MUST BE FIXED, and that is the whole rig.** A first version used `port: 0`, where two
concurrent binds each get their own ephemeral port, nothing fails, and the catch under test never
runs — it hung with no output rather than reporting anything. With a fixed port the second bind fails
for the ordinary reason and the loser's catch is reached.

Four observables, because the two packages fail differently and no single one covers both: what each
start returned, `isRunning`, `endpoints`, the result of a call, and — on http2 — whether the port is
free after `stop()`.

## The numbers (round 560)

```
rpc_dart_http   (afterModulesStart)
  CONTROL one call          bound           isRunning=true   endpoints=1  call -> ok:x
  TWO concurrent            bound + threw   isRunning=true   endpoints=0  call -> status 14
  THREE concurrent start()  call -> ok:x

rpc_dart_http2  (start)
  CONTROL one start()       started           isRunning=true   call -> ok:x   port free after stop()
  TWO concurrent start()    started + threw   isRunning=false  call -> ok:x   PORT STILL BOUND
```

After the fix both `TWO concurrent` rows read as their CONTROL.

## Measures

State and outcome, not a quantity: what the server reports about itself, what a caller gets, and
whether the OS still holds the port.

**The port check is the only thing that can see http2's defect.** `stop()` returns normally there and
`isRunning` is already false, so every in-process observable says the server is down. A bind attempt
from outside is what says the listener is still there.

## Control

`CONTROL one start()` on the same fixed-port rig in both files — without it the failures below are
indistinguishable from a rig that cannot serve a call at all.

`THREE concurrent start()` on the http server is a second control and a refutation: it answers `ok:x`,
so the lead's claim about `start()` is wrong, and the probe says which method the defect is in rather
than agreeing with the lead about the file.

## What it establishes, and what it does not

Establishes that one cause produces two unrelated-looking disasters: a bound socket answering
UNAVAILABLE behind a healthy-looking flag, and a bound socket serving traffic that `stop()` refuses
to touch.

Does NOT exercise TLS on http2 — the secure bind is a different call behind the same claim — and does
not cover the four other items in B-151, none of which is about this guard.

Does NOT show the race is reachable from the framework. `RpcApp` drives phase one then phase two once
each; the reachable form is a misuse or a supervisor retry, which the round records.

## Reading

rpc_dart_http + rpc_dart_http2 — two files, one question: what two concurrent
starts do to a server that is already binding. **A FIXED port is the whole
rig** — with `port: 0` each concurrent bind gets its own ephemeral port,
nothing fails, and the catch under test never runs; the first version hung
with no output rather than reporting that. Four observables, because the two
packages fail differently: what each start returned, `isRunning`, `endpoints`,
a real call, and whether the port is free after `stop()`. **That last one is
the only thing that can see http2's defect**, since `stop()` returns normally
and `isRunning` is already false — every in-process check says the server is
down, and a bind attempt from outside says the listener is still there. `THREE
concurrent start()` answering `ok:x` is a second control and a refutation of
the lead's own claim.
