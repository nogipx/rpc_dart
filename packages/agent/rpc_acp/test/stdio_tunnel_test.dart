// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:rpc_acp/rpc_acp.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_stdio/rpc_dart_stdio.dart';
import 'package:test/test.dart';

void main() {
  test('ACP client reaches an agent through rpc_dart stdio', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'test/support/stdio_tunnel_host.dart',
    ]);
    final endpoint = RpcPeerEndpoint(
      transport: RpcStdioCallerTransport.fromProcess(process),
    );
    endpoint.start();
    final client = AcpClient(RpcAcpConnection(endpoint));
    try {
      expect((await client.initialize()).protocolVersion, 1);
      expect(await client.newSession(), 'stdio-session');
    } finally {
      await client.dispose();
      await endpoint.close();
      if (!await process.exitCode
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              process.kill();
              return -1;
            },
          )
          .then((code) => code == 0)) {
        fail('stdio tunnel host did not exit cleanly');
      }
    }
  });
}
