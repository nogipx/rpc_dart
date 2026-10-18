// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Support script for stale_socket_file_test.dart. argv: <mode> <path>.
//
// raw     binds a Unix socket at path and exits without closing it, which is
//         what a crashed server of any kind does.
// server  starts an RpcSocketServer at path and exits without stopping it, so
//         its lock file stays behind too, unlocked.
// intrude waits for a line on stdin, fills the accept queue of the server at
//         path until a connect fails, then starts a second RpcSocketServer
//         there. Prints `queued N`, then `taken` or `refused`.

import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';

Future<void> main(List<String> argv) async {
  final path = argv[1];
  final address = RpcSocketAddress.unix(path);
  switch (argv.first) {
    case 'raw':
      await ServerSocket.bind(address.host, 0);
    case 'server':
      await RpcSocketServer(
        address: address,
        mode: RpcResponderMode((_) {}),
      ).start();
    case 'intrude':
      print('ready');
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
      final held = <Socket>[];
      try {
        while (held.length < 300) {
          held.add(
            await Socket.connect(
              address.host,
              0,
              timeout: const Duration(seconds: 2),
            ),
          );
        }
      } on SocketException {
        // The queue is full.
      }
      print('queued ${held.length}');
      final intruder = RpcSocketServer(
        address: address,
        mode: RpcResponderMode((_) {}),
      );
      try {
        await intruder.start();
        print('taken');
      } on SocketException {
        print('refused');
      }
      for (final socket in held) {
        socket.destroy();
      }
  }
  exit(0);
}
