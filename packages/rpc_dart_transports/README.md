<div style="text-align: center;">
  <h1>
    <p>RPC Dart - Transports</p>
  </h1>
</div>

Transport implementations for [RPC Dart](https://pub.dev/packages/rpc_dart). Provides ready transports.

### Core concepts

- Transport — concrete implementation of the IRpcTransport interface.
- Client/Server transports — client-side connectors and server-side handlers.
- Multiplexing — many RPCs over one connection where supported.
- Zero-copy — supported where transport permits in-process object transfer.

### Supported transports

- WebSocketTransport — bidirectional real-time transport with reconnection and optional multiplexing.
- IsolateTransport — efficient communication between Dart isolates, supports zero-copy for in-process objects.
- Http2Transport — HTTP/2 based transport with gRPC-compatible framing, TLS support and stream multiplexing.
