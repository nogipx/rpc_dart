// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'errors.dart';
import 'health.dart';
import 'metadata.dart';
import 'security_policy.dart';

/// Transport-layer message with Stream ID support.
///
/// Represents payload and metadata traveling over a transport and bound to a
/// specific HTTP/2 stream (an RPC call).
///
/// ZERO-COPY OPTIMIZATION: Supports passing objects directly without
/// serialization for in-memory transports.
final class RpcTransportMessage {
  /// Serialized payload bytes.
  final Uint8List? payload;

  /// ZERO-COPY: Direct reference to an object (for in-memory transport).
  /// Use only inside a single process.
  /// Object must be immutable or cloned.
  final Object? directPayload;

  /// Associated metadata.
  final RpcMetadata? metadata;

  /// Whether this is the final message in the stream.
  final bool isEndOfStream;

  /// Method path in `/ServiceName/MethodName` format.
  final String? methodPath;

  /// HTTP/2 stream identifier for this RPC call.
  final int streamId;

  /// True when the message contains only metadata.
  bool get isMetadataOnly =>
      metadata != null && payload == null && directPayload == null;

  /// True when a direct object is being sent (zero-copy optimization).
  bool get isDirect => directPayload != null;

  /// True when serialized bytes are present.
  bool get isSerialized => payload != null;

  /// Charged per header on top of its characters — see [bufferedBytes].
  ///
  /// A header is an [RpcHeader] object plus two Strings, and a queue retains all
  /// three. Measured at three scales, filling the queue with metadata frames of
  /// 500, 2000 and 5000 tiny headers: 97, 103 and 111 bytes of resident memory
  /// per header. 64 is under every one of them deliberately — a floor that holds
  /// when a different runtime lays objects out differently — and it costs a
  /// legitimate ten-header frame 640 bytes against a 16 MiB bound.
  static const int _perHeaderOverheadBytes = 64;

  /// What this message weighs while it is held in a queue, in bytes.
  ///
  /// One home for the rule, because every transport buffers these and each
  /// would otherwise repeat it. A `directPayload` is a reference to an object
  /// this process already owns, so queuing it costs a pointer rather than its
  /// contents.
  ///
  /// Used by `BufferedBroadcastController.sizeOf`, whose bound was on event
  /// COUNT alone — 4096 events of up to `maxMessageLengthBytes` each.
  ///
  /// Metadata is counted too, and used not to be. "Small and bounded by the
  /// policy's header limits" is true per frame and false in aggregate:
  /// `maxMetadataBytes` defaults to 64 KiB, so 4096 metadata-only frames
  /// retained 256 MiB against this queue's 16 MiB bound — the same
  /// count-versus-bytes hole round 236 closed for payloads, left open in the
  /// dimension it excluded.
  int get bufferedBytes {
    var total = payload?.length ?? 0;
    final m = metadata;
    if (m != null) {
      // Characters ALONE are not what a header costs. Round 245 stopped
      // metadata weighing zero here; it then weighed `name.length +
      // value.length`, which is right for a few large headers and wrong for
      // many small ones -- and many small ones is the shape a peer picks.
      // ["h1","v1"] weighs 4 and retains about a hundred bytes.
      //
      // Measured against this queue, one arm per process, maxRss:
      //
      //   arm      headers  admitted   wire  weighed     RSS   stopped by
      //   payload        -       256   16.0     16.0    37.3   the byte bound
      //   thin         500      4096   30.4     14.8   190.8   the EVENT count
      //   thin        2000       943   30.4     16.0   186.4   the byte bound
      //   thin        5000       351   29.4     16.0   186.3   the byte bound
      //
      // A plateau at ~186 MiB against a 16 MiB bound, at every scale, while the
      // payload arm -- weighed correctly -- sits at 2.3x. At 500 headers the
      // byte bound did not engage AT ALL: the event count stopped it, which is
      // the hole round 236 closed for payloads reopening one dimension over.
      for (final h in m.headers) {
        total += h.name.length + h.value.length + _perHeaderOverheadBytes;
      }
    }
    return total;
  }

  /// Creates a transport message.
  RpcTransportMessage({
    this.payload,
    this.directPayload,
    this.metadata,
    this.isEndOfStream = false,
    this.methodPath,
    required this.streamId,
  }) {
    if (payload != null && directPayload != null) {
      throw ArgumentError('Specify either payload or directPayload, not both');
    }
  }

  /// Factory for serialized-payload message (standard mode).
  factory RpcTransportMessage.withPayload({
    required Uint8List payload,
    RpcMetadata? metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    payload: payload,
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );

  /// Factory for direct-object message (zero-copy mode).
  factory RpcTransportMessage.withDirectObject({
    required Object directPayload,
    RpcMetadata? metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    directPayload: directPayload,
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );

  /// Factory for metadata-only message.
  factory RpcTransportMessage.withMetadata({
    required RpcMetadata metadata,
    bool isEndOfStream = false,
    String? methodPath,
    required int streamId,
  }) => RpcTransportMessage(
    metadata: metadata,
    isEndOfStream: isEndOfStream,
    methodPath: methodPath,
    streamId: streamId,
  );
}

/// Capability for transports that can abort a single stream out-of-band.
///
/// The four `IRpc*` capabilities below are deliberately SEPARATE from
/// [IRpcTransport]: a third-party transport that `implements IRpcTransport`
/// must keep compiling when one is added. Callers probe with `is` and fall back
/// to a safe default, so not implementing one is always allowed.
///
/// Implement this where a real abort primitive exists (HTTP/2 RST_STREAM). The
/// fallback — a `grpc-status: CANCELLED` metadata frame — is only legal while
/// this side is still open, and at cancellation time it usually is not: HTTP/2
/// then throws "Open state expected (was: HalfClosedLocal)" asynchronously,
/// where no caller can catch it, and the connection is corrupted.
abstract interface class IRpcStreamReset {
  /// Aborts [streamId], returning true when the reset was delivered.
  ///
  /// Returning false means "not resettable" (e.g. the stream is unknown) and
  /// the caller should fall back to the metadata notice.
  Future<bool> resetStream(int streamId, {String? reason});
}

/// Capability for transports that carry an [RpcSecurityPolicy].
///
/// Lets the layers above honour the limits the application already configured
/// instead of adding a second knob for the same concept. Not implementing it
/// means those layers use `const RpcSecurityPolicy()` — the defaults, not "no
/// limits". See [IRpcStreamReset] for why this is a separate interface.
abstract interface class IRpcSecurityPolicyAware {
  /// The policy this transport was configured with.
  RpcSecurityPolicy get securityPolicy;
}

/// Capability for transports whose stream-id sequence can be CONTINUED.
///
/// `RpcClientConnection` builds a WHOLE NEW transport on reconnect, and a fresh
/// one starts its ids at 1 — so the first call afterwards gets the id a call
/// from the old connection still holds. Since the id is all a release or a
/// half-close presents, nothing downstream can tell them apart: measured, a
/// dead call's late `finishSending` half-closed the live one and the server
/// finished serving it.
///
/// **The cursor must survive [IRpcTransport.close].** A reconnect is usually
/// started by the peer, and a transport learns that by closing itself, so a
/// cursor destroyed at close is gone before anything above can read it — and
/// there is no earlier moment to read it at.
///
/// See [IRpcStreamReset] for why this is a separate interface.
abstract interface class IRpcStreamIdSequence {
  /// The highest stream id handed out so far, or a value below the first
  /// assignable id when none has been.
  int get lastIssuedStreamId;

  /// Continues the sequence after [streamId].
  ///
  /// Must only ever move the cursor FORWARD, and must leave parity intact:
  /// a client transport still issues odd ids afterwards, a server even ones.
  /// Safe to call with a value from a different transport instance; that is the
  /// entire point.
  void resumeStreamIdsAfter(int streamId);
}

/// Capability: a higher layer takes over flow-control metering for a stream.
///
/// The transport meters what it hands out through `getMessagesForStream`,
/// lazily, so a consumer that stops reading stops credit reaching the peer. A
/// client-stream handler is fed by the responder pipeline instead, so the
/// transport sees nothing to meter and would have to credit on arrival —
/// leaving that direction unbounded.
///
/// Once [deferFlowCredit] is called, [returnFlowCredit] MUST be called as the
/// application consumes, or the peer stalls when the window runs out.
///
/// See [IRpcStreamReset] for why this is a separate interface.
abstract interface class IRpcFlowControlled {
  /// Hands metering of [streamId] to the caller.
  void deferFlowCredit(int streamId);

  /// Reports [bytes] consumed by the application on [streamId].
  void returnFlowCredit(int streamId, int bytes);
}

/// Transport interface with Stream ID multiplexing.
///
/// Contract for transports over different protocols (HTTP/2, WebSockets,
/// isolates, etc.) that multiplex by Stream ID per gRPC spec.
abstract class IRpcTransport {
  /// True for client transport (generates odd Stream IDs), false for server
  /// transport (even Stream IDs).
  bool get isClient;

  /// Returns true when the transport has been closed.
  bool get isClosed;

  /// Whether the transport supports zero-copy operations (sendDirectObject).
  ///
  /// Helps avoid explicit type checks for transports.
  bool get supportsZeroCopy => false;

  /// Creates a new HTTP/2 stream for an RPC call.
  ///
  /// Returns a unique Stream ID that will be used for all messages of the call.
  int createStream();

  /// Releases a stream ID so it can be reused later.
  ///
  /// Called after a stream finishes and its resources are cleared.
  bool releaseStreamId(int streamId);

  /// Sends metadata for a stream.
  ///
  /// [streamId] HTTP/2 stream identifier.
  /// [metadata] Metadata to send.
  /// [endStream] Whether to end the stream after sending.
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  });

  /// Sends a framed message for a stream.
  ///
  /// [streamId] HTTP/2 stream identifier.
  /// [data] gRPC frame bytes (5-byte prefix + payload).
  /// [endStream] Whether to end the stream after sending.
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  });

  /// ZERO-COPY: Sends an object directly without serialization (optional).
  ///
  /// Not supported by default. Only transports with `supportsZeroCopy = true`
  /// override this to truly pass objects by reference. Check
  /// `transport.supportsZeroCopy` before calling.
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError(
      'Transport does not support direct object transfer. '
      'Use sendMessage() with serialization or a zero-copy capable transport.',
    );
  }

  /// Stream of all incoming messages from the remote side.
  ///
  /// Merges incoming metadata and data into a single stream; each entry carries
  /// the Stream ID for routing.
  Stream<RpcTransportMessage> get incomingMessages;

  /// Returns a filtered stream for a specific stream ID.
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  /// Finishes sending data for a stream.
  Future<void> finishSending(int streamId);

  /// Closes the transport connection and releases resources.
  Future<void> close();

  /// Checks transport health and returns diagnostics.
  Future<RpcHealthStatus> health();

  /// Attempts to restore transport connectivity. If unsupported, return a
  /// status with [RpcHealthLevel.degraded] or [RpcHealthLevel.unhealthy] and
  /// `supported: false` in details.
  Future<RpcHealthStatus> reconnect();
}

/// Stream ID manager for HTTP/2 connections.
///
/// Generates and tracks stream IDs per HTTP/2 (RFC 7540):
/// - Clients use odd IDs (1, 3, 5…)
/// - Servers use even IDs (2, 4, 6…)
/// - ID 0 is reserved for connection control
/// - Max ID is 2^31-1 (2,147,483,647)
///
/// When the max ID is reached, released IDs are reused if available; otherwise
/// [RpcException] is thrown and the transport must wait or reconnect.
final class RpcStreamIdManager {
  /// Maximum allowed ID (2^31-1).
  static const int maxId = 0x7FFFFFFF; // 2,147,483,647

  /// Determines role (client/server) for ID generation.
  final bool isClient;

  /// Last generated ID.
  int _lastId;

  /// Upper bound considering parity.
  final int _maxAssignableId;

  /// First valid ID for the role (1 for client, 2 for server).
  final int _firstAssignableId;

  /// Active IDs in use.
  final SplayTreeSet<int> _activeIds = SplayTreeSet<int>();

  /// Creates an ID manager for a given role.
  ///
  /// [isClient] True to generate client (odd) IDs; false for server (even).
  /// [customMaxId] Optional custom upper bound (tests, specialized transports).
  /// [resumeAfter] Continue an existing sequence instead of starting over —
  ///   pass a previous manager's [lastIssuedId]. Values below the natural start
  ///   are ignored, so `resumeAfter: -1` and `resumeAfter: null` behave alike,
  ///   and a value of the wrong parity cannot be produced by [lastIssuedId].
  RpcStreamIdManager({
    required this.isClient,
    int? customMaxId,
    int? resumeAfter,
  }) : _lastId = (resumeAfter != null && resumeAfter > (isClient ? -1 : 0))
           ? resumeAfter
           : (isClient ? -1 : 0),
       _firstAssignableId = isClient ? 1 : 2,
       _maxAssignableId = _computeMaxAssignableId(
         isClient: isClient,
         maxIdOverride: customMaxId,
       );

  /// Computes the upper ID bound respecting parity.
  static int _computeMaxAssignableId({
    required bool isClient,
    int? maxIdOverride,
  }) {
    final effectiveMax = maxIdOverride ?? maxId;
    final adjustedMax = isClient
        ? (effectiveMax.isOdd ? effectiveMax : effectiveMax - 1)
        : (effectiveMax.isEven ? effectiveMax : effectiveMax - 1);

    if (adjustedMax < (isClient ? 1 : 2)) {
      throw ArgumentError.value(
        effectiveMax,
        'customMaxId',
        'Not enough valid Stream IDs available for this role',
      );
    }

    return adjustedMax;
  }

  /// Generates a new unique stream ID.
  ///
  /// Throws if the maximum ID is reached and no reusable IDs exist.
  int generateId() {
    // Compute next ID based on role.
    final nextId = _lastId + 2;

    if (nextId <= _maxAssignableId) {
      _lastId = nextId;
      _activeIds.add(nextId);
      return nextId;
    }

    // If no active streams, safely restart the sequence.
    if (_activeIds.isEmpty) {
      final restartId = _firstAssignableId;
      _lastId = restartId;
      _activeIds.add(restartId);
      return restartId;
    }

    final recycledId = _findReusableId();
    if (recycledId == null) {
      throw RpcException(
        'All $_sideLabel Stream IDs are in use. '
        'Wait for active streams to finish or establish a new connection.',
      );
    }

    _activeIds.add(recycledId);
    return recycledId;
  }

  /// Releases an ID after stream completion.
  bool releaseId(int streamId) {
    return _activeIds.remove(streamId);
  }

  /// Returns true if the ID is currently active.
  bool isActive(int streamId) {
    return _activeIds.contains(streamId);
  }

  /// Number of active IDs.
  int get activeCount => _activeIds.length;

  /// The highest id handed out so far, for a transport that has to CONTINUE
  /// this sequence on a fresh connection rather than restart it.
  ///
  /// A reconnecting transport builds a new manager, and a new manager starts
  /// over at 1 — so the call that opens after a reconnect gets the id a dead
  /// call held before it. The dead call's teardown then acts on the live one:
  /// measured over websocket, a late `finishSending` for the old id
  /// HALF-CLOSED the new call's request stream and the server finished serving
  /// it. Seeding a new manager from this value makes the two id spaces
  /// disjoint, which is the only thing that can distinguish them — the id is
  /// all a teardown has to present.
  ///
  /// Reads as the manager's own "last generated" cursor, so
  /// `RpcStreamIdManager(isClient: ..., resumeAfter: old.lastIssuedId)`
  /// round-trips exactly.
  int get lastIssuedId => _lastId;

  /// Moves the cursor forward so the next id follows [streamId].
  ///
  /// Only ever forward: a stale or lower value is ignored, so calling this with
  /// a watermark collected from several previous connections is safe in any
  /// order. Parity is preserved — a value of the wrong parity for this role is
  /// rounded UP to the next valid one, so a client manager keeps issuing odd
  /// ids whatever it is handed.
  void resumeAfter(int streamId) {
    if (streamId <= _lastId) return;
    final aligned = streamId.isOdd == isClient ? streamId : streamId + 1;
    _lastId = aligned > _maxAssignableId ? _maxAssignableId : aligned;
  }

  /// Frees every active id, keeping the [lastIssuedId] cursor.
  ///
  /// What a transport wants at close: the ids are no longer in use, but the
  /// sequence they came from is exactly what a reconnecting wrapper needs
  /// afterwards. [reset] rewinds the cursor as well, and using it here meant a
  /// transport that closed ITSELF — which is how every peer-started drop is
  /// reported — erased the cursor before anything above could read it.
  void releaseAll() {
    _activeIds.clear();
  }

  /// Resets manager state (clears active IDs and rewinds the cursor).
  ///
  /// Starts the id space over, so anything holding an id from before now shares
  /// a namespace with new calls. Use [releaseAll] to end the calls without that.
  void reset() {
    _activeIds.clear();
    _lastId = isClient ? -1 : 0;
  }

  String get _sideLabel => isClient ? 'client' : 'server';

  int? _findReusableId() {
    var candidate = _firstAssignableId;

    for (final activeId in _activeIds) {
      if (candidate < activeId) {
        return candidate;
      }

      if (candidate == activeId) {
        candidate = _advanceCandidate(activeId);
      }
    }

    if (!_activeIds.contains(candidate)) {
      return candidate;
    }

    return null;
  }

  int _advanceCandidate(int current) {
    final next = current + 2;
    if (next > _maxAssignableId) {
      return _firstAssignableId;
    }
    return next;
  }
}
