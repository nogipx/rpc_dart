// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';

const _handshakeHeader = 'x-rpc-secure-handshake';
const _metadataHeader = 'x-rpc-secure-metadata';
const _handshakePeerKeyHeader = 'x-rpc-secure-peer-key';
const _protocolLabel = 'rpc+secure/1';
const _infoCallerToResponder = 'rpc:data:caller->responder';
const _infoResponderToCaller = 'rpc:data:responder->caller';

class _HandshakeEnvelope {
  const _HandshakeEnvelope({
    required this.token,
    required this.streamId,
    required this.isEndOfStream,
    this.peerPublicKeyPaserk,
  });

  final String token;
  final int streamId;
  final bool isEndOfStream;
  final String? peerPublicKeyPaserk;
}

enum SecureFrameFormat { verbose, compact }

/// Configuration for the [SecureTransportAdapter].
class SecureTransportConfig {
  const SecureTransportConfig({
    this.handshakeTimeout = const Duration(seconds: 15),
    this.handshakeTokenTtl = const Duration(minutes: 5),
    this.frameFormat = SecureFrameFormat.verbose,
    this.paddingBlockSize,
    this.maxPaddingBlocks = 3,
    this.removeTransportId = false,
    this.removeProtocol = false,
    this.pendingHandshakeMessageLimit = 16,
  }) : assert(pendingHandshakeMessageLimit >= 0);

  /// Maximum time to wait for handshake messages.
  final Duration handshakeTimeout;

  /// Time-to-live for Licensify handshake tokens.
  final Duration handshakeTokenTtl;

  /// Формат кадра: verbose (текущий совместимый) или compact (минимизированные ключи).
  final SecureFrameFormat frameFormat;

  /// Размер блока для padding (байт). Если null — padding отключен.
  final int? paddingBlockSize;

  /// Максимальное число блоков padding (0..maxPaddingBlocks). Игнорируется если paddingBlockSize == null.
  final int maxPaddingBlocks;

  /// Удалять ли transportId из каждого кадра (экономия, но снижает самодокументированность). Используется только в compact формате.
  final bool removeTransportId;

  /// Удалять ли protocol поле из каждого кадра (опираемся на handshake). Только compact.
  final bool removeProtocol;

  /// Максимальное число сообщений, которые буферизуются до завершения handshake.
  ///
  /// Значение `0` отключает буферизацию и приводит к немедленному отклонению
  /// любого сообщения до завершения аутентификации.
  final int pendingHandshakeMessageLimit;
}

/// Holds the long-term identity material used by the secure overlay.
class SecureTransportKeyStore {
  const SecureTransportKeyStore({
    required this.keyPair,
    this.peerPublicKey,
    this.transportId = '',
  }) : assert(
          peerPublicKey != null || keyPair.publicKey != null,
          'SecureTransportKeyStore requires either peerPublicKey or keyPair.publicKey',
        );

  /// Identifier advertised to the remote peer.
  final String transportId;

  /// Local identity key pair used for handshake signing and advertisement.
  final LicensifyKeyPair keyPair;

  /// Local signing key used to produce handshake tokens.
  LicensifyPrivateKey get privateKey => keyPair.privateKey;

  /// Local public key advertised to remote peers when they don't have it cached.
  LicensifyPublicKey? get publicKey => keyPair.publicKey;

  /// Remote signing key used to validate handshake tokens.
  final LicensifyPublicKey? peerPublicKey;
}

enum _SecureFrameType { data, metadata }

class _SessionState {
  _SessionState({
    required this.sendKey,
    required this.recvKey,
    required this.assertion,
    required this.peerTransportId,
  });

  final LicensifySymmetricKey sendKey;
  final LicensifySymmetricKey recvKey;
  final String assertion;
  final String peerTransportId;

  void dispose() {
    sendKey.dispose();
    recvKey.dispose();
  }
}

class _DecryptedFrame {
  _DecryptedFrame(this.payload, this.type);

  final Uint8List payload;
  final _SecureFrameType type;
}

/// Wraps any [IRpcTransport] with a Licensify-backed encrypted overlay.
class SecureTransportAdapter implements IRpcTransport {
  SecureTransportAdapter._(
    this._inner,
    this._keyStore,
    this._config,
    this._logger,
  ) {
    _handshakeFuture = _performHandshake();
    _innerSubscription = _inner.incomingMessages.listen(
      (message) => unawaited(_processIncoming(message)),
      onError: (error, stackTrace) {
        if (!_incomingController.isClosed) {
          _incomingController.addError(error, stackTrace);
        }
      },
      onDone: () async {
        if (!_incomingController.isClosed) {
          await _incomingController.close();
        }
      },
    );
  }

  /// Wraps a transport instance with encryption.
  factory SecureTransportAdapter.wrap(
    IRpcTransport inner, {
    required SecureTransportKeyStore keyStore,
    SecureTransportConfig config = const SecureTransportConfig(),
    RpcLogger? logger,
  }) {
    return SecureTransportAdapter._(inner, keyStore, config, logger);
  }

  final IRpcTransport _inner;
  final SecureTransportKeyStore _keyStore;
  final SecureTransportConfig _config;
  final RpcLogger? _logger;

  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();
  final StreamController<_HandshakeEnvelope> _handshakeTokens =
      StreamController<_HandshakeEnvelope>();
  final List<RpcTransportMessage> _pendingMessages = <RpcTransportMessage>[];

  late final StreamSubscription<RpcTransportMessage> _innerSubscription;
  late final Future<_SessionState> _handshakeFuture;

  _SessionState? _session;
  bool _closed = false;
  int _outboundSequence = 0;
  int _expectedInboundSequence = 0;

  /// Exposes a future that completes when the secure channel is ready.
  Future<void> get ready async {
    await _handshakeFuture;
  }

  @override
  bool get isClient => _inner.isClient;

  @override
  bool get isClosed => _closed || _inner.isClosed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  int createStream() => _inner.createStream();

  @override
  bool releaseStreamId(int streamId) => _inner.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    final session = await _handshakeFuture;
    _logger?.debug(
        '[SecureTransportAdapter] Encrypting metadata for stream $streamId');
    final payload = _serializeMetadata(metadata);
    final token = await _encryptFrame(
      session: session,
      streamId: streamId,
      type: _SecureFrameType.metadata,
      payload: payload,
    );
    final wrappedMetadata = RpcMetadata([
      RpcHeader(_metadataHeader, token),
    ]);
    await _inner.sendMetadata(streamId, wrappedMetadata, endStream: endStream);
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    final session = await _handshakeFuture;
    _logger?.debug(
        '[SecureTransportAdapter] Encrypting payload for stream $streamId');
    final token = await _encryptFrame(
      session: session,
      streamId: streamId,
      type: _SecureFrameType.data,
      payload: data,
    );
    final tokenBytes = Uint8List.fromList(utf8.encode(token));
    final framed = RpcMessageFrame.encode(tokenBytes, compressed: false);
    await _inner.sendMessage(streamId, framed, endStream: endStream);
  }

  @override
  Future<void> finishSending(int streamId) async {
    // Вместо прямого делегирования во внутренний транспорт (которое
    // генерировало незашифрованный metadata end-of-stream кадр),
    // отправляем зашифрованный пустой metadata кадр с endStream=true.
    // Это сохраняет инвариант: все metadata после завершения handshake
    // проходят через шифрование.
    await sendMetadata(streamId, const RpcMetadata([]), endStream: true);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    await _innerSubscription.cancel();

    if (!_handshakeTokens.isClosed) {
      await _handshakeTokens.close();
    }

    final session = _session;
    if (session != null) {
      session.dispose();
    }

    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }

    await _inner.close();
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_closed) {
      return RpcHealthStatus.closed(
        component: 'SecureTransportAdapter',
        message: 'Secure transport closed',
        details: {
          'transportId': _keyStore.transportId,
        },
      );
    }

    if (_session == null) {
      return RpcHealthStatus.degraded(
        component: 'SecureTransportAdapter',
        message: 'Handshake pending',
        details: {
          'transportId': _keyStore.transportId,
        },
      );
    }

    final base = await _inner.health();
    return RpcHealthStatus(
      component: 'SecureTransportAdapter',
      level: base.level,
      message: base.message,
      details: {
        ...base.details,
        'transportId': _keyStore.transportId,
        'secure': true,
      },
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: 'SecureTransportAdapter',
      message: 'Reconnect is not supported by SecureTransportAdapter yet',
      details: {
        'transportId': _keyStore.transportId,
        'supported': false,
      },
    );
  }

  Future<void> _processIncoming(RpcTransportMessage message) async {
    if (_closed) return;

    if (message.metadata != null) {
      final token = message.metadata!.getHeaderValue(_handshakeHeader);
      if (token != null && !_handshakeTokens.isClosed) {
        final peerPublicKeyPaserk =
            message.metadata!.getHeaderValue(_handshakePeerKeyHeader);
        _handshakeTokens.add(
          _HandshakeEnvelope(
            token: token,
            streamId: message.streamId,
            isEndOfStream: message.isEndOfStream,
            peerPublicKeyPaserk: peerPublicKeyPaserk,
          ),
        );
        return;
      }
    }

    final session = _session;
    if (session == null) {
      final limit = _config.pendingHandshakeMessageLimit;
      if (limit == 0 || _pendingMessages.length >= limit) {
        _logger?.warning(
          '[SecureTransportAdapter] Dropping pre-handshake message and closing connection '
          '(streamId=${message.streamId}, buffered=${_pendingMessages.length}, limit=$limit)',
        );
        unawaited(close());
        return;
      }

      _pendingMessages.add(message);
      return;
    }

    await _deliverProtectedMessage(message, session);
  }

  Future<_SessionState> _performHandshake() async {
    try {
      final result = _inner.isClient
          ? await _performCallerHandshake()
          : await _performResponderHandshake();
      _session = result;
      _flushPendingMessages();
      return result;
    } catch (error, stackTrace) {
      _logger?.error('Secure handshake failed: $error',
          error: error, stackTrace: stackTrace);
      if (!_incomingController.isClosed) {
        _incomingController.addError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<_SessionState> _performCallerHandshake() async {
    final seedCaller = _randomBytes(32);
    final nonceCaller = _randomBytes(24);

    final handshakeStreamId = _inner.createStream();

    final helloLicense = await Licensify.createLicense(
      privateKey: _keyStore.privateKey,
      appId: 'rpc.secure',
      expirationDate: DateTime.now().toUtc().add(_config.handshakeTokenTtl),
      type: LicenseType.standard,
      features: {
        'protocol': _protocolLabel,
        'nonce': base64Encode(nonceCaller),
      },
      metadata: {
        'seed': base64Encode(seedCaller),
        'transportId': _keyStore.transportId,
      },
    );

    final helloToken = helloLicense.token;
    await _inner.sendMetadata(
      handshakeStreamId,
      _buildHandshakeMetadata(helloToken),
      endStream: true,
    );

    final ackEnvelope = await _waitForHandshakeToken();
    if (ackEnvelope.streamId != handshakeStreamId) {
      throw StateError('Responder returned handshake on unexpected stream');
    }
    final ackToken = ackEnvelope.token;
    final ackResolution =
        _resolvePeerPublicKey(ackEnvelope, peerRole: 'Responder');
    late final License ack;
    try {
      ack = await Licensify.fromToken(
        token: ackToken,
        publicKey: ackResolution.key,
      );
    } finally {
      if (ackResolution.owned) {
        ackResolution.key.dispose();
      }
    }

    final ackFeatures = await ack.features;
    final ackMetadata = await ack.metadata ?? <String, dynamic>{};

    _ensureProtocol(ackFeatures['protocol']);

    final peerNonceBase64 = ackMetadata['peerNonce'] as String?;
    if (peerNonceBase64 == null ||
        peerNonceBase64 != base64Encode(nonceCaller)) {
      throw StateError('Responder returned unexpected peer nonce');
    }

    final seedResponderBase64 = ackMetadata['seed'] as String?;
    if (seedResponderBase64 == null) {
      throw StateError('Responder did not provide seed');
    }

    final transportId = ackMetadata['transportId'] as String?;
    if (transportId == null) {
      throw StateError('Responder did not provide transportId');
    }

    final seedResponder = Uint8List.fromList(base64Decode(seedResponderBase64));
    final nonceResponderBase64 = ackFeatures['nonce'] as String?;
    if (nonceResponderBase64 == null) {
      throw StateError('Responder did not provide nonce');
    }

    final nonceResponder =
        Uint8List.fromList(base64Decode(nonceResponderBase64));

    final secretMaterial = Uint8List.fromList([
      ...seedCaller,
      ...seedResponder,
      ...nonceCaller,
      ...nonceResponder,
    ]);

    final sendKeyBytes =
        _hkdf(secretMaterial, info: utf8.encode(_infoCallerToResponder));
    final recvKeyBytes =
        _hkdf(secretMaterial, info: utf8.encode(_infoResponderToCaller));

    final sendKey = Licensify.encryptionKeyFromBytes(keyBytes: sendKeyBytes);
    final recvKey = Licensify.encryptionKeyFromBytes(keyBytes: recvKeyBytes);

    final handshakeHash = _computeHandshakeHash(helloToken, ackToken);

    final session = _SessionState(
      sendKey: sendKey,
      recvKey: recvKey,
      assertion: base64Encode(handshakeHash),
      peerTransportId: transportId,
    );

    if (!ackEnvelope.isEndOfStream) {
      unawaited(_inner.finishSending(handshakeStreamId));
    }

    return session;
  }

  Future<_SessionState> _performResponderHandshake() async {
    final helloEnvelope = await _waitForHandshakeToken();
    final handshakeStreamId = helloEnvelope.streamId;
    final helloToken = helloEnvelope.token;
    final helloResolution =
        _resolvePeerPublicKey(helloEnvelope, peerRole: 'Caller');
    late final License hello;
    try {
      hello = await Licensify.fromToken(
        token: helloToken,
        publicKey: helloResolution.key,
      );
    } finally {
      if (helloResolution.owned) {
        helloResolution.key.dispose();
      }
    }

    final helloFeatures = await hello.features;
    final helloMetadata = await hello.metadata ?? <String, dynamic>{};

    _ensureProtocol(helloFeatures['protocol']);

    final seedCallerBase64 = helloMetadata['seed'] as String?;
    if (seedCallerBase64 == null) {
      throw StateError('Caller did not include seed');
    }

    final transportId = helloMetadata['transportId'] as String?;
    if (transportId == null) {
      throw StateError('Caller did not include transportId');
    }

    final seedCaller = Uint8List.fromList(base64Decode(seedCallerBase64));
    final nonceCallerBase64 = helloFeatures['nonce'] as String?;
    if (nonceCallerBase64 == null) {
      throw StateError('Caller did not include nonce');
    }

    final nonceCaller = Uint8List.fromList(base64Decode(nonceCallerBase64));

    final seedResponder = _randomBytes(32);
    final nonceResponder = _randomBytes(24);

    final ackLicense = await Licensify.createLicense(
      privateKey: _keyStore.privateKey,
      appId: 'rpc.secure',
      expirationDate: DateTime.now().toUtc().add(_config.handshakeTokenTtl),
      type: LicenseType.standard,
      features: {
        'protocol': _protocolLabel,
        'nonce': base64Encode(nonceResponder),
      },
      metadata: {
        'seed': base64Encode(seedResponder),
        'peerNonce': base64Encode(nonceCaller),
        'transportId': _keyStore.transportId,
      },
    );

    final ackToken = ackLicense.token;

    await _inner.sendMetadata(
      handshakeStreamId,
      _buildHandshakeMetadata(ackToken),
      endStream: true,
    );

    final secretMaterial = Uint8List.fromList([
      ...seedCaller,
      ...seedResponder,
      ...nonceCaller,
      ...nonceResponder,
    ]);

    final sendKeyBytes =
        _hkdf(secretMaterial, info: utf8.encode(_infoResponderToCaller));
    final recvKeyBytes =
        _hkdf(secretMaterial, info: utf8.encode(_infoCallerToResponder));

    final sendKey = Licensify.encryptionKeyFromBytes(keyBytes: sendKeyBytes);
    final recvKey = Licensify.encryptionKeyFromBytes(keyBytes: recvKeyBytes);

    final handshakeHash = _computeHandshakeHash(helloToken, ackToken);

    final session = _SessionState(
      sendKey: sendKey,
      recvKey: recvKey,
      assertion: base64Encode(handshakeHash),
      peerTransportId: transportId,
    );

    if (!helloEnvelope.isEndOfStream) {
      unawaited(_inner.finishSending(handshakeStreamId));
    }

    return session;
  }

  Future<void> _deliverProtectedMessage(
    RpcTransportMessage message,
    _SessionState session,
  ) async {
    if (message.metadata != null) {
      final token = message.metadata!.getHeaderValue(_metadataHeader);
      if (token == null) {
        throw StateError('Received unprotected metadata on secure channel');
      }

      final decrypted = await _decryptFrame(
        token: token,
        session: session,
        streamId: message.streamId,
        expected: _SecureFrameType.metadata,
      );

      final metadata = _deserializeMetadata(decrypted.payload);
      _incomingController.add(
        RpcTransportMessage(
          metadata: metadata,
          streamId: message.streamId,
          isEndOfStream: message.isEndOfStream,
          methodPath: metadata.methodPath,
        ),
      );
      return;
    }

    if (message.payload != null) {
      final payload = message.payload!;
      if (payload.length < RpcConstants.messagePrefixSize) {
        throw StateError('Received truncated gRPC frame on secure channel');
      }

      final header = RpcMessageFrame.parseHeader(payload);
      if (header.isCompressed) {
        throw StateError('Compressed gRPC frames are not supported');
      }

      final expectedLength =
          RpcConstants.messagePrefixSize + header.messageLength;
      if (expectedLength != payload.length) {
        throw StateError(
          'Received gRPC frame with mismatched length on secure channel',
        );
      }

      final tokenBytes =
          payload.sublist(RpcConstants.messagePrefixSize, expectedLength);
      final token = utf8.decode(tokenBytes);
      final decrypted = await _decryptFrame(
        token: token,
        session: session,
        streamId: message.streamId,
        expected: _SecureFrameType.data,
      );

      _incomingController.add(
        RpcTransportMessage(
          payload: decrypted.payload,
          streamId: message.streamId,
          isEndOfStream: message.isEndOfStream,
        ),
      );
      return;
    }

    if (message.isEndOfStream) {
      _incomingController.add(
        RpcTransportMessage(
          streamId: message.streamId,
          isEndOfStream: true,
        ),
      );
    }
  }

  Future<_HandshakeEnvelope> _waitForHandshakeToken() async {
    try {
      return await _handshakeTokens.stream.first
          .timeout(_config.handshakeTimeout);
    } on TimeoutException catch (error) {
      throw StateError('Handshake timed out: ${error.message ?? ''}');
    }
  }

  ({LicensifyPublicKey key, bool owned}) _resolvePeerPublicKey(
    _HandshakeEnvelope envelope, {
    required String peerRole,
  }) {
    final configuredKey = _keyStore.peerPublicKey;
    final advertisedPaserk = envelope.peerPublicKeyPaserk;

    if (configuredKey != null) {
      if (advertisedPaserk != null) {
        final configuredPaserk = configuredKey.toPaserk();
        if (configuredPaserk != advertisedPaserk) {
          throw StateError(
            '$peerRole advertised unexpected public key',
          );
        }
      }
      return (key: configuredKey, owned: false);
    }

    if (advertisedPaserk == null) {
      throw StateError('$peerRole did not advertise public key');
    }

    return (
      key: LicensifyPublicKey.fromPaserk(paserk: advertisedPaserk),
      owned: true,
    );
  }

  RpcMetadata _buildHandshakeMetadata(String token) {
    final headers = <RpcHeader>[RpcHeader(_handshakeHeader, token)];
    final localPublicKey = _keyStore.publicKey;
    if (localPublicKey != null) {
      headers.add(
        RpcHeader(
          _handshakePeerKeyHeader,
          localPublicKey.toPaserk(),
        ),
      );
    }
    return RpcMetadata(headers);
  }

  Uint8List _serializeMetadata(RpcMetadata metadata) {
    final headers = metadata.headers
        .map((header) => {'name': header.name, 'value': header.value})
        .toList(growable: false);
    final jsonData = json.encode({'headers': headers});
    return Uint8List.fromList(utf8.encode(jsonData));
  }

  RpcMetadata _deserializeMetadata(Uint8List payload) {
    final jsonData = json.decode(utf8.decode(payload)) as Map<String, dynamic>;
    final headers = <RpcHeader>[];
    final rawHeaders = jsonData['headers'];
    if (rawHeaders is List) {
      for (final entry in rawHeaders) {
        if (entry is Map<String, dynamic>) {
          final name = entry['name'];
          final value = entry['value'];
          if (name is String && value is String) {
            headers.add(RpcHeader(name, value));
          }
        }
      }
    }
    return RpcMetadata(headers);
  }

  Future<String> _encryptFrame({
    required _SessionState session,
    required int streamId,
    required _SecureFrameType type,
    required Uint8List payload,
  }) async {
    final sequence = _outboundSequence++;

    Map<String, dynamic> frame;
    if (_config.frameFormat == SecureFrameFormat.verbose) {
      frame = <String, dynamic>{
        'payload': base64Encode(payload),
        'transportId': _keyStore.transportId,
        'streamId': streamId,
        'protocol': _protocolLabel,
        'sequence': sequence,
        'type': type.name,
      };
    } else {
      // compact format: shorter keys, optional omission of transportId / protocol, optional padding
      final map = <String, dynamic>{
        't': type.index, // 0 metadata, 1 data
        'i': streamId,
        'q': sequence,
        'p': base64Encode(payload),
        'v': 1, // version of compact frame
      };
      if (!_config.removeTransportId) {
        map['x'] = _keyStore.transportId; // transport id
      }
      if (!_config.removeProtocol) {
        map['r'] = 1; // protocol marker (fixed 1 for rpc+secure/1)
      }
      // padding
      if (_config.paddingBlockSize != null && _config.paddingBlockSize! > 0) {
        final block = _config.paddingBlockSize!;
        final maxBlocks = _config.maxPaddingBlocks.clamp(0, 16);
        final blocks =
            maxBlocks == 0 ? 0 : Random.secure().nextInt(maxBlocks + 1);
        if (blocks > 0) {
          final padBytes = _randomBytes(block * blocks);
          map['d'] = base64Encode(padBytes); // d = dummy padding
          map['db'] = blocks; // number of blocks (for анализ, можно опустить)
        }
      }
      frame = map;
    }

    final token = await Licensify.encryptData(
      data: frame,
      encryptionKey: session.sendKey,
      implicitAssertion: session.assertion,
    );
    return token;
  }

  Future<_DecryptedFrame> _decryptFrame({
    required String token,
    required _SessionState session,
    required int streamId,
    required _SecureFrameType expected,
  }) async {
    final decoded = await Licensify.decryptData(
      encryptedToken: token,
      encryptionKey: session.recvKey,
      implicitAssertion: session.assertion,
    );

    // Distinguish formats by presence of 'payload' vs 'p'.
    bool compact = false;
    if (!decoded.containsKey('payload') && decoded.containsKey('p')) {
      compact = true;
    }

    late int frameStreamId;
    late int sequence;
    late _SecureFrameType type;
    Uint8List payloadBytes;

    if (!compact) {
      final protocol = decoded['protocol'];
      _ensureProtocol(protocol);

      final transportId = decoded['transportId'];
      if (transportId is! String || transportId != session.peerTransportId) {
        throw StateError('Unexpected transportId in secure frame');
      }

      final frameStreamIdVal = decoded['streamId'];
      if (frameStreamIdVal is! num) {
        throw StateError('Secure frame stream mismatch');
      }
      frameStreamId = frameStreamIdVal.toInt();

      final typeValue = decoded['type'];
      if (typeValue is! String) {
        throw StateError('Secure frame missing type');
      }

      type = _SecureFrameType.values.firstWhere(
        (value) => value.name == typeValue,
        orElse: () => throw StateError('Unknown secure frame type: $typeValue'),
      );

      final sequenceValue = decoded['sequence'];
      if (sequenceValue is! num) {
        throw StateError('Secure frame missing sequence');
      }
      sequence = sequenceValue.toInt();

      final payload = decoded['payload'];
      if (payload is! String) {
        throw StateError('Secure frame payload missing');
      }
      payloadBytes = Uint8List.fromList(base64Decode(payload));
    } else {
      // compact format parsing
      // protocol & transportId optionally omitted; rely on implicitAssertion binding.
      final version = decoded['v'];
      if (version != 1) {
        throw StateError('Unsupported compact frame version: $version');
      }
      final typeIdx = decoded['t'];
      if (typeIdx is! num ||
          typeIdx.toInt() < 0 ||
          typeIdx.toInt() >= _SecureFrameType.values.length) {
        throw StateError('Invalid compact frame type index: $typeIdx');
      }
      type = _SecureFrameType.values[typeIdx.toInt()];

      final streamVal = decoded['i'];
      if (streamVal is! num) {
        throw StateError('Compact frame missing stream id');
      }
      frameStreamId = streamVal.toInt();

      final seqVal = decoded['q'];
      if (seqVal is! num) {
        throw StateError('Compact frame missing sequence');
      }
      sequence = seqVal.toInt();

      if (!_config.removeTransportId) {
        final transportId = decoded['x'];
        if (transportId is! String || transportId != session.peerTransportId) {
          throw StateError('Unexpected transportId in compact frame');
        }
      }
      if (!_config.removeProtocol) {
        final protoMarker = decoded['r'];
        if (protoMarker != 1) {
          throw StateError('Invalid protocol marker in compact frame');
        }
      }
      final payloadStr = decoded['p'];
      if (payloadStr is! String) {
        throw StateError('Compact frame missing payload');
      }
      payloadBytes = Uint8List.fromList(base64Decode(payloadStr));
      // ignore padding fields: 'd' (dummy), 'db'
    }

    if (frameStreamId != streamId) {
      throw StateError('Secure frame stream mismatch');
    }

    if (type != expected) {
      throw StateError('Secure frame type mismatch');
    }

    if (sequence != _expectedInboundSequence) {
      throw StateError('Secure frame sequence mismatch');
    }
    _expectedInboundSequence++;

    return _DecryptedFrame(payloadBytes, type);
  }

  void _flushPendingMessages() {
    if (_session == null || _pendingMessages.isEmpty) {
      return;
    }

    final pending = List<RpcTransportMessage>.from(_pendingMessages);
    _pendingMessages.clear();

    for (final message in pending) {
      unawaited(_deliverProtectedMessage(message, _session!));
    }
  }

  void _ensureProtocol(Object? value) {
    if (value is! String || value != _protocolLabel) {
      throw StateError('Unsupported secure protocol: $value');
    }
  }

  Uint8List _computeHandshakeHash(String helloToken, String ackToken) {
    final digest = sha256.convert(
      <int>[
        ...utf8.encode(helloToken),
        0,
        ...utf8.encode(ackToken),
      ],
    );
    return Uint8List.fromList(digest.bytes);
  }

  Uint8List _hkdf(
    Uint8List input, {
    required List<int> info,
    int length = 32,
  }) {
    final salt = List<int>.filled(sha256.blockSize, 0);
    final prk = Hmac(sha256, salt).convert(input).bytes;
    final hmac = Hmac(sha256, prk);

    final iterations = (length / sha256.convert(<int>[]).bytes.length).ceil();
    final okm = <int>[];
    var previous = <int>[];

    for (var i = 1; i <= iterations; i++) {
      final buffer = <int>[...previous, ...info, i];
      previous = hmac.convert(buffer).bytes;
      okm.addAll(previous);
    }

    return Uint8List.fromList(okm.sublist(0, length));
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) {
    throw UnimplementedError();
  }
}
