part of '_index.dart';

// Параметры для usecase
@freezed
abstract class FinishRegistrationParams
    with _$FinishRegistrationParams
    implements IRpcSerializable {
  const factory FinishRegistrationParams({
    required String userId,
    required WebAuthnRegistrationCredential credential,
    required String origin,
    @Default('web') String platform,
  }) = _FinishRegistrationParams;

  static IRpcCodec<FinishRegistrationParams> get codec =>
      RpcCodec(FinishRegistrationParams.fromJson);

  factory FinishRegistrationParams.fromJson(Map<String, dynamic> json) =>
      _$FinishRegistrationParamsFromJson(json);
}

// Результат выполнения usecase
@freezed
abstract class FinishRegistrationResult
    with _$FinishRegistrationResult
    implements IRpcSerializable {
  const FinishRegistrationResult._();
  const factory FinishRegistrationResult({
    required bool success,
    WebAuthnCredentialPublic? credential,
    WebAuthnException? error,
  }) = _FinishRegistrationResult;

  static IRpcCodec<FinishRegistrationResult> get codec =>
      RpcCodec(FinishRegistrationResult.fromJson);

  factory FinishRegistrationResult.fromJson(Map<String, dynamic> json) =>
      _$FinishRegistrationResultFromJson(json);

  // Фабричный метод для создания успешного результата
  factory FinishRegistrationResult.success(WebAuthnCredentialPublic credential) {
    return FinishRegistrationResult(success: true, credential: credential);
  }

  // Фабричный метод для создания результата с ошибкой
  factory FinishRegistrationResult.failure(WebAuthnException error) {
    return FinishRegistrationResult(success: false, error: error);
  }
}

// UseCase для завершения процесса регистрации WebAuthn
class FinishRegistrationUseCase {
  final IWebAuthnRepository _webAuthnRepository;
  final IChallengeRepository _challengeRepository;
  final WebAuthnSettings _settings;

  const FinishRegistrationUseCase(
    this._webAuthnRepository,
    this._challengeRepository, {
    required WebAuthnSettings settings,
  }) : _settings = settings;

  // Выполнение usecase
  Future<FinishRegistrationResult> execute(FinishRegistrationParams params) async {
    try {
      // 1. Проверяем, есть ли challenge и валиден ли он по времени
      final isValid = await _challengeRepository.isValidTimestamp(params.userId);
      if (!isValid) {
        throw WebAuthnException.timeout('Challenge не валиден');
      }

      // 2. Получаем сохраненный challenge
      final challenge = await _challengeRepository.getChallenge(params.userId);
      if (challenge == null) {
        throw WebAuthnException.registration('Challenge не найден');
      }

      // 3. Проверяем данные от клиента
      final verified = await _verifyRegistrationResponse(
        params.credential,
        challenge,
        params.origin,
        params.platform,
      );

      if (!verified.success) {
        throw WebAuthnException.registration(verified.errorMessage!);
      }

      // 4. Создаем и сохраняем новые учетные данные
      final newCredential = WebAuthnCredentialPrivate(
        id: Uuid().v4(),
        credentialId: verified.credentialId!,
        userId: params.userId,
        publicKey: verified.publicKey!,
        counter: 0,
        createdAt: DateTime.now(),
      );

      await _webAuthnRepository.saveCredential(newCredential);

      // 5. Удаляем использованный challenge
      await _challengeRepository.removeChallenge(params.userId);

      return FinishRegistrationResult.success(newCredential.public);
    } on WebAuthnException catch (e) {
      return FinishRegistrationResult.failure(e);
    } catch (e, stackTrace) {
      return FinishRegistrationResult.failure(
        WebAuthnException.registration(e.toString(), stackTrace),
      );
    }
  }

  // Верификация ответа от клиента
  Future<VerificationResult> _verifyRegistrationResponse(
    WebAuthnRegistrationCredential credential,
    List<int> challenge,
    String reportedOrigin,
    String platform,
  ) async {
    // 1. Декодируем clientDataJSON
    final clientDataJSON = utf8.decode(credential.response.clientDataJSON);
    final clientData = jsonDecode(clientDataJSON) as Map<String, dynamic>;

    // 2. Проверяем тип операции
    if (clientData['type'] != 'webauthn.create') {
      throw WebAuthnException.registration('Неверный тип операции: ${clientData['type']}');
    }

    // 3. Проверяем challenge
    final clientChallenge = WebAuthnSafeBase64.decode(clientData['challenge']);
    if (!WebAuthnCryptoUtils.compareBytes(challenge, clientChallenge)) {
      throw WebAuthnException.registration('Challenge не совпадает');
    }

    // 4. Проверяем origin - простое сравнение с ожидаемым значением
    final clientOrigin = clientData['origin'] as String? ?? '';
    _settings.ensureOriginAllowed(
      clientOrigin: clientOrigin,
      reportedOrigin: reportedOrigin,
      platform: platform,
    );

    // 5. Хешируем clientDataJSON
    final clientDataHash = sha256.convert(credential.response.clientDataJSON).bytes;

    // 6. Декодируем attestationObject
    final attestationObjectResult = AppCborDecoder.decodeAttestationObject(
      Uint8List.fromList(credential.response.attestationObject),
    );

    if (!attestationObjectResult.success) {
      throw WebAuthnException.registration(
        'Ошибка декодирования attestationObject: ${attestationObjectResult.errorMessage}',
      );
    }

    final format = attestationObjectResult.format!;
    final authData = attestationObjectResult.authData!;
    final attStmt = attestationObjectResult.attStmt!;

    // 7. Получаем и валидируем authenticator data
    final authenticatorData = AppCborDecoder.parseAuthenticatorData(authData);

    // Проверяем RP ID hash
    final rpIdHash = sha256.convert(utf8.encode(_settings.rpId)).bytes;
    if (!WebAuthnCryptoUtils.compareBytes(authenticatorData.rpIdHash, rpIdHash)) {
      throw WebAuthnException.registration('RP ID hash не соответствует');
    }

    // Проверяем обязательные флаги
    if (!authenticatorData.isUserPresent) {
      throw WebAuthnException.registration('Пользователь не присутствует при создании (UP flag)');
    }

    if (!authenticatorData.hasAttestedCredentialData) {
      throw WebAuthnException.registration('Отсутствуют данные об учетных данных (AT flag)');
    }

    // 8. Проверяем аттестационное заявление с помощью соответствующего верификатора
    final verifier = AttestationVerifierFactory.getVerifier(format);
    final attestationResult = await verifier.verify(
      attStmt: attStmt,
      authenticatorData: authData,
      clientDataHash: clientDataHash,
    );

    if (!attestationResult.success) {
      throw WebAuthnException.signatureVerification(
        'Ошибка проверки attestation: ${attestationResult.errorMessage}',
      );
    }

    // 9. Извлекаем credentialId и publicKey
    final credentialId = WebAuthnSafeBase64.encode(authenticatorData.credentialId!);

    // 10. Преобразуем COSE публичный ключ в PEM формат для сохранения
    final coseKey = AppCborDecoder.decodeCosePublicKey(authenticatorData.credentialPublicKey!);
    final publicKeyBytes = WebAuthnCryptoUtils.coseKeyToPem(coseKey);

    // 11. Возвращаем успешный результат
    return VerificationResult.success(
      credentialId: credentialId,
      publicKey: publicKeyBytes,
      aaguid: authenticatorData.aaguid,
      attestationType: attestationResult.attestationType,
    );
  }
}
