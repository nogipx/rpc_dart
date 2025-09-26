// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'turn_message.dart';
import 'turn_relay_logger.dart';

/// Represents the transport protocol used for relaying peer traffic.
enum TurnRelayTransportProtocol { udp, tcp }

/// Represents permission to send data to a specific peer address.
final class TurnPeerPermission {
  TurnPeerPermission(this.address, Duration lifetime)
      : expiresAt = DateTime.now().add(lifetime);

  final InternetAddress address;
  DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  void refresh(Duration lifetime) {
    expiresAt = DateTime.now().add(lifetime);
  }
}

/// Channel binding information according to RFC 5766 section 11.
final class TurnChannelBinding {
  TurnChannelBinding({
    required this.channelNumber,
    required this.peerAddress,
    required this.peerPort,
    required Duration lifetime,
  }) : expiresAt = DateTime.now().add(lifetime);

  final int channelNumber;
  final InternetAddress peerAddress;
  final int peerPort;
  DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  void refresh(Duration lifetime) {
    expiresAt = DateTime.now().add(lifetime);
  }
}

/// Active TURN allocation state for a single client.
final class TurnAllocation {
  TurnAllocation.udp({
    required this.clientAddress,
    required this.clientPort,
    required RawDatagramSocket socket,
    required this.relayAddress,
    required this.defaultLifetime,
    required this.permissionLifetime,
    required this.channelLifetime,
    required this.logger,
    required this.onPeerData,
    this.onExpired,
  })  : transportProtocol = TurnRelayTransportProtocol.udp,
        _udpSocket = socket,
        _tcpListener = null {
    _udpSubscription =
        socket.listen(_handleUdpSocketEvent, onError: _handleUdpSocketError);
    socket.readEventsEnabled = true;
    refresh(defaultLifetime);
  }

  TurnAllocation.tcp({
    required this.clientAddress,
    required this.clientPort,
    required ServerSocket serverSocket,
    required this.relayAddress,
    required this.defaultLifetime,
    required this.permissionLifetime,
    required this.channelLifetime,
    required this.logger,
    required this.onPeerData,
    this.onExpired,
  })  : transportProtocol = TurnRelayTransportProtocol.tcp,
        _udpSocket = null,
        _tcpListener = serverSocket {
    _tcpListenerSubscription = serverSocket.listen(
      _handleTcpConnection,
      onError: _handleTcpListenerError,
    );
    refresh(defaultLifetime);
  }

  final InternetAddress clientAddress;
  final int clientPort;
  final InternetAddress relayAddress;
  final Duration defaultLifetime;
  final Duration permissionLifetime;
  final Duration channelLifetime;
  final TurnRelayLogger? logger;
  final void Function(Uint8List data, InternetAddress address, int port)
      onPeerData;
  final void Function()? onExpired;

  final TurnRelayTransportProtocol transportProtocol;
  final RawDatagramSocket? _udpSocket;
  final ServerSocket? _tcpListener;

  final Map<String, TurnPeerPermission> _permissions = {};
  final Map<int, TurnChannelBinding> _channels = {};
  final Map<String, Socket> _tcpPeers = {};
  final Map<String, StreamSubscription<List<int>>> _tcpPeerSubscriptions = {};

  StreamSubscription<RawSocketEvent>? _udpSubscription;
  StreamSubscription<Socket>? _tcpListenerSubscription;
  Timer? _expirationTimer;
  DateTime expiresAt = DateTime.now();

  int get relayPort => transportProtocol == TurnRelayTransportProtocol.udp
      ? _udpSocket!.port
      : _tcpListener!.port;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  void refresh(Duration lifetime) {
    final effective = lifetime.inSeconds > 0 ? lifetime : defaultLifetime;
    expiresAt = DateTime.now().add(effective);
    _expirationTimer?.cancel();
    _expirationTimer = Timer(effective, expire);
    logger?.debug(
      'Allocation for ${clientAddress.address}:$clientPort refreshed until $expiresAt',
    );
  }

  void expire() {
    logger?.info(
      'Allocation for ${clientAddress.address}:$clientPort expired',
    );
    onExpired?.call();
    close();
  }

  void close() {
    _expirationTimer?.cancel();
    _udpSubscription?.cancel();
    _tcpListenerSubscription?.cancel();

    if (_udpSocket != null) {
      _udpSocket!.close();
    }

    if (_tcpListener != null) {
      _tcpListener!.close();
    }

    for (final subscription in _tcpPeerSubscriptions.values) {
      subscription.cancel();
    }
    _tcpPeerSubscriptions.clear();

    for (final socket in _tcpPeers.values) {
      socket.destroy();
    }
    _tcpPeers.clear();
  }

  void addPermission(InternetAddress address, int port) {
    final key = _permissionKey(address);
    final permission = _permissions[key];
    if (permission != null) {
      permission.refresh(permissionLifetime);
      logger?.debug('Permission refreshed for $key');
    } else {
      _permissions[key] = TurnPeerPermission(address, permissionLifetime);
      logger?.debug('Permission created for $key');
    }
  }

  bool hasPermission(InternetAddress address, int port) {
    final key = _permissionKey(address);
    final permission = _permissions[key];
    if (permission == null) {
      return false;
    }
    if (permission.isExpired) {
      _permissions.remove(key);
      return false;
    }
    return true;
  }

  void bindChannel(int channelNumber, InternetAddress peerAddress, int peerPort) {
    final binding = _channels[channelNumber];
    if (binding != null) {
      binding.refresh(channelLifetime);
      logger?.debug(
        'Channel $channelNumber refreshed for ${peerAddress.address}:$peerPort',
      );
    } else {
      _channels[channelNumber] = TurnChannelBinding(
        channelNumber: channelNumber,
        peerAddress: peerAddress,
        peerPort: peerPort,
        lifetime: channelLifetime,
      );
      logger?.debug(
        'Channel $channelNumber bound to ${peerAddress.address}:$peerPort',
      );
    }
    addPermission(peerAddress, peerPort);
  }

  TurnChannelBinding? getChannel(int channelNumber) {
    final binding = _channels[channelNumber];
    if (binding == null) return null;
    if (binding.isExpired) {
      _channels.remove(channelNumber);
      return null;
    }
    return binding;
  }

  TurnChannelBinding? findChannelByPeer(
    InternetAddress peerAddress,
    int peerPort,
  ) {
    for (final entry in _channels.entries) {
      final binding = entry.value;
      if (binding.isExpired) {
        _channels.remove(entry.key);
        continue;
      }
      if (binding.peerAddress.address == peerAddress.address &&
          binding.peerPort == peerPort) {
        return binding;
      }
    }
    return null;
  }

  void sendToPeer(Uint8List payload, InternetAddress address, int port) {
    switch (transportProtocol) {
      case TurnRelayTransportProtocol.udp:
        _udpSocket!.send(payload, address, port);
        break;
      case TurnRelayTransportProtocol.tcp:
        final key = _peerKey(address, port);
        Socket? socket = _tcpPeers[key];
        if (socket == null) {
          for (final entry in _tcpPeers.entries) {
            if (entry.value.remoteAddress.address == address.address) {
              socket = entry.value;
              break;
            }
          }
        }
        if (socket == null) {
          logger?.warning(
            'No TCP peer connection for ${address.address}:$port',
          );
          return;
        }
        socket.add(payload);
        break;
    }
  }

  void _handleUdpSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    while (true) {
      final datagram = _udpSocket!.receive();
      if (datagram == null) {
        break;
      }
      onPeerData(
        Uint8List.fromList(datagram.data),
        datagram.address,
        datagram.port,
      );
    }
  }

  void _handleUdpSocketError(Object error) {
    logger?.error(
      'Relay UDP socket error for ${clientAddress.address}:$clientPort',
      error: error,
    );
  }

  void _handleTcpConnection(Socket socket) {
    final key = _peerKey(socket.remoteAddress, socket.remotePort);
    _tcpPeers[key] = socket;
    socket.encoding = null;

    final subscription = socket.listen(
      (List<int> data) {
        if (data.isEmpty) {
          return;
        }
        onPeerData(
          Uint8List.fromList(data),
          socket.remoteAddress,
          socket.remotePort,
        );
      },
      onError: (Object error) {
        logger?.error(
          'Relay TCP peer error for ${socket.remoteAddress.address}:${socket.remotePort}',
          error: error,
        );
        _removeTcpPeer(key, close: true);
      },
      onDone: () {
        _removeTcpPeer(key, close: false);
      },
      cancelOnError: false,
    );

    _tcpPeerSubscriptions[key] = subscription;
  }

  void _handleTcpListenerError(Object error) {
    logger?.error(
      'Relay TCP listener error for ${clientAddress.address}:$clientPort',
      error: error,
    );
  }

  void _removeTcpPeer(String key, {required bool close}) {
    final subscription = _tcpPeerSubscriptions.remove(key);
    subscription?.cancel();

    final socket = _tcpPeers.remove(key);
    if (socket != null && close) {
      socket.destroy();
    }
  }

  static String _permissionKey(InternetAddress address) => address.address;

  static String _peerKey(InternetAddress address, int port) =>
      '${address.address}:$port';
}
