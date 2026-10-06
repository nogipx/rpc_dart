---
status: open
round: 675
commit: 32974d54
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/example/integration_test/guest_to_host_order_test.dart]
probe: none — the device test itself; its failure text has not been captured
reason: "bench — found by round 675's device suite, pre-existing: red at 32974d54 too, Android emulator only (green on the iOS simulator)"
---

# B-255 — 10k frames from a guest stream fail on Android

## Seen

`guest_to_host_order_test` "10k frames from one guest stream arrive in order":
red on the Android emulator (API 30, arm64) at about 14 s, green on the iOS 18.6
simulator. Red at the session-start commit `32974d54` too, so it predates rounds
664-675.

## Not yet captured

The assertion: the test's `print` of the frame count never appears, so the
server stream itself failed before `toList()` completed, and the exception text
was lost in ~10k lines of the bridge's per-frame `debugPrint`. Run it with that
debug output off, or catch and print the error in the test, before reading
anything into it.

## Owner decision

—
