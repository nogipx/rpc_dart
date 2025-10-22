part of '_index.dart';

// Параметры для usecase
@freezed
abstract class FinishAuthenticationParams
    with _$FinishAuthenticationParams
    implements IRpcSerializable {
  const factory FinishAuthenticationParams({
    required String userId,
    required WebAuthnAssertion assertion,
    required String origin,
    required int expiresIn,
    required List<String> scopes,
    @Default('web') String platform,
  }) = _FinishAuthenticationParams;

  static IRpcCodec<FinishAuthenticationParams> get codec =>
      RpcCodec(FinishAuthenticationParams.fromJson);

  factory FinishAuthenticationParams.fromJson(Map<String, dynamic> json) =>
      _$FinishAuthenticationParamsFromJson(json);
}

// Результат выполнения usecase
@freezed
abstract class FinishAuthenticationResult
    with _$FinishAuthenticationResult
    implements IRpcSerializable {
  const FinishAuthenticationResult._();

  const factory FinishAuthenticationResult({
    required bool success,
    AuthResponse? authResponse,
    WebAuthnException? error,
  }) = _FinishAuthenticationResult;

  static IRpcCodec<FinishAuthenticationResult> get codec =>
      RpcCodec(FinishAuthenticationResult.fromJson);

  factory FinishAuthenticationResult.fromJson(Map<String, dynamic> json) =>
      _$FinishAuthenticationResultFromJson(json);

  // Фабричный метод для создания успешного результата
  factory FinishAuthenticationResult.success({
    required AuthResponse authResponse,
  }) {
    return FinishAuthenticationResult(
      success: true,
      authResponse: authResponse,
    );
  }

  // Фабричный метод для создания результата с ошибкой
  factory FinishAuthenticationResult.failure(WebAuthnException error) {
    return FinishAuthenticationResult(success: false, error: error);
  }
}

// UseCase для завершения процесса аутентификации WebAuthn
class FinishAuthenticationUseCase {
  final IWebAuthnRepository _webAuthnRepository;
  final IChallengeRepository _challengeRepository;
  final ISessionRepository _sessionRepository;
  final WebAuthnSettings _settings;
  final PasetoUtils _pasetoUtils;

  FinishAuthenticationUseCase(
    this._webAuthnRepository,
    this._challengeRepository,
    this._sessionRepository, {
    required WebAuthnSettings settings,
    required PasetoUtils pasetoUtils,
  }) : _settings = settings,
       _pasetoUtils = pasetoUtils;

  // Выполнение usecase
  Future<FinishAuthenticationResult> execute(
    FinishAuthenticationParams params,
  ) async {
    try {
      // 1. Проверяем, есть ли challenge и валиден ли он по времени
      final isValid = await _challengeRepository.isValidTimestamp(
        params.userId,
      );
      if (!isValid) {
        throw WebAuthnException.timeout('Challenge не валиден');
      }

      // 2. Получаем сохраненный challenge
      final challenge = await _challengeRepository.getChallenge(params.userId);
      if (challenge == null) {
        throw WebAuthnException.authentication('Challenge не найден');
      }

      // 3. Получаем credentialId из assertion
      final credentialId = params.assertion.id;

      // 4. Получаем учетные данные из БД
      final credential = await _webAuthnRepository.getCredentialById(
        credentialId,
      );
      if (credential == null) {
        throw WebAuthnException.credential('Учетные данные не найдены');
      }

      // 5. Проверяем, соответствует ли пользователь
      if (credential.userId != params.userId) {
        throw WebAuthnException.credential(
          'Учетные данные принадлежат другому пользователю',
        );
      }

      // 6. Проверяем данные от клиента
      final result = await _verifyAuthenticationResponse(
        params.assertion,
        challenge,
        params.origin,
        params.platform,
        credential.publicKey,
        credential.counter,
        params.userId,
      );

      // 7. Обновляем счетчик
      if (result > credential.counter) {
        await _webAuthnRepository.updateCounter(credentialId, result);
      } else if (credential.counter > 0) {
        // Потенциальное клонирование устройства!
        final counterDiff = credential.counter - result;
        throw WebAuthnException.authentication(
          'Обнаружена потенциальная атака клонирования устройства: '
          'счетчик в БД (${credential.counter}) больше или равен полученному счетчику ($result). '
          'Разница: $counterDiff',
        );
      }

      // 8. Удаляем использованный challenge
      await _challengeRepository.removeChallenge(params.userId);

      // 9. Создаем сессию
      final expiresInSeconds = _settings.tokenLifetime;
      final sessionId = const Uuid().v4();
      final sessionExpiresAt = DateTime.now().add(
        Duration(seconds: expiresInSeconds),
      );

      await _sessionRepository.storeActiveSession(
        sessionId,
        credential.userId,
        expiresAt: sessionExpiresAt,
        metadata: {
          'credentialId': credential.credentialId,
          'platform': params.platform,
          'origin': params.origin,
          'createdAt': DateTime.now().toIso8601String(),
        },
      );

      // 10. Создаем токен с ID сессии
      final pasetoToken = await _pasetoUtils.createToken(
        userId: credential.userId,
        scopes: params.scopes,
        extra: {...credential.public.toJson(), 'sessionId': sessionId},
      );

      final authResponse = AuthResponse(
        accessToken: pasetoToken,
        expiresIn: expiresInSeconds,
        userId: credential.userId,
        credential: credential.public,
      );

      // Добавляем информацию о токене в результат
      return FinishAuthenticationResult.success(authResponse: authResponse);
    } on WebAuthnException catch (e) {
      return FinishAuthenticationResult.failure(e);
    } catch (e, stackTrace) {
      return FinishAuthenticationResult.failure(
        WebAuthnException.authentication(e.toString(), stackTrace),
      );
    }
  }

  // Верификация ответа от клиента
  Future<int> _verifyAuthenticationResponse(
    WebAuthnAssertion assertion,
    List<int> challenge,
    String reportedOrigin,
    String platform,
    List<int> publicKey,
    int storedCounter,
    String expectedUserId,
  ) async {
    // 1. Декодируем clientDataJSON
    final clientDataJSON = utf8.decode(assertion.response.clientDataJSON);
    final clientData = jsonDecode(clientDataJSON) as Map<String, dynamic>;

    // 2. Проверяем тип операции
    if (clientData['type'] != 'webauthn.get') {
      throw WebAuthnException.authentication(
        'Неверный тип операции: ${clientData['type']}',
      );
    }

    // 3. Проверяем challenge
    final clientChallenge = WebAuthnSafeBase64.decode(clientData['challenge']);
    if (!WebAuthnCryptoUtils.compareBytes(challenge, clientChallenge)) {
      throw WebAuthnException.authentication('Challenge не совпадает');
    }

    // 4. Проверяем origin
    final clientOrigin = clientData['origin'] as String? ?? '';
    _settings.ensureOriginAllowed(
      clientOrigin: clientOrigin,
      reportedOrigin: reportedOrigin,
      platform: platform,
    );

    // 4a. Проверяем user handle, если он присутствует
    final userHandle = assertion.response.userHandle;
    if (userHandle != null && userHandle.isNotEmpty) {
      final handleUtf8 = utf8.decode(userHandle, allowMalformed: true);
      final handleBase64 = WebAuthnSafeBase64.encode(userHandle);
      if (handleUtf8 != expectedUserId && handleBase64 != expectedUserId) {
        throw WebAuthnException.authentication(
          'User handle не соответствует ожидаемому пользователю',
        );
      }
    }

    // 5. Проверяем authenticator data
    final authenticatorData = assertion.response.authenticatorData;

    // Проверяем минимальную длину (rpIdHash[32] + flags[1] + counter[4])
    if (authenticatorData.length < 37) {
      throw WebAuthnException.authentication(
        'Неверная длина authenticator data: ${authenticatorData.length} < 37',
      );
    }

    // 6. Проверяем флаги (User Present и User Verified)
    final flags = authenticatorData[32];
    final userPresent = (flags & 0x01) != 0;
    final userVerified = (flags & 0x04) != 0;

    if (!userPresent) {
      throw WebAuthnException.authentication(
        'Пользователь не присутствует при аутентификации (отсутствует флаг UP)',
      );
    }

    // Если требуется верификация пользователя, проверяем наличие флага UV
    if (_settings.requireUserVerification && !userVerified) {
      throw WebAuthnException.authentication(
        'Требуется верификация пользователя, но флаг UV отсутствует',
      );
    }

    // 7. Проверяем rpIdHash
    final rpIdHash = authenticatorData.sublist(0, 32);
    final calculatedRpIdHash = sha256
        .convert(utf8.encode(_settings.rpId))
        .bytes;

    if (!WebAuthnCryptoUtils.compareBytes(rpIdHash, calculatedRpIdHash)) {
      throw WebAuthnException.authentication(
        'RP ID hash не совпадает. Ожидалось: ${_bytesToHex(calculatedRpIdHash)}, получено: ${_bytesToHex(rpIdHash)}',
      );
    }

    // 8. Проверяем счетчик
    final counterBytes = authenticatorData.sublist(33, 37);
    final counter =
        (counterBytes[0] << 24) |
        (counterBytes[1] << 16) |
        (counterBytes[2] << 8) |
        counterBytes[3];

    if (counter < storedCounter && storedCounter > 0) {
      throw WebAuthnException.authentication(
        'Счетчик не увеличился: возможно клонирование устройства. '
        'Сохраненный счетчик: $storedCounter, полученный счетчик: $counter',
      );
    }

    // 9. Хешируем clientDataJSON
    final clientDataHash = sha256
        .convert(assertion.response.clientDataJSON)
        .bytes;

    // 10. Комбинируем данные для проверки подписи
    final signedData = Uint8List.fromList([
      ...authenticatorData,
      ...clientDataHash,
    ]);

    // 11. Проверяем, является ли ключ JSON-форматом (для P-256)
    final keyStr = utf8.decode(publicKey);
    final keyMap = jsonDecode(keyStr) as Map<String, dynamic>;

    // Получаем кривую и координаты
    final curve = keyMap['curve'] as String;
    final xBase64 = keyMap['x'] as String;
    final yBase64 = keyMap['y'] as String;

    final signatureValid = WebAuthnCryptoUtils.verifyWebAuthnSignature(
      signedData,
      Uint8List.fromList(assertion.response.signature),
      curve,
      xBase64,
      yBase64,
    );

    if (!signatureValid) {
      throw WebAuthnException.signatureVerification('Неверная подпись');
    }

    // Возвращаем новое значение счетчика
    return counter;
  }

  // Вспомогательный метод для преобразования байтов в шестнадцатеричную строку
  String _bytesToHex(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
