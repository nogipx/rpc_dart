# rpc_dart_analytics

`rpc_dart_analytics` is a privacy-centric analytics layer for Flutter applications.
It runs the collection pipeline inside an isolate via `RpcIsolateTransport`, keeps
all events on-device using the encrypted storage primitives from `rpc_dart_data`,
and requires a `LicensifyPublicKey` to operate.

## Features

- 🧩 Designed for integration with existing `rpc_dart` stacks.
- 🔐 Transparent SQLCipher encryption for every stored payload.
- 📶 Works fully offline — no network connection is required to collect events.
- 🧵 Runs in a background isolate to isolate disk IO from the UI thread.
- 🧹 Offers a one-shot `disableAndClear()` helper to wipe all telemetry.

See `lib/rpc_dart_analytics.dart` for the public API surface.
