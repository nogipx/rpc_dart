# Streaming patterns

RPC Dart treats streaming as a first-class citizen. The same contract-based API
covers all gRPC patterns while giving you fine-grained control over
serialisation, cancellation, and flow control.

## Overview

- **Unary** – single request, single response. Returns `Future<T>` on both sides.
- **Server streaming** – single request, multiple responses. Returns `Stream<T>`
  to the caller.
- **Client streaming** – multiple requests, single response. Caller sends a
  `Stream<T>`.
- **Bidirectional** – full-duplex messaging. Both sides use `Stream<T>`
  concurrently.

## Declaring streaming methods

```dart
class ChatContract extends RpcResponderContract {
  ChatContract() : super('Chat');

  @override
  void setup() {
    addServerStreamMethod<JoinRequest, ChatMessage>(
      methodName: 'JoinRoom',
      handler: _joinRoom,
    );

    addBidirectionalMethod<ClientEvent, ChatMessage>(
      methodName: 'LiveChat',
      handler: _liveChat,
    );
  }

  Stream<ChatMessage> _joinRoom(JoinRequest request, {RpcContext? context}) {
    return chatRooms.openStream(request.roomId, request.userId);
  }

  Stream<ChatMessage> _liveChat(
    Stream<ClientEvent> events, {
    RpcContext? context,
  }) {
    return liveChatBroker.connect(events, context: context);
  }
}
```

On the caller side you get symmetrical helpers:

```dart
class ChatCaller extends RpcCallerContract {
  ChatCaller(RpcCallerEndpoint endpoint) : super('Chat', endpoint);

  Stream<ChatMessage> joinRoom(String roomId, String userId) {
    return callServerStream<JoinRequest, ChatMessage>(
      methodName: 'JoinRoom',
      request: JoinRequest(roomId, userId),
    );
  }

  Stream<ChatMessage> liveChat(Stream<ClientEvent> events) {
    return callBidirectionalStream<ClientEvent, ChatMessage>(
      methodName: 'LiveChat',
      requests: events,
    );
  }
}
```

## Flow control essentials

### Deadlines & cancellation

Any `RpcContext` passed to streaming calls is propagated to processors. When
the deadline expires or the cancellation token is triggered the caller and
responder terminate the stream gracefully.

### Backpressure

Streams use Dart's async primitives, so the responder honours pause/resume
signals from the caller. The built-in processors buffer minimally, letting you
compose with `StreamTransformer`s for custom flow control.

### Zero-copy streaming

When you omit codecs in `add*StreamMethod` and the transport supports
`supportsZeroCopy`, RPC Dart forwards objects by reference even for streams –
ideal for high-frequency in-process messaging.

## Managing server-side fan-out with `StreamDistributor`

`StreamDistributor<T>` simplifies building broadcast or multi-subscriber
channels on top of streaming RPCs. Declare events that implement
`IRpcSerializable` so they work with both zero-copy and codec-based transports.

```dart
final distributor = StreamDistributor<ChatMessage>();

Stream<ChatMessage> connectClient(String clientId) {
  return distributor.getOrCreateClientStream(clientId);
}

void publishToRoom(ChatMessage message) {
  distributor.publish(message, metadata: {
    'roomId': message.roomId,
    'sender': message.senderId,
  });
}
```

Key capabilities:

- Automatic cleanup of inactive client streams.
- Targeted delivery via `publishFiltered` to specific clients.
- Metrics via `distributor.metrics` (total/current streams, total messages,
  average message size).
- Optional logging hooks for visibility.

## Testing streaming logic

The `RpcInMemoryTransport` makes it trivial to test streaming handlers without a
network stack:

```dart
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
final responder = RpcResponderEndpoint(transport: serverTransport)
  ..registerServiceContract(ChatContract())
  ..start();
final caller = RpcCallerEndpoint(transport: clientTransport);

final chat = ChatCaller(caller);
final stream = chat.joinRoom('general', 'u-42');

expectLater(stream, emitsThrough(predicate<ChatMessage>((msg) => msg.roomId == 'general')));
```

Because the in-memory transport supports zero-copy, the exact objects your
handler emits are the ones received by the client—perfect for verifying complex
state transitions without serialisation noise.

Streaming RPCs let you build collaborative apps, background workers, and live
updates without switching frameworks. RPC Dart keeps the API ergonomic while
letting you opt into advanced features only when you need them.
