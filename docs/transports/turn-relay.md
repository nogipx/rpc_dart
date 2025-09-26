# TURN relay

`TurnRelayServer` implements an RFC 5766 compatible UDP relay in pure Dart. The
listener accepts TURN Allocate requests, provisions individual relay sockets for
clients, tracks permissions and channel bindings, and converts peer traffic back
into TURN Data indications or ChannelData frames. The implementation ships with
`rpc_dart_transports` but has no dependency on the RPC runtime, which makes it a
lightweight building block for any UDP-based application that needs NAT
traversal.

## Key capabilities

- **TURN/STUN encoding helpers** – `TurnMessage`, `TurnAttribute`, and related
  utilities cover XOR addresses, DATA attributes, lifetimes, and channel
  metadata so that you do not have to craft binary frames by hand.
- **Allocation lifecycle management** – `TurnAllocation` keeps per-client relay
  sockets, expiration timers, peer permissions, and channel bindings in sync
  with RFC 5766.
- **Full TURN method support** – the server handles `Allocate`, `Refresh`,
  `CreatePermission`, `ChannelBind`, and `Send` flows and delivers peer packets
  back to the client as Data indications or ChannelData messages depending on
  active bindings.
- **Embeddable logging** – `TurnRelayLogger` lets you adapt the relay output to
  your own logging infrastructure without pulling in extra packages.

## Running a relay

```dart
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

Future<void> main() async {
  final relay = TurnRelayServer(
    bindAddress: InternetAddress.anyIPv4,
    bindPort: 3478,
    logger: TurnRelayLogger(
      scope: 'turn',
      onInfo: (message) => print('[INFO] $message'),
      onWarning: (message) => print('[WARN] $message'),
      onError: (message, {error, stackTrace}) {
        print('[ERROR] $message');
        if (error != null) {
          print('  error: $error');
        }
        if (stackTrace != null) {
          print('  stack: $stackTrace');
        }
      },
    ),
  );

  await relay.start();
  print('TURN relay listening on ${relay.bindAddress.address}:${relay.port}');

  // ... keep the process alive ...

  await relay.stop();
}
```

When the listener binds to a private address, provide `relayAddress` so the
server advertises the externally reachable IP in the `XOR-RELAYED-ADDRESS`
attribute.

## Allocation lifecycle

Every successful `Allocate` request spawns a `TurnAllocation`:

- `clientAddress` / `clientPort` identify the TURN client socket.
- `relayPort` exposes the UDP port peers must target.
- `addPermission`, `hasPermission`, and `bindChannel` enforce the TURN security
  rules for authorized peers and optional channel bindings.
- `onPeerData` delivers datagrams received on the relay socket so the server can
  translate them back into TURN responses.

Allocations expire automatically after `allocationLifetime` (10 minutes by
default). A `Refresh` request extends the lifetime, while a zero-second
refresh tears the allocation down immediately. Permissions and channel bindings
are lazily pruned when their TTL elapses.

## Client workflow

1. **Allocate** – send an `Allocate` request (with `REQUESTED-TRANSPORT = UDP`).
   The success response returns the relay endpoint in `XOR-RELAYED-ADDRESS`.
2. **Create permissions** – authorize peers with `CreatePermission` requests.
3. **Send data** – use `Send` indications (`XOR-PEER-ADDRESS` + `DATA`) or bind a
   channel via `ChannelBind` and transmit ChannelData packets for lower
   overhead.
4. **Receive peer traffic** – the relay emits either Data indications or
   ChannelData frames back to the client depending on whether a channel binding
   exists for the peer.
5. **Refresh / tear down** – `Refresh` extends the allocation lifetime or closes
   it when the client requests a zero-second duration.

The integration test `turn_relay_server_test.dart` demonstrates this flow with a
TURN client talking to a peer socket through the relay.

## Helper APIs

Use the helpers from `turn_message.dart` to build or inspect TURN frames when
writing tests or integrating custom clients:

- `TurnMessage.encode()` / `TurnMessage.decode(...)`
- `encodeXorAddress` / `decodeXorAddress`
- `encodeLifetime` / `decodeLifetime`
- `encodeData`

These cover the pieces required for the UDP relay profile defined in RFC 5766.

## Limitations

- Only the UDP transport profile is supported – TCP allocations, TLS, and DTLS
  are currently out of scope.
- Authentication (long-term or short-term credentials) is not implemented; gate
  access at the network level or layer additional authentication on top.
- No quota management or alternate server discovery is provided yet.

Despite these gaps the relay is sufficient for controlled environments,
integration tests, or as a foundation for more advanced TURN deployments.
