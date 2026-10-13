// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Support script for stale_socket_file_test.dart.
//
// Binds a Unix socket at argv[0] and exits without closing it, which is what a
// crashed server does: the socket file stays behind with nobody listening.

import 'dart:io';

Future<void> main(List<String> argv) async {
  await ServerSocket.bind(
    InternetAddress(argv.first, type: InternetAddressType.unix),
    0,
  );
  exit(0);
}
