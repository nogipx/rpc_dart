# Licensify-backed encrypted transport

This document updates the secure transport overlay to rely on the
[`licensify`](https://pub.dev/packages/licensify) package. Licensify wraps
PASETO v4 tokens around structured payloads, giving us authenticated and tamper
proof handshake messages without having to maintain a bespoke signature
implementation. The overlay is packaged as an adapter that wraps any existing
transport, so caller and responder agree on session keys automatically and
every frame is protected with AEAD without modifying the underlying transport
implementations.

## Design goals

- **Compositional** – the encrypted overlay wraps any existing transport using a
  `SecureTransportAdapter`, leaving the original constructors untouched.
- **Hands-off configuration** – endpoints only store their long-term signing
  keys. All session material is exchanged through Licensify tokens during
  startup.
- **Forward secrecy** – session keys are derived from per-connection seeds and
  thrown away after rekeying.
- **Transport agnostic** – the overlay only requires ordered, reliable delivery
  and therefore works for HTTP/2, WebSocket, isolates, TURN, etc.

## Dependencies and key material

1. Add Licensify to any package that instantiates transports:

   ```dart
   dependencies:
     licensify: ^3.1.0
   ```

2. Generate long-term signing keys once and persist them next to the endpoint
   configuration:

   ```dart
   final keys = await Licensify.generateSigningKeys();
   await savePrivateKey(keys.privateKeyBytes);
   await savePublicKey(keys.publicKeyBytes);
   ```

   The public portion is shared out-of-band (service discovery, config push)
   while the private key never leaves the endpoint.

## Handshake using Licensify tokens

The handshake rides on stream `0` before any RPC payloads. All messages are
Licensify licenses with a five minute TTL to guard against replay.

```text
Caller                                      Responder
------                                      ---------
Long-term signing key KC                    Long-term signing key KR
Shared public keys Pc (caller), Pr (resp)   Shared public keys Pc, Pr

1. SecureHello = Licensify.createLicense(
     privateKey: KC.priv,
     appId: 'rpc.secure',
     expirationDate: now + 5 minutes,
     type: LicenseType.standard,
     features: {
       'protocol': 'rpc+secure/1',
       'nonce': base64(nc),
     },
     metadata: {
       'seed': base64(sc),          // 32 random bytes
       'transportId': callerTransportId,
     },
   )
   ->
                                             validate using Pc
                                             extract `sc`, `nc`
                                             derive hc = HKDF(sc || nc, 'rpc:handshake:caller')
                                             pick sr (32 random bytes) and nr
                                             SecureAck = Licensify.createLicense(
                                               privateKey: KR.priv,
                                               appId: 'rpc.secure',
                                               expirationDate: now + 5 minutes,
                                               type: LicenseType.standard,
                                               features: {
                                                 'protocol': 'rpc+secure/1',
                                                 'nonce': base64(nr),
                                               },
                                               metadata: {
                                                 'seed': base64(sr),
                                                 'peerNonce': base64(nc),
                                               },
                                             )
2. <- SecureAck
   validate using Pr
   ensure `metadata.peerNonce` matches `nc`
   derive hr = HKDF(sc || sr || nr, 'rpc:handshake:responder')

3. Both sides compute the final session keys once both messages are verified:
   sendKeyBytes = HKDF(sc || sr || nc || nr, 'rpc:data:send' || role)
   recvKeyBytes = HKDF(sc || sr || nc || nr, 'rpc:data:recv' || role)
   sendKey = Licensify.encryptionKeyFromBytes(sendKeyBytes)
   recvKey = Licensify.encryptionKeyFromBytes(recvKeyBytes)
```

- Licensify guarantees authenticity of `SecureHello` and `SecureAck`.
- Random nonces prevent replay and tie responses to the initiating hello.
- Handshake state is wiped from memory after the session keys are derived.

## Frame protection

Each subsequent frame is sealed as a PASETO v4.local token. The overlay keeps a
monotonic `sequence` per direction, encodes the original frame bytes as
Base64, and relies on Licensify to manage nonces and authentication tags
internally. The `handshakeTranscriptHash` value can be any digest that covers
both handshake tokens (for example `SHA256(SecureHello || SecureAck)`) so that
frames are cryptographically tied to the negotiated session:

```dart
final frameBytes = codec.encode(originalFrame);
final assertion = base64Encode(handshakeTranscriptHash);
final token = await Licensify.encryptData(
  data: {
    'payload': base64Encode(frameBytes),
    'transportId': transportId,
    'streamId': streamId,
    'protocol': 'rpc+secure/1',
    'sequence': sequence,
  },
  encryptionKey: sendKey,
  implicitAssertion: assertion,
);
```

- The returned token string is transmitted instead of the raw frame bytes. The
  invariant fields (`transportId`, protocol version, stream ID, sequence) travel
  inside the token so the recipient can validate them before decoding.
- The responder calls `await Licensify.decryptData` with the matching
  `recvKey` and the same implicit assertion. It rejects the frame if the token
  fails integrity checks or if the decoded metadata does not match the expected
  transport context.
- A successful decryption yields a `Map<String, dynamic>`; decode the
  Base64-encoded payload to recover the original frame bytes:

  ```dart
  final decoded = await Licensify.decryptData(
    encryptedToken: token,
    encryptionKey: recvKey,
    implicitAssertion: assertion,
  );
  final restoredFrame = codec.decode(base64Decode(decoded['payload'] as String));
  ```
- After the session ends, dispose of the symmetric keys with
  `sendKey.dispose()` / `recvKey.dispose()` to wipe them from memory.

## Rekeying and rotation

- Session keys expire after a configurable number of frames or time window
  (default: 12 hours). Either side starts a background handshake on a control
  stream while suspending application streams.
- To rotate long-term identities, publish the new Licensify public key and cache
  the previous ones for a grace period. As soon as the peer accepts the new key
  the secure overlay seamlessly continues.

## Implementation checklist

1. Introduce a `SecureChannelNegotiator` and `SecureTransportAdapter` pair that
   sits between transports and wraps all outbound/inbound frames after the
   Licensify handshake succeeds.
2. Provide unit tests covering:
   - successful negotiation over each bundled transport;
   - rejection when validating Licensify tokens with the wrong public key;
   - re-handshake after triggering a key rotation.
3. Expose metrics: handshake duration, rejected handshakes, frame failures,
   rekey counts.

## Developer experience

```dart
final baseCaller = await RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);
final secureCaller = SecureTransportAdapter.wrap(
  baseCaller,
  keyStore: callerKeyStore,
);

final baseResponder = RpcWebSocketResponderTransport(channel);
final secureResponder = SecureTransportAdapter.wrap(
  baseResponder,
  keyStore: responderKeyStore,
);
```

Wrapping the transport opt-in enables the Licensify handshake and exposes an
authenticated, encrypted channel before any RPC payload is sent. The same
adapter can wrap isolate pipes, HTTP/2 streams, or any custom transport that
implements the shared interface.
