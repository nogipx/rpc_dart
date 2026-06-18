<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# TURN relay

`TurnRelayServer` implements an RFC 5766 compatible relay in pure Dart. Clients
connect over TCP, while the relay provisions per-allocation UDP sockets *or*
TCP listeners for peer traffic. The listener accepts TURN Allocate requests,
tracks permissions and channel bindings, and converts peer packets back into
TURN Data indications or ChannelData frames. The implementation ships with
`rpc_dart_transports` but has no dependency on the RPC runtime, which makes it a
lightweight building block for any UDP- or TCP-based application that needs NAT
traversal.

## Key capabilities

- **TURN/STUN encoding helpers** – `TurnMessage`, `TurnAttribute`, and related
  utilities cover XOR addresses, DATA attributes, lifetimes, and channel
  metadata so that you do not have to craft binary frames by hand.
- **Allocation lifecycle management** – `TurnAllocation` keeps per-client relay
  sockets or TCP listeners, expiration timers, peer permissions, and channel
  bindings in sync with RFC 5766.
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

- `clientAddress` / `clientPort` identify the TCP client connection.
- `relayPort` exposes the UDP or TCP port peers must target.
- `addPermission`, `hasPermission`, and `bindChannel` enforce the TURN security
  rules for authorized peers and optional channel bindings.
- `onPeerData` delivers datagrams received on the relay socket so the server can
  translate them back into TURN responses.

Allocations expire automatically after `allocationLifetime` (10 minutes by
default). A `Refresh` request extends the lifetime, while a zero-second
refresh tears the allocation down immediately. Permissions and channel bindings
are lazily pruned when their TTL elapses.

## Client workflow

1. **Allocate** – send an `Allocate` request with the desired
   `REQUESTED-TRANSPORT` (UDP by default, TCP when peer sockets should be
   stream-oriented). The success response returns the relay endpoint in
   `XOR-RELAYED-ADDRESS`.
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

### Client options

`TurnRelayClient.connect` accepts a `TurnRelayClientOptions` instance when you
need to customize timeouts, lifetimes, the local bind address, peer transport,
or permission behaviour:

```dart
final client = await TurnRelayClient.connect(
  serverAddress: server.bindAddress,
  serverPort: server.port,
  options: const TurnRelayClientOptions(
    requestTimeout: Duration(seconds: 3),
    allocationRefreshMargin: Duration(seconds: 10),
    autoCreatePermission: false,
    requestedTransport: TurnRequestedTransport.tcp,
  ),
);
```

Leaving the parameter out falls back to the built-in defaults (5 second request
timeouts, automatic permission creation, and allocation refreshes scheduled 30
seconds before expiry).

## Using `RpcTurnRelayPeer`

`RpcTurnRelayPeer` wraps the TURN client so that you can publish your relay
endpoint first and decide on the actual peer address later. It stores responder
contracts up front, keeps a single connection to the relay server, and creates
the underlying transports on demand once you know where the remote participant
is reachable.

```dart
final peer = await RpcTurnRelayPeer.connectToRelay(
  serverAddress: relay.bindAddress,
  serverPort: relay.port,
  responderContracts: [EchoResponderContract()],
);

print('Share this TURN endpoint: ${peer.relayAddress.address}:${peer.relayPort}');

// ... exchange relay coordinates with the other participant ...

await peer.connectPeer(
  peerAddress: otherPeerAddress,
  peerPort: otherPeerPort,
);

final response = await peer.callerEndpoint.unaryRequest<RpcString, RpcString>(
  serviceName: 'echo',
  methodName: 'echo',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  request: RpcString('ping'),
);

print(response.value);
```

`connectPeer()` lazily provisions the caller and responder transports. After the
call returns you can start issuing outgoing RPC requests through
`callerEndpoint`, while `responderEndpoint` automatically exposes the contracts
provided during construction. The `close()` method disposes of every resource and
is safe to invoke multiple times.

### Coordinating QR-based invitations

You can keep the entire invitation workflow inside the RPC layer without
standing up a dedicated signaling service. A typical flow looks like this:

1. Both participants call `RpcTurnRelayPeer.connectToRelay(...)` during app
   startup and register a contract with a method such as `incomingInvite`.
2. Each client generates a QR code that bundles its `relayAddress`,
   `relayPort`, and any additional metadata (for example a display name or
   verification token).
3. When Alice scans Bob's QR code she immediately calls
   `peer.connectPeer(peerAddress: bobAddress, peerPort: bobPort)` to create the
   TURN transports, then performs an RPC call to `incomingInvite` with her own
   coordinates.
4. Bob's handler shows the prompt to the user. If the invite is accepted it
   calls `peer.connectPeer(...)` with Alice's address and port from the request
   before returning a positive response.
5. Once both sides have confirmed the invite they continue using the same
   caller/responder endpoints for the main session.

The contract can decode the invite payload and establish the transport only
after the user confirms the connection:

```dart
import 'dart:convert';
import 'package:universal_io/io.dart';

class ConnectionInvitationContract extends RpcResponderContract {
  ConnectionInvitationContract(this.peer, this.showPrompt)
      : super('ConnectionInvitation');

  final RpcTurnRelayPeer peer;
  final Future<bool> Function(Map<String, Object?> payload) showPrompt;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcBool>(
      methodName: 'incomingInvite',
      requestCodec: RpcString.codec,
      responseCodec: RpcBool.codec,
      handler: _handleInvite,
    );
  }

  Future<RpcBool> _handleInvite(
    RpcString request, {
    RpcContext? context,
  }) async {
    final payload = jsonDecode(request.value) as Map<String, Object?>;
    final accepted = await showPrompt(payload);

    if (accepted) {
      await peer.connectPeer(
        peerAddress: InternetAddress(payload['peerAddress']! as String),
        peerPort: payload['peerPort']! as int,
      );
    }

    return RpcBool(accepted);
  }
}
```

Alice issues the invite with her own coordinates so Bob can connect back once he
approves the prompt:

```dart
final inviteAccepted = await peer.callerEndpoint.unaryRequest<RpcString, RpcBool>(
  serviceName: 'ConnectionInvitation',
  methodName: 'incomingInvite',
  requestCodec: RpcString.codec,
  responseCodec: RpcBool.codec,
  request: RpcString(jsonEncode({
    'peerAddress': peer.relayAddress.address,
    'peerPort': peer.relayPort,
    'displayName': currentUserName,
  })),
);

if (!inviteAccepted.value) {
  // user on the other side declined the connection
  return;
}
```

This approach keeps the QR exchange, confirmation prompt, and session setup in a
single RPC protocol while the TURN relay continues to forward the encrypted
transport traffic.

### Relay-assisted connect requests

When you want the relay to notify a participant about an incoming connection,
use the custom TURN method `CONNECT-REQUEST` exposed through
`RpcTurnRelayPeer`.

```dart
// Bob subscribes to incoming notifications before showing his QR code.
peer.connectRequests.listen((TurnConnectRequest request) async {
  final shouldAccept = await showPrompt(request);
  if (!shouldAccept) {
    return;
  }

  await peer.connectPeer(
    peerAddress: request.peerAddress,
    peerPort: request.peerPort,
  );
});

// Alice scans Bob's QR code and asks the relay to ping Bob.
await peer.requestPeerConnection(
  peerAddress: bobAddress,
  peerPort: bobPort,
  payload: utf8.encode(jsonEncode({
    'displayName': currentUserName,
  })),
);
```

The relay delivers an indication containing the requesting allocation's relay
address/port plus the optional payload. This keeps the "please connect back"
notification inside the TURN transport without introducing a separate signaling
channel.

## Helper APIs

Use the helpers from `turn_message.dart` to build or inspect TURN frames when
writing tests or integrating custom clients:

- `TurnMessage.encode()` / `TurnMessage.decode(...)`
- `encodeXorAddress` / `decodeXorAddress`
- `encodeLifetime` / `decodeLifetime`
- `encodeData`

These cover the pieces required for the UDP relay profile defined in RFC 5766,
while the TCP stream framing is handled internally by `TurnTcpFrameDecoder`.
When requesting TCP peer transport, the allocation exposes a TCP listener and
forwards bytes through established connections.

## Limitations

- TURN client connections run over TCP. Peer allocations may be UDP or TCP,
  but TLS and DTLS remain out of scope, and the TCP workflow assumes peers can
  actively connect to the advertised relay port.
- Authentication (long-term or short-term credentials) is not implemented; gate
  access at the network level or layer additional authentication on top.
- No quota management or alternate server discovery is provided yet.

Despite these gaps the relay is sufficient for controlled environments,
integration tests, or as a foundation for more advanced TURN deployments.
