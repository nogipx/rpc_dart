import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpoint health', () {
    test('caller endpoint reports healthy status when active', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final caller = RpcCallerEndpoint(transport: clientTransport);
      final responder = RpcResponderEndpoint(transport: serverTransport);

      final report = await caller.health();

      expect(report.endpointStatus.level, RpcHealthLevel.healthy);
      expect(report.transportStatus?.level, RpcHealthLevel.healthy);
      expect(report.isHealthy, isTrue);

      await caller.close();
      await responder.close();
    });

    test('responder endpoint health becomes closed after close()', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final caller = RpcCallerEndpoint(transport: clientTransport);
      final responder = RpcResponderEndpoint(transport: serverTransport);

      await responder.close();

      final report = await responder.health();

      expect(report.endpointStatus.level, RpcHealthLevel.closed);
      expect(report.transportStatus?.level, RpcHealthLevel.closed);
      expect(report.isHealthy, isFalse);

      await caller.close();
    });

    test(
      'reconnect reflects transport status when endpoint already closed',
      () async {
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final caller = RpcCallerEndpoint(transport: clientTransport);
        final responder = RpcResponderEndpoint(transport: serverTransport);

        await caller.close();

        final report = await caller.reconnect();

        expect(report.endpointStatus.level, RpcHealthLevel.closed);
        expect(report.transportStatus?.level, RpcHealthLevel.unhealthy);
        expect(report.transportStatus?.details['supported'], isFalse);

        await responder.close();
      },
    );
  });
}
