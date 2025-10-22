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
- 🛠️ Ships with optional in-memory diagnostics buffers for development builds.
- ☁️ Exposes fetch + acknowledge APIs (and a helper) for forwarding sealed
  events to your backend.
- 🎯 Supports per-event delivery hints so the app chooses how and where to send
  encrypted batches.

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

await analytics.logEvent(
  'subscription_purchase',
  properties: {'plan': 'pro'},
  deliveryHints: {'route': 'billing'},
);

Delivery hints stay local to the device and are exposed when you fetch upload
batches so the host app can decide which transport should handle them.
```

### Forwarding events to a backend

Because the worker stores Licensify-sealed tokens, you can upload them without
ever touching the raw payloads. Fetch the encrypted batches, send them to your
API, and acknowledge them so they are removed locally:

```dart
final uploaded = await analytics.uploadPendingEvents(
  (events) async {
    // Route batches based on the delivery hints each event carries.
    final marketingEvents = <Map<String, dynamic>>[];
    final billingEvents = <Map<String, dynamic>>[];

    for (final event in events) {
      final target = event.deliveryHints?['route'];
      final payload = <String, dynamic>{
        'id': event.id,
        'createdAt': event.createdAt.toIso8601String(),
        'sealed': event.encryptedToken,
      };

      if (target == 'billing') {
        billingEvents.add(payload);
      } else {
        marketingEvents.add(payload);
      }
    }

    if (marketingEvents.isNotEmpty) {
      await backendClient.sendAnalytics(marketingEvents);
    }
    if (billingEvents.isNotEmpty) {
      await billingClient.sendAnalytics(billingEvents);
    }
  },
  batchSize: 100,
);

debugPrint('Uploaded $uploaded events');
```

Delivery hints never leave the device unencrypted; they simply help you decide
which transport or API client should receive a batch before you forward the
sealed payloads.

If you prefer manual control, call `fetchForUpload()` to retrieve a batch and
`acknowledgeUpload()` once your backend confirms persistence.

### Developer diagnostics

To inspect recent events during development, enable the diagnostics buffer in the
configuration. The worker keeps the latest `maxEvents` payloads (unencrypted) in
memory and exposes them via `RpcAnalytics.diagnostics()`. The encrypted store on
disk is unaffected.

```dart
final analytics = await RpcAnalytics.initialize(
  RpcAnalyticsConfig(
    licenseKeyPaserk: 'k4.public.your-app-key-here',
    databasePath: '/path/to/analytics.sqlite',
    diagnosticsOptions: const RpcAnalyticsDiagnosticsOptions(
      enabled: true,
      maxEvents: 100,
    ),
  ),
);

final diagnostics = await analytics.diagnostics();
debugPrint('Diagnostics enabled: ${diagnostics.diagnosticsEnabled}');
for (final event in diagnostics.recentEvents) {
  debugPrint('${event.timestamp}: ${event.eventName}');
}
```
