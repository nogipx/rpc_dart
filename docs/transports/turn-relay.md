# TURN relay transport

`RpcTurnRelayServer` brings RFC 5766 style UDP relaying into the
`rpc_dart_transports` package. It exposes a TURN listener that accepts
allocations from clients, forwards outbound datagrams to peers, and relays peer
traffic back to the original caller. The implementation lives entirely in Dart
and reuses the same diagnostics/logging facilities that power other RPC Dart
transports.

## What was implemented

- **TURN/STUN framing helpers** – `TurnMessage`, `TurnAttribute`, and encoding
  utilities cover the XOR address, data, channel data, and lifetime attributes
  required by RFC 5389/5766.
- **Allocation lifecycle management** – `TurnAllocation` tracks each client's
  relay socket, expiration timers, peer permissions, and channel bindings.
- **TURN method handlers** – the server responds to `Allocate`, `Refresh`,
  `CreatePermission`, `ChannelBind`, and `Send` flows and emits peer data through
  `Data` indications or channel data frames.
- **UDP relay sockets** – every active allocation binds its own UDP socket on
  the relay address so that peer hosts exchange datagrams without touching the
  TURN control port.

## When to use the relay

Choose the TURN relay when:

- you need a **NAT traversal helper** for WebRTC-style media flows or other
  bidirectional UDP protocols;
- **rpc_dart** already powers your control plane and you want to reuse the same
  logging, lifecycle hooks, and deployment story instead of running a separate
  coturn/turnserver process;
- you plan to **integrate TURN allocations with custom business logic**, e.g.
  provisioning relay quotas, introspecting active peers, or wiring RPC calls to
  allocation events.

## Starting a server

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

Future<void> main() async {
  final relay = RpcTurnRelayServer(
    bindAddress: InternetAddress.anyIPv4,
    port: 3478,
    logger: RpcLogger('turn'),
  );

  await relay.start();
  print('TURN relay listening on ${relay.bindAddress.address}:${relay.listenPort}');

  // ...keep the process alive until shutdown...

  await relay.stop();
}
```

By default the relay reuses the bind address as the public relay address. Supply
`relayAddress` when you run behind NAT or want to advertise a different IP in
`XOR-RELAYED-ADDRESS` attributes.

## Handling allocations and peers

`RpcTurnRelayServer` keeps a registry of live `TurnAllocation` instances that
your application can inspect. Each allocation exposes:

- `clientAddress` / `clientPort` – the TURN client's socket;
- `relayPort` – the ephemeral UDP port peers should target;
- `permissions` and `channels` (via helper getters) – check which peers are
  allowed or bound;
- `onPeerData` callback – invoked whenever a peer datagram arrives so the server
  can emit a `Data` indication back to the client.

Allocations expire automatically after `allocationLifetime` (10 minutes by
default). `Refresh` requests extend that lifetime, and the server sweeps expired
permissions and channels lazily whenever it evaluates them.

## Client interaction flow

1. **Allocate** – send an `Allocate` request with
   `REQUESTED-TRANSPORT = UDP`. The success response returns the relay socket in
   `XOR-RELAYED-ADDRESS` and echoes the client's `XOR-MAPPED-ADDRESS`.
2. **Create permissions** – issue one or more `CreatePermission` requests to
   authorize specific peers via `XOR-PEER-ADDRESS` attributes.
3. **Send data** – either:
   - send `Send` indications containing `XOR-PEER-ADDRESS` + `DATA`, or
   - bind a channel via `ChannelBind` and then transmit raw ChannelData frames
     for lower overhead.
4. **Receive peer traffic** – the relay transforms inbound peer datagrams into
   `Data` indications (or ChannelData frames) and forwards them to the client.
5. **Refresh / teardown** – `Refresh` requests renew the allocation; omitting a
   lifetime or setting it to zero tears the allocation down immediately.

The companion test `rpc_turn_relay_server_test.dart` demonstrates the full flow
end-to-end, including a peer replying through the relay.

## Helper APIs for TURN messages

`TurnMessage` offers strongly typed helpers for TURN/STUN encoding so you do not
have to handcraft byte buffers:

- `TurnMessage.encode()` and `TurnMessage.decode(...)` convert between Dart
  objects and UDP payloads.
- `encodeXorAddress`, `decodeXorAddress`, `encodeLifetime`, `encodeData`, and
  ChannelData helpers in `turn_message.dart` simplify working with common
  attribute types.

Use these utilities to integrate existing TURN clients, write your own
specialized tooling, or test interactions without extra dependencies.

## Limitations and roadmap

- Only **UDP allocations** are currently supported; TCP relaying, DTLS, and
  TURN-over-TLS are out of scope.
- **Authentication (long-term or short-term credentials) is not implemented**.
  Gate TURN access at the network perimeter or add your own challenge/response
  logic before exposing the relay publicly.
- No bandwidth quotas or alternate server selection (ALTERNATE-SERVER) logic is
  implemented yet.

Despite these gaps the relay is already useful for private deployments, tests,
prototyping, or as a foundation for a more feature-complete TURN service.
