# rpc_dart_analytics

`rpc_dart_analytics` is a privacy-centric analytics layer for Flutter applications.
It runs the collection pipeline inside an isolate via `RpcIsolateTransport`, keeps
all events on-device using the encrypted storage primitives from `rpc_dart_data`,
and requires a `Licensify` PASERK `k4.public` key supplied by the host
application.

> **Important:** The PASERK string must be bundled with the app (not derived from
> a password at runtime) and is used directly to seal every analytics payload
> through Licensify.

## Features

- 🧩 Designed for integration with existing `rpc_dart` stacks.
- 🔐 Every event is sealed with your Licensify public key before it reaches disk.
- 📶 Works fully offline — no network connection is required to collect events.
- 🧵 Runs in a background isolate to isolate disk IO from the UI thread.
- 🧹 Offers a one-shot `disableAndClear()` helper to wipe all telemetry.

See `lib/rpc_dart_analytics.dart` for the public API surface.

## Usage

```dart
final analytics = await RpcAnalytics.initialize(
  const RpcAnalyticsConfig(
    licenseKeyPaserk: 'k4.public.your-app-key-here',
    databasePath: '/path/to/analytics.sqlite',
  ),
);

await analytics.logEvent('app_launch');
```
