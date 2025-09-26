// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'turn_message.dart';

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
  TurnAllocation({
    required this.clientAddress,
    required this.clientPort,
    required this.socket,
    required this.relayAddress,
    required this.defaultLifetime,
    required this.permissionLifetime,
    required this.channelLifetime,
    required this.logger,
    required this.onPeerData,
    this.onExpired,
  }) {
    _subscription = socket.listen(_handleSocketEvent, onError: _handleSocketError);
    socket.readEventsEnabled = true;
    refresh(defaultLifetime);
  }

  final InternetAddress clientAddress;
  final int clientPort;
  final RawDatagramSocket socket;
  final InternetAddress relayAddress;
  final Duration defaultLifetime;
  final Duration permissionLifetime;
  final Duration channelLifetime;
  final RpcLogger? logger;
  final void Function(Uint8List data, InternetAddress address, int port)
      onPeerData;
  final void Function()? onExpired;

  final Map<String, TurnPeerPermission> _permissions = {};
  final Map<int, TurnChannelBinding> _channels = {};
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _expirationTimer;
  DateTime expiresAt = DateTime.now();

  int get relayPort => socket.port;

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
    _subscription?.cancel();
    socket.close();
  }

  void addPermission(InternetAddress address) {
    final key = address.address;
    final permission = _permissions[key];
    if (permission != null) {
      permission.refresh(permissionLifetime);
      logger?.debug('Permission refreshed for $key');
    } else {
      _permissions[key] = TurnPeerPermission(address, permissionLifetime);
      logger?.debug('Permission created for $key');
    }
  }

  bool hasPermission(InternetAddress address) {
    final key = address.address;
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
    addPermission(peerAddress);
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
    socket.send(payload, address, port);
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      while (true) {
        final datagram = socket.receive();
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
  }

  void _handleSocketError(Object error) {
    logger?.error(
      'Relay socket error for ${clientAddress.address}:$clientPort',
      error: error,
    );
  }
}
