import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryWebAuthnRepositoryImpl', () {
    late MemoryWebAuthnRepositoryImpl repository;

    setUp(() {
      repository = MemoryWebAuthnRepositoryImpl();
    });

    test('должен сохранять и получать учетные данные по ID', () async {
      // Arrange
      final credential = WebAuthnCredentialPrivate(
        id: '1',
        credentialId: 'credential-123',
        userId: '1',
        publicKey: [1, 2, 3, 4],
        counter: 0,
        createdAt: DateTime.now(),
      );

      // Act
      await repository.saveCredential(credential);
      final retrieved = await repository.getCredentialById('credential-123');

      // Assert
      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals('1'));
      expect(retrieved.credentialId, equals('credential-123'));
      expect(retrieved.userId, equals('1'));
      expect(retrieved.publicKey, equals([1, 2, 3, 4]));
      expect(retrieved.counter, equals(0));
    });

    test('должен получать все учетные данные пользователя', () async {
      // Arrange
      final credential1 = WebAuthnCredentialPrivate(
        id: '1',
        credentialId: 'credential-1',
        userId: '1',
        publicKey: [1, 2, 3, 4],
        counter: 0,
        createdAt: DateTime.now(),
      );

      final credential2 = WebAuthnCredentialPrivate(
        id: '2',
        credentialId: 'credential-2',
        userId: '1',
        publicKey: [5, 6, 7, 8],
        counter: 0,
        createdAt: DateTime.now(),
      );

      final credential3 = WebAuthnCredentialPrivate(
        id: '3',
        credentialId: 'credential-3',
        userId: '2',
        publicKey: [9, 10, 11, 12],
        counter: 0,
        createdAt: DateTime.now(),
      );

      // Act
      await repository.saveCredential(credential1);
      await repository.saveCredential(credential2);
      await repository.saveCredential(credential3);

      final user1Credentials = await repository.getCredentialsByUserId('1');
      final user2Credentials = await repository.getCredentialsByUserId('2');

      // Assert
      expect(user1Credentials.length, equals(2));
      expect(user1Credentials.map((c) => c.id).toList()..sort(), equals(['1', '2']));

      expect(user2Credentials.length, equals(1));
      expect(user2Credentials.first.id, equals('3'));
    });

    test('должен обновлять счетчик', () async {
      // Arrange
      final credential = WebAuthnCredentialPrivate(
        id: '1',
        credentialId: 'credential-123',
        userId: '1',
        publicKey: [1, 2, 3, 4],
        counter: 0,
        createdAt: DateTime.now(),
      );

      await repository.saveCredential(credential);

      // Act
      await repository.updateCounter('credential-123', 5);
      final updated = await repository.getCredentialById('credential-123');

      // Assert
      expect(updated!.counter, equals(5));
    });

    test('должен возвращать null при получении несуществующих учетных данных', () async {
      // Act
      final nonExistent = await repository.getCredentialById('non-existent');

      // Assert
      expect(nonExistent, isNull);
    });

    test(
      'должен возвращать пустой список при получении учетных данных несуществующего пользователя',
      () async {
        // Act
        final credentials = await repository.getCredentialsByUserId('1');

        // Assert
        expect(credentials, isEmpty);
      },
    );
  });
}
