// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'transport.dart';

/// Multiplexed message channel -- sits between a raw transport and [IRpcTransport].
///
/// Converts between a transport-specific wire format and [RpcTransportMessage].
/// Stream ID management, security policy, and health checks are handled by
/// [RpcChannelTransport] which wraps this interface.
///
/// Built-in implementations:
/// - `RpcFrameMultiplexedChannel` wraps an [IRpcChannel] with frame encoding
/// - `RpcDirectMultiplexedChannel` passes messages directly (zero-copy)
abstract class IRpcMultiplexedChannel {
  /// Whether the channel has been closed.
  bool get isClosed;

  /// Whether the channel supports zero-copy message passing.
  bool get supportsZeroCopy => false;

  /// Incoming messages from all streams, already decoded.
  Stream<RpcTransportMessage> get incoming;

  /// Send a message to the remote side.
  ///
  /// **A send on a CLOSED channel returns normally and delivers nothing.** Both
  /// shipped implementations do this -- `if (_closed) return` -- so it is the
  /// convention rather than one channel's quirk, and it means the future
  /// completing is not evidence the peer received anything. Measured on the direct
  /// channel after the peer closed: `the send returned normally / the peer received
  /// [] / our isClosed true`.
  ///
  /// Callers that need to know go through [RpcChannelTransport], which throws
  /// `RpcClosedException` from its own `sendMessage` instead. A channel used
  /// directly has only [isClosed] to check.
  Future<void> send(RpcTransportMessage message);

  /// Close the channel and release resources.
  ///
  /// **Asymmetric, and the CLOSING side is the one that loses.** What this side had
  /// already queued is still delivered; what the peer had queued toward us is
  /// dropped, because closing cancels the inbound subscription. Measured with both
  /// ends queuing a frame in the same turn and the client closing:
  /// `the client received [] / the server received [from-client]`, mirrored when the
  /// server closes.
  ///
  /// Kept deliberately rather than fixed. Delivering that queued inbound needs an
  /// event-loop turn before the cancel, and the turn delays the close CASCADE —
  /// the peer's `onDone`, its channel, its transport — so a peer's `sendMessage`
  /// right after `await close()` stopped throwing and started succeeding silently.
  /// Of the two losses that is the worse one. A side that wants the peer's last
  /// frames must read them before closing.
  Future<void> close();
}
