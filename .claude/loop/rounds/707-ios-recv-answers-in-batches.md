---
round: 707
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a device probe, 2000 frames of about 1 KiB each way, three rounds (`example/integration_test/zz_probe_frame_rate.dart`, untracked; a copy in `.dart_tool/probe/zz_probe_frame_rate.dart.txt`), and a guest method `Kilobytes` for it
commit: yes
release: changelog
severity: S2
---

# Round 707 — iOS recv answers in batches

## Target

B-168, the iOS half: `/recv` returns exactly one frame per fetch even when
many are queued, so host-to-guest costs a URL-scheme fetch per frame; sends are
one fetch per frame too. The Android half is not reached here (Not fixed).

## Hypothesis

Host-to-guest is capped by fetches, not bytes.

## Before

iOS 18.6 simulator, 1 KiB frames:

```
round 0  guest->host 3636 f/s   host->guest 211 f/s
round 1  guest->host  649 f/s   host->guest 243 f/s
round 2  guest->host 1101 f/s   host->guest 375 f/s
```

## Mechanism

As hypothesised for `/recv`.

## Fix

`/recv` answers with everything queued, concatenated, up to 64 frames and
4 MiB, always at least one. Safe because the bridge is a byte stream: the
guest's multiplexer reassembles frames across and within chunks.

Tried and reverted, recorded because it is a trap: batching the guest's SENDS
the same way (one fetch per microtask turn) took guest-to-host to
8826-20772 f/s and failed `guest_to_host_order_test` with `Stream 1 buffered
more than 1024 un-consumed messages`, at 256 frames per fetch and at 64. A
probe on the host showed microtasks running between chunks
(`maxPendingMicro=1`, after making the bridge's controller async, also
reverted) while the consumer still lagged -- `consumed=2112` when the cap
tripped. The host cannot absorb a fast guest's burst of tiny frames; the
fetch per frame was what paced it. Not pursued further: a VM rig for it lost
frames and proved nothing.

## After

```
round 0  guest->host 3798 f/s   host->guest 4231 f/s
round 1  guest->host 2168 f/s   host->guest 1363 f/s
round 2  guest->host 2439 f/s   host->guest 2220 f/s
tiny host->guest burst: 10000 of 10000
```

Host-to-guest about 6-11x. Full iOS device suite: 32 passed, 2 skipped.

## Canary

Before is the canary, on the same simulator and guest.

## The verdict questions

1. Yes: Before on the same tree.
2. The iOS half of the lead.
3. Yes: frames per second, and every frame arriving.
4. Not zero-valued.
5. Yes, quoted; the rounds vary a lot on a simulator.
6. One cause for this half.
7. Not a trade: nothing gets slower.
8. None.

## Gate

`analyze:native` PASS, `test:wasm:device` on iOS.

## Not fixed

- Android: adb could not reach its own loopback server this session
  (`protocol fault (couldn't read status): Network is down`, on 5037 and on
  another port, with a Proxifier system extension running), so the Android
  half -- pure-JS base64, a script per frame, three IPC trips per tick -- is
  unmeasured. B-168 stays open for it.
- Guest-to-host batching, above.

## Links

Lead `../backlog/B-168-wasm-byte-transport-cost.md` -- iOS recv done, open.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 707]`.
