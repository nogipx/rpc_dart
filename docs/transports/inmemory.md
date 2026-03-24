# InMemory Transport

`RpcInMemoryTransport` is a bidirectional in-process transport. Both sides of a connection live in the same Dart isolate — no sockets, no serialization, no ports. It is the default transport for unit tests and for co-located services that run in the same process.

---

## Creating a Pair

```dart
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
```

`pair()` returns two connected transports. Messages sent to one arrive on the other. The returned record is ordered `(caller, responder)`.

---

## Zero-Copy Transfer

`RpcInMemoryTransport` reports `supportsZeroCopy == true`. When both sides use the same transport pair, the endpoint skips serialization and passes objects directly by reference — no CBOR encoding, no memory copies. This makes in-process calls as fast as a plain Dart function call.

Zero-copy activates automatically when no codec is provided and the transport supports it. You can also use it explicitly with `RpcDataTransferMode.zeroCopy` contracts (the default for generated code).

---

## Usage

### Testing

The primary use case is fast, hermetic unit tests — no network setup, teardown in microseconds:

```dart
late CalculatorContractCaller caller;
late RpcResponderEndpoint server;

setUp(() {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  server = RpcResponderEndpoint(transport: responderTransport);
  server.registerServiceContract(CalculatorResponder());
  server.start();

  caller = CalculatorContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
  );
});

tearDown(() async {
  await caller.endpoint.close();
  await server.close();
});
```

### Co-located Services

For services that run in the same process (e.g., a plugin architecture or a monolith with logical service boundaries):

```dart
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

final authServer = RpcResponderEndpoint(transport: responderTransport);
authServer.registerServiceContract(AuthResponder());
authServer.start();

// Another part of the app holds the caller transport
final authClient = AuthContractCaller(
  RpcCallerEndpoint(transport: callerTransport),
);
```

---

## Notes

- Compression is automatically disabled for InMemory transport — zero-copy makes it pointless.
- Both transports share a `StreamController` pair; closing either side closes both.
- `supportsZeroCopy` returns `true` only on `RpcInMemoryTransport`. All network transports return `false`.