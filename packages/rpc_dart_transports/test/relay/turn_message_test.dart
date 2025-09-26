import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

void main() {
  group('TurnMessage', () {
    test('encodes and decodes round-trip', () {
      final transactionId = Uint8List.fromList(List.generate(12, (i) => i));
      final message = TurnMessage(
        method: TurnMethod.allocate,
        messageClass: TurnMessageClass.request,
        transactionId: transactionId,
        attributes: [
          TurnAttribute(
            TurnAttributeType.lifetime,
            encodeLifetime(const Duration(minutes: 10)),
          ),
          TurnAttribute(
            TurnAttributeType.requestedTransport,
            Uint8List.fromList(<int>[TurnRequestedTransport.udp, 0, 0, 0]),
          ),
        ],
      );

      final bytes = message.encode();
      final decoded = TurnMessage.decode(bytes);

      expect(decoded, isNotNull);
      expect(decoded!.method, TurnMethod.allocate);
      expect(decoded.messageClass, TurnMessageClass.request);
      expect(decoded.transactionId, equals(transactionId));
      expect(decoded.attributes.length, message.attributes.length);
      expect(
        decoded.firstAttribute(TurnAttributeType.lifetime),
        encodeLifetime(const Duration(minutes: 10)),
      );
    });

    test('decodes requested transport attribute', () {
      final udp = decodeRequestedTransport(
        Uint8List.fromList(<int>[TurnRequestedTransport.udp]),
      );
      final tcp = decodeRequestedTransport(
        Uint8List.fromList(<int>[TurnRequestedTransport.tcp, 0, 0, 0]),
      );

      expect(udp, TurnRequestedTransport.udp);
      expect(tcp, TurnRequestedTransport.tcp);
    });

    test('XOR address encode/decode', () {
      final transactionId = Uint8List.fromList(List.filled(12, 1));
      final address = InternetAddress.loopbackIPv4;
      const port = 3478;

      final encoded = encodeXorAddress(address, port, transactionId);
      final (decodedAddress, decodedPort) =
          decodeXorAddress(encoded, transactionId);

      expect(decodedAddress.address, address.address);
      expect(decodedPort, port);
    });

    test('lifetime helpers', () {
      const lifetime = Duration(minutes: 2, seconds: 30);
      final encoded = encodeLifetime(lifetime);
      final decoded = decodeLifetime(encoded);
      expect(decoded, lifetime);
    });
  });
}
