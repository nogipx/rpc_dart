import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryChallengeRepositoryImpl', () {
    late MemoryChallengeRepositoryImpl repository;

    setUp(() {
      repository = MemoryChallengeRepositoryImpl(
        validDuration: Duration(milliseconds: 100),
      );
    });

    test('должен сохранять и получать challenge', () async {
      // Arrange
      const userId = '1';
      final challenge = [1, 2, 3, 4];

      // Act
      await repository.storeChallenge(userId, challenge);
      final retrieved = await repository.getChallenge(userId);

      // Assert
      expect(retrieved, equals(challenge));
    });

    test('должен удалять challenge', () async {
      // Arrange
      const userId = '1';
      final challenge = [1, 2, 3, 4];

      await repository.storeChallenge(userId, challenge);

      // Act
      await repository.removeChallenge(userId);
      final retrieved = await repository.getChallenge(userId);

      // Assert
      expect(retrieved, isNull);
    });

    test('должен корректно проверять актуальность timestamp', () async {
      // Arrange
      const userId = '1';
      final challenge = [1, 2, 3, 4];

      await repository.storeChallenge(userId, challenge);

      // Act & Assert
      // Сразу после создания должен быть валидным
      expect(await repository.isValidTimestamp(userId), isTrue);

      // Ждем, пока timestamp устареет
      await Future.delayed(Duration(milliseconds: 110));

      // После истечения времени должен быть невалидным
      expect(await repository.isValidTimestamp(userId), isFalse);
    });

    test('должен поддерживать кастомное время истечения', () async {
      // Arrange
      const userId = '1';
      final challenge = [1, 2, 3, 4];

      // Устанавливаем challenge с коротким временем жизни
      await repository.storeChallenge(userId, challenge, expiresInSeconds: 1);

      // Act & Assert
      // Сразу после создания должен быть валидным
      expect(await repository.isValidTimestamp(userId), isTrue);

      // Ждем, пока timestamp устареет
      await Future.delayed(Duration(milliseconds: 1100)); // 1.1 секунды

      // После истечения времени должен быть невалидным
      expect(await repository.isValidTimestamp(userId), isFalse);
    });

    test('должен возвращать null для несуществующего challenge', () async {
      // Act
      final retrieved = await repository.getChallenge('1');

      // Assert
      expect(retrieved, isNull);
    });

    test('должен возвращать false для несуществующего timestamp', () async {
      // Act
      final isValid = await repository.isValidTimestamp('1');

      // Assert
      expect(isValid, isFalse);
    });

    test('перезапись challenge должна обновлять timestamp', () async {
      // Arrange
      const userId = '1';
      final challenge1 = [1, 2, 3, 4];

      await repository.storeChallenge(userId, challenge1);

      // Ждем, пока timestamp почти устареет
      await Future.delayed(Duration(milliseconds: 90));

      // Перезаписываем challenge
      final challenge2 = [5, 6, 7, 8];
      await repository.storeChallenge(userId, challenge2);

      // Ждем еще немного, чтобы первый timestamp точно устарел
      await Future.delayed(Duration(milliseconds: 20));

      // Act & Assert
      // Должен быть валидным, так как мы перезаписали challenge и timestamp обновился
      expect(await repository.isValidTimestamp(userId), isTrue);

      // И должны получить новый challenge
      expect(await repository.getChallenge(userId), equals(challenge2));
    });
  });
}
