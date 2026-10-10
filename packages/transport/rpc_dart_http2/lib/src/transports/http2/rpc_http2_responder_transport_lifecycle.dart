// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_responder_transport.dart';

extension _Http2ResponderLifecycle on RpcHttp2ResponderTransport {
  /// Subscribes to the connection's incoming client streams.
  void _setupConnectionListener() {
    _connection.incomingStreams.listen(
      _handleIncomingStream,
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'HTTP/2 connection error',
          error: error,
          stackTrace: stackTrace,
        );

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        // `incomingStreams` completing means NO MORE NEW STREAMS -- it does not
        // mean the connection is closed, and treating it as such killed every
        // call still running.
        //
        // package:http2 completes this stream from `onClosing()`, which fires
        // on GOAWAY (its `_finishing`) as well as on a real teardown. GOAWAY is
        // the ordinary graceful-shutdown signal -- a peer draining, a proxy
        // recycling a connection, a load balancer rotating a backend -- and its
        // whole point is that streams already open are allowed to FINISH.
        // Closing here answers "please stop starting new work" with "everything
        // in flight dies now", which also defeats this server's own drain.
        //
        // So: stop accepting, and close only once the last open stream is done.
        // A genuinely dead connection still closes promptly, because its
        // streams end too (and `socket.done` closes the endpoint regardless).
        _logger?.internal(
          'HTTP/2: no further incoming streams (GOAWAY or connection close)',
        );
        _acceptingStreams = false;
        _closeIfDrained();
      },
    );
  }

  /// Closes the transport once no stream is left to serve.
  ///
  /// Only meaningful after [_acceptingStreams] goes false: before that, an
  /// empty stream table is just an idle connection.
  void _closeIfDrained() {
    if (_acceptingStreams || _isClosed) return;
    if (_incomingStreams.isNotEmpty) return;
    _logger?.internal('HTTP/2: last stream drained, closing transport');
    close();
  }

  /// Ends the connection after a policy violation, when the policy asks for it.
  Future<void> _closeForProtocolError() async {
    if (_isClosed) return;
    try {
      await _connection.terminate();
    } catch (e) {
      _logger?.warning('Protocol-error close failed: $e');
    }
  }

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'incomingStreams': _incomingStreams.length,
    'streamSubscriptions': _streamSubscriptions.length,
    'streamParsers': _streamParsers.length,
    // The per-stream collection that had no observable. It holds a writer
    // parked on the peer's window, so it is the one whose growth costs most,
    // and its pruning could only be argued from sharing a line with
    // `_incomingStreams` in releaseStreamId.
    'outgoingPumps': _outgoingPumps.length,
    'messageControllerClosed': _messageController.isClosed,
  };
}
