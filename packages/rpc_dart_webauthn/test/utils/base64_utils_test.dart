import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

void main() {
  group('SafeBase64', () {
    group('encode', () {
      test('должен кодировать данные в base64url без паддингов', () {
        // 'Hello' -> 'SGVsbG8'
        expect(WebAuthnSafeBase64.encode([72, 101, 108, 108, 111]), equals('SGVsbG8'));

        // 'Hello, World!' -> 'SGVsbG8sIFdvcmxkIQ'
        expect(
          WebAuthnSafeBase64.encode([72, 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33]),
          equals('SGVsbG8sIFdvcmxkIQ'),
        );
      });

      test('должен кодировать данные без паддингов даже когда они требуются', () {
        // 'A' -> 'QQ' (должно быть 'QQ==' с паддингами)
        expect(WebAuthnSafeBase64.encode([65]), equals('QQ'));

        // 'AB' -> 'QUI' (должно быть 'QUI=' с паддингом)
        expect(WebAuthnSafeBase64.encode([65, 66]), equals('QUI'));
      });

      test('должен кодировать пустой массив в пустую строку', () {
        expect(WebAuthnSafeBase64.encode([]), equals(''));
      });
    });

    group('decode', () {
      test('должен декодировать base64url без паддингов', () {
        expect(WebAuthnSafeBase64.decode('SGVsbG8'), equals([72, 101, 108, 108, 111])); // 'Hello'
        expect(
          WebAuthnSafeBase64.decode('SGVsbG8sIFdvcmxkIQ'),
          equals([72, 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33]), // 'Hello, World!'
        );
      });

      test('должен декодировать base64url с паддингами', () {
        expect(WebAuthnSafeBase64.decode('QQ=='), equals([65])); // 'A'
        expect(WebAuthnSafeBase64.decode('QUI='), equals([65, 66])); // 'AB'
      });

      test('должен обрабатывать символы base64url (- и _)', () {
        // Строка '+/A=' должна дать байты [251, 240]
        expect(WebAuthnSafeBase64.decode('-_A='), equals([251, 240]));
        expect(WebAuthnSafeBase64.decode('-_A'), equals([251, 240]));
      });

      test('должен декодировать пустую строку в пустой массив', () {
        expect(WebAuthnSafeBase64.decode(''), equals([]));
      });

      test('должен выбрасывать исключение при некорректных данных', () {
        expect(
            () => WebAuthnSafeBase64.decode('ThisIsNotBase64!'), throwsA(isA<FormatException>()));
      });
    });

    group('normalize', () {
      test('должен добавлять паддинги если они нужны', () {
        expect(WebAuthnSafeBase64.normalize('QQ'), equals('QQ==')); // 'A'
        expect(WebAuthnSafeBase64.normalize('QUI'), equals('QUI=')); // 'AB'
      });

      test('не должен изменять строку если паддинги не нужны', () {
        expect(WebAuthnSafeBase64.normalize('QUJD'), equals('QUJD')); // 'ABC'
      });

      test('должен заменять символы base64url на base64 (+/)', () {
        // '-_A' -> '+/A' с паддингом
        expect(WebAuthnSafeBase64.normalize('-_A'), equals('+/A='));
      });
    });

    group('интеграционные тесты', () {
      test('encode и decode должны быть обратными операциями', () {
        final testBytes = [1, 2, 3, 4, 5, 255, 254, 253, 252];
        final encoded = WebAuthnSafeBase64.encode(testBytes);
        final decoded = WebAuthnSafeBase64.decode(encoded);
        expect(decoded, equals(testBytes));
      });

      test('должен работать с WebAuthn challenge примером', () {
        // Типичный размер challenge в WebAuthn - 32 байта
        final challenge = List<int>.generate(32, (i) => i + 1);
        final encoded = WebAuthnSafeBase64.encode(challenge);

        // Проверка на отсутствие паддингов
        expect(encoded.contains('='), isFalse);

        // Проверка корректного декодирования
        final decoded = WebAuthnSafeBase64.decode(encoded);
        expect(decoded, equals(challenge));
      });
    });
  });
}
