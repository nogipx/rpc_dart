---
file: packages/core/rpc_dart/.dart_tool/probe/metadata_is_never_paced.dart
round: 282
commit: 736a9b8d
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-31 — is metadata paced by the send window?

The SEND-path bench B-28 asked for. A real `RpcInMemoryTransport.pair` with flow
control on and a consumer that has TAKEN a stream and stopped reading it; the
client then pushes frames of the same wire size two ways and the observable is
whether the sender ever parks.

Reuse it for any "does this path apply backpressure?" question — the arms differ
only in which send method is called.

## Measures

Sends that completed inside a per-send deadline, and whether one blocked. A send
that has not returned in 500 ms is a sender that parked; counting completions is
what turns that into a number.

## Control

`arm=payload`, and it took two attempts to build.

```
arm       frames offered  sends completed  sender PARKED  connection error
payload              200                8           true              none
metadata             200              200          false              none
metadata            4000             4000          false              none
```

Eight sends of 8 KiB is exactly the 64 KiB window, so the control does not just
park — it parks at the arithmetically right frame, which is what says the bench
is measuring the window and not a coincidence.

> **The slow consumer has to TAKE the stream.** A first version left nobody on
> `getMessagesForStream` and the control did NOT park: with no metered consumer
> `_onIncoming` credits ON ARRIVAL by design (round 206, C-20), so the window
> never depletes and the bench cannot see pacing at all. Subscribe to the
> per-stream metered view and `pause()` it.

> **Push past every bound you are not testing.** At 200 frames the metadata arm
> reported no connection error and that meant nothing — 1.6 MiB is a tenth of
> the queue's 16 MiB ceiling. Only 4000 frames (32 MiB, twice the ceiling) makes
> "no error" evidence rather than an artefact of the offer being too small.
