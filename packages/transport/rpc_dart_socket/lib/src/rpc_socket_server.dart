// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/transport.dart';

import 'rpc_socket_address.dart';
import 'rpc_socket_channel.dart';
import 'rpc_socket_connect.dart';

/// rpc_dart server on a Unix domain socket or a TCP port.
///
/// Owns its listening socket: [start] binds it, [stop] closes it, and a later
/// [start] binds again. Each accepted connection gets its own endpoint over
/// [RpcChannelTransport] and [RpcSocketChannel].
///
/// ```dart
/// final server = RpcSocketServer.createWithContracts(
///   address: const RpcSocketAddress.unix('/tmp/app/rpc.sock'),
///   contracts: [MyResponder()],
/// );
/// await server.start();
/// ```
///
/// **A stale Unix socket file is replaced.** A running server holds an
/// exclusive lock on a file beside its socket, `<path>.lock`. [start] takes
/// that lock first, and throws a [SocketException] if a running server holds
/// it or the lock file cannot be created. Holding the lock, it may find a
/// socket file a crashed server left behind: if a connect to it is refused,
/// the file is deleted and the bind retried. A path that is not a socket is
/// left alone and [start] throws.
///
/// The lock belongs to the process, so two isolates of one process serving
/// one path are not told apart; use one path per process.
///
/// A clean [stop] removes both the socket file and the lock file.
class RpcSocketServer extends IRpcServer {
  /// Creates a server for [address]. Nothing is bound until [start].
  ///
  /// [maxConnections] caps concurrent connections, those still in their
  /// handshake included; a connection past it is closed at once, which its
  /// caller reports as UNAVAILABLE. Null means no cap.
  ///
  /// [prefaceTimeout] bounds how long an accepted socket may take to send its
  /// preface (see `RpcFrameMultiplexedChannel.ready`). No endpoint exists
  /// before it arrives,
  /// so a peer that connects and stays silent costs a socket for this long
  /// and no more. Null waits for ever.
  ///
  /// [mode] says what each connection gets: [RpcResponderMode] for a
  /// responder endpoint, [RpcPeerMode] for a peer one, where both sides may
  /// start calls.
  RpcSocketServer({
    required RpcSocketAddress address,
    required RpcServerMode mode,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? maxConnections,
    Duration? prefaceTimeout = const Duration(seconds: 10),
    LogScope? logger,
    LogController? logController,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(RpcSocketChannel channel)? onConnectionOpened,
    void Function(RpcSocketChannel channel)? onConnectionClosed,
  }) : _address = address,
       _policy = policy,
       _prefaceTimeout = prefaceTimeout,
       _log = logger?.child('SocketServer') ?? LogScope.noop,
       _host = RpcConnectionHost(
         mode: mode,
         maxConnections: maxConnections,
         logger: logger?.child('SocketServer'),
         logController: logController,
       ),
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed;

  /// A server that registers [contracts] on every connection.
  factory RpcSocketServer.createWithContracts({
    required RpcSocketAddress address,
    required List<RpcResponderContract> contracts,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    int? maxConnections,
    Duration? prefaceTimeout = const Duration(seconds: 10),
    LogScope? logger,
    LogController? logController,
  }) {
    return RpcSocketServer(
      address: address,
      mode: RpcResponderMode.contracts(contracts),
      policy: policy,
      maxConnections: maxConnections,
      prefaceTimeout: prefaceTimeout,
      logger: logger,
      logController: logController,
    );
  }

  final RpcSocketAddress _address;
  final RpcSecurityPolicy _policy;
  final Duration? _prefaceTimeout;
  final LogScope _log;
  final RpcConnectionHost _host;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(RpcSocketChannel channel)? _onConnectionOpened;
  final void Function(RpcSocketChannel channel)? _onConnectionClosed;

  ServerSocket? _listener;
  StreamSubscription<Socket>? _accepting;
  bool _isRunning = false;
  int _connCounter = 0;

  /// Accepted sockets whose preface has not arrived yet. They hold no
  /// endpoint, but they do hold a socket, so they count against the cap and
  /// [stop] closes them.
  final Set<RpcSocketChannel> _handshaking = {};

  /// The address this server was created for.
  RpcSocketAddress get address => _address;

  /// The port actually bound: the free port picked for a TCP address with
  /// port 0, once started. 0 for a Unix socket, and before [start].
  int get port => _listener?.port ?? _address.port;

  /// Responder endpoints only, so empty in peer mode. See
  /// [IRpcServer.endpoints].
  @override
  List<RpcResponderEndpoint> get endpoints => _host.responders;

  @override
  bool get isRunning => _isRunning;

  /// Claimed synchronously by [start] before its first await, so two
  /// overlapping starts cannot both bind.
  Future<void>? _starting;

  /// The [stop] in flight, so a [start] waits for it and a second [stop] joins
  /// it.
  Future<void>? _stopping;

  /// Binds the listening socket and starts accepting.
  ///
  /// A [stop] in flight is finished first. A second [start] while one is
  /// binding joins it. Throws what the bind throws, the server left stopped,
  /// so a retry works.
  @override
  Future<void> start() async {
    final stopping = _stopping;
    if (stopping != null) await stopping;
    if (_isRunning) return;
    final inFlight = _starting;
    if (inFlight != null) return inFlight;
    final attempt = _startOnce().whenComplete(() => _starting = null);
    _starting = attempt;
    return attempt;
  }

  Future<void> _startOnce() async {
    final listener = await _bind();
    _listener = listener;
    _isRunning = true;
    _accepting = listener.listen(
      _handleConnection,
      onError: (Object error, StackTrace st) {
        _log.error('Listening socket error', error: error, stackTrace: st);
        _notify('onConnectionError', () => _onConnectionError?.call(error, st));
      },
    );
    _log.info('Listening on $_address');
  }

  Future<ServerSocket> _bind() async {
    final address = _address;
    if (address is! RpcUnixSocketAddress || _isAbstract(address.path)) {
      return ServerSocket.bind(address.host, address.port);
    }
    await _claimPath(address);
    try {
      try {
        return await ServerSocket.bind(address.host, address.port);
      } on SocketException {
        if (!await _removeStaleSocket(address.path)) rethrow;
        return await ServerSocket.bind(address.host, address.port);
      }
    } catch (_) {
      _releasePath();
      rethrow;
    }
  }

  /// Lock files of the socket paths servers in this isolate hold. The lock is
  /// per process: without this a second server here is granted the lock its
  /// neighbour holds, and closing its file on failure drops that lock.
  static final Set<String> _claimedPaths = {};

  /// The lock file [_claimPath] holds while this server owns its path.
  RandomAccessFile? _pathLock;
  String? _pathLockFile;

  /// A Linux abstract address has no file, so nothing can go stale.
  static bool _isAbstract(String path) =>
      path.startsWith('@') && (Platform.isLinux || Platform.isAndroid);

  /// Takes the exclusive lock on `<path>.lock`, held until [_releasePath].
  ///
  /// The lock, not a probe connect, is what tells a live server from a dead
  /// one: a live server whose accept queue is full refuses connects exactly
  /// like a dead one, and then its file would be deleted under it.
  Future<void> _claimPath(RpcUnixSocketAddress address) async {
    final path = address.path;
    final lockFile = '${_canonicalPath(path)}.lock';
    if (!_claimedPaths.add(lockFile)) {
      throw SocketException(
        '$path is held by another server in this process',
        address: address.host,
      );
    }
    RandomAccessFile? lock;
    try {
      lock = await File(lockFile).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
    } on FileSystemException catch (e) {
      _claimedPaths.remove(lockFile);
      await lock?.close();
      throw SocketException(
        lock == null
            ? 'Cannot open the lock file $lockFile: ${e.message}'
            : '$path is held by a running server',
        osError: e.osError,
        address: address.host,
      );
    }
    _pathLock = lock;
    _pathLockFile = lockFile;
  }

  /// Deletes the lock file, then unlocks it. Deleting first means a server
  /// that starts after this creates a fresh file instead of locking the one
  /// being removed.
  void _releasePath() {
    final lock = _pathLock;
    final lockFile = _pathLockFile;
    if (lock == null || lockFile == null) return;
    _pathLock = null;
    _pathLockFile = null;
    try {
      File(lockFile).deleteSync();
    } on FileSystemException catch (e) {
      _log.warning('Cannot remove the lock file $lockFile: $e');
    }
    try {
      lock.closeSync();
    } on FileSystemException catch (e) {
      _log.warning('Cannot close the lock file $lockFile: $e');
    }
    _claimedPaths.remove(lockFile);
  }

  /// [path] with its directory's symlinks resolved, so two spellings of one
  /// path claim one entry in [_claimedPaths].
  static String _canonicalPath(String path) {
    final file = File(path);
    try {
      return '${file.parent.resolveSymbolicLinksSync()}'
          '${Platform.pathSeparator}${file.uri.pathSegments.last}';
    } on FileSystemException {
      return file.absolute.path;
    }
  }

  /// Deletes the socket file at [path] if nobody is listening on it. Called
  /// only with the path's lock held, so no server of this library owns it;
  /// the probe connect still spares a live server that takes no lock.
  ///
  /// True when the file was removed and the bind is worth retrying. A path
  /// that is not a socket is never touched: it is somebody's file.
  Future<bool> _removeStaleSocket(String path) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.unixDomainSock) {
      return false;
    }
    try {
      final probe = await Socket.connect(
        _address.host,
        0,
        timeout: const Duration(seconds: 1),
      );
      probe.destroy();
      // Somebody answered: the address is in use, not stale.
      return false;
    } on SocketException {
      // Refused: nobody is listening.
    }
    try {
      File(path).deleteSync();
    } on FileSystemException {
      return false;
    }
    _log.warning('Removed a stale socket file at $path');
    return true;
  }

  /// Stops the server, optionally letting in-flight calls finish first.
  ///
  /// The listener closes first, so new connections are refused from the
  /// start of the stop. With [drainTimeout] null every endpoint is then closed
  /// at once and a running call fails with UNAVAILABLE. With a budget the
  /// endpoints stop admitting new calls and the server waits, up to the budget,
  /// for the running ones to finish before closing them.
  @override
  Future<void> stop({Duration? drainTimeout}) {
    final starting = _starting;
    if (!_isRunning && starting == null) {
      return _stopping ?? Future<void>.value();
    }
    return _stopping ??= _stopOnce(
      starting,
      drainTimeout,
    ).whenComplete(() => _stopping = null);
  }

  Future<void> _stopOnce(Future<void>? starting, Duration? drainTimeout) async {
    // A bind in progress lands first: before it there is nothing to stop, and
    // the listener it produces would otherwise be reachable by nothing.
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        return;
      }
    }
    if (!_isRunning) return;
    _isRunning = false;

    await _accepting?.cancel();
    _accepting = null;
    try {
      await _listener?.close();
    } catch (e) {
      _log.warning('Error closing the listening socket: $e');
    }
    _listener = null;
    _releasePath();

    for (final channel in List.of(_handshaking)) {
      unawaited(channel.close());
    }
    _handshaking.clear();

    await _host.stop(drainTimeout: drainTimeout);
    _log.info('Stopped listening on $_address');
  }

  void _handleConnection(Socket socket) {
    if (!_isRunning) {
      socket.destroy();
      return;
    }
    if (!_host.admit(pending: _handshaking.length)) {
      socket.destroy();
      return;
    }

    configureRpcSocket(socket, _address);
    final channel = RpcSocketChannel(
      socket,
      maxWriteBacklogBytes: RpcWriteBacklog.defaultServerMax,
    );
    // Built now, so it reads the client's preface; the endpoint waits for it.
    final frames = RpcFrameMultiplexedChannel(
      channel: channel,
      isClient: false,
      policy: _policy,
      prefaceTimeout: _prefaceTimeout,
    );
    _handshaking.add(channel);
    frames.ready.then(
      (_) {
        if (!_handshaking.remove(channel)) return; // stop() took it
        if (!_isRunning) {
          unawaited(frames.close());
          return;
        }
        _serve(channel, frames);
      },
      onError: (Object e) {
        _handshaking.remove(channel);
        if (_log.isDebug) {
          _log.debug('Dropping ${channel.peer} before its preface: $e');
        }
      },
    );
  }

  /// Builds the endpoint for a connection whose preface has arrived.
  void _serve(RpcSocketChannel channel, RpcFrameMultiplexedChannel frames) {
    final label = 'peer-${++_connCounter}';
    _notify('onConnectionOpened', () => _onConnectionOpened?.call(channel));

    try {
      _host.serve(
        RpcChannelTransport(
          channel: frames,
          isClient: false,
          policy: _policy,
          logger: _log,
        ),
        // The channel closes on every path -- peer hang-up, read error, local
        // close -- so this is the one place a connection is released.
        done: channel.done,
        debugLabel: 'SocketEndpoint-$label',
        onRelease: () => _onConnectionClosed?.call(channel),
      );
    } catch (e, st) {
      _log.error(
        'Failed to set up connection $label',
        error: e,
        stackTrace: st,
      );
      _notify('onConnectionError', () => _onConnectionError?.call(e, st));
      unawaited(channel.close());
    }
  }

  /// Runs an observability callback without letting it take the server down.
  void _notify(String what, void Function() body) =>
      notifyWithoutDying(what, body, logger: _log);
}
