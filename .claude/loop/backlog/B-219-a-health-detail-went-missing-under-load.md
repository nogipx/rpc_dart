---
status: open
round: 555
commit: 5d33d595
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/test/peer_ids_return_to_zero_test.dart]
probe: —
reason: "observed once in a loaded gate run and not reproduced: health().details['peerStreamIds'] was NULL where the same call had returned 0 seconds earlier. `lib/` was byte-identical to its committed state, so it is not the round's change — but a diagnostic that can answer `null` for a key it documents is a defect in the diagnostic, and the test asserts through a `!`"
---

# B-219 — a health detail answered null under load

Seen during round 555's gate, which is the only reason it is written down.

```
test/peer_ids_return_to_zero_test.dart: WITNESS: the heartbeat does not fill the peer-id set
  Null check operator used on a null value
  test/peer_ids_return_to_zero_test.dart 102:48  _peerIds
```

`_peerIds` is `(await t.health()).details['peerStreamIds']! as int`. The SAME call three seconds
earlier in the same test returned `0` — so the key was present and then absent.

## What is already established

- **Not this round's change.** `git status` showed `lib/` byte-identical to its committed state;
  the only modified file was an unrelated core test.
- **Not reproducible on demand.** The file passes alone (5 of 5), and the full `test:unit` passed
  on the next run with websocket at `241`.
- **The machine was loaded**: `load average 9.62 12.68 11.07`, well above the `uptime` under 3
  that `config.md` names as the condition for reading an intermittent failure.

## Why it matters

Two separate things, and the smaller one is certain:

1. **The test asserts through `!`.** Whatever makes the key absent, the witness reports it as a
   null-check crash rather than as the fact it is about, which costs a reader the diagnosis.
   Cheap to fix and worth doing whoever is right about (2).
2. **`health()` may be able to answer without a key it documents.** If `details` is assembled
   from a transport that is mid-reconnect or closing, a diagnostic an operator polls would be
   missing a field rather than reporting a state — the same class as B-104's `health()` reading
   CLOSED during a recovery, which was a real defect.

## Witness a round would build

Read `health()`'s detail assembly in the websocket wrapper and find every path on which a key can
be omitted — then drive that state deliberately rather than waiting for load to produce it. If no
such path exists, the finding is about the TEST's timing and the `!` is still wrong.

Do not start by looping the gate: one reproduction under load costs minutes and says nothing a
reading of the assembly does not say faster.

## Owner decision

—
