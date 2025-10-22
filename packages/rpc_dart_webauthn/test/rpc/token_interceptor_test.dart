import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_webauthn/rpc_dart_webauthn.dart';
import 'package:test/test.dart';

class _TokenTestContract extends RpcResponderContract
    implements IRpcContract {
  _TokenTestContract() : super('TokenTest');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'SecuredEcho',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: securedEcho,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'PublicEcho',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: publicEcho,
    );
  }

  Future<RpcString> publicEcho(
    RpcString input, {
    RpcContext? context,
  }) async {
    return input;
  }

  Future<RpcString> securedEcho(
    RpcString input, {
    RpcContext? context,
  }) async {
    final header = context?.getHeader('authorization');
    if (header != 'Bearer fresh-token') {
      throw InvalidTokenException.expired();
    }

    return input;
  }
}

class _TokenTestCaller extends RpcCallerContract {
  _TokenTestCaller(RpcCallerEndpoint endpoint)
      : super('TokenTest', endpoint);

  Future<RpcString> publicEcho(RpcString message) {
    return endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: serviceName,
      methodName: 'PublicEcho',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
    );
  }

  Future<RpcString> securedEcho(RpcString message) {
    return endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: serviceName,
      methodName: 'SecuredEcho',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
    );
  }
}

class _MemoryTokenStore {
  WebAuthnTokenState? state;
}

void main() {
  group('WebAuthnTokenInterceptor', () {
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late _TokenTestCaller caller;
    late _MemoryTokenStore store;
    late int refreshCount;

    setUp(() async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      responderEndpoint.registerServiceContract(_TokenTestContract());
      await responderEndpoint.start();

      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      caller = _TokenTestCaller(callerEndpoint);

      store = _MemoryTokenStore();
      refreshCount = 0;

      callerEndpoint.addInterceptor(
        WebAuthnTokenInterceptor(
          tokenProvider: () async => store.state,
          refreshCallback: (expired, call) async {
            refreshCount++;
            return AuthResponse(
              accessToken: 'fresh-token',
              expiresIn: 60,
              userId: 'user-1',
            );
          },
          onTokenRefreshed: (state, response) async {
            store.state = state;
          },
          shouldRefreshOnError: (call, error) => true,
          onRefreshFailed: (_, __) {},
        ),
      );
    });

    tearDown(() async {
      await callerEndpoint.close();
      await responderEndpoint.close();
    });

    test('добавляет заголовок и не триггерит refresh для публичных методов',
        () async {
      final response = await caller.publicEcho('ping'.rpc);
      expect(response.value, 'ping');
      expect(refreshCount, 0);
    });

    test('обновляет токен если он просрочен до вызова', () async {
      store.state = WebAuthnTokenState(
        accessToken: 'expired-token',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        userId: 'user-1',
      );

      final response = await caller.securedEcho('data'.rpc);

      expect(response.value, 'data');
      expect(store.state!.accessToken, 'fresh-token');
      expect(refreshCount, 1);
    });

    test('повторяет запрос после refresh при ошибке авторизации', () async {
      store.state = WebAuthnTokenState(
        accessToken: 'stale-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        userId: 'user-1',
      );

      final response = await caller.securedEcho('retry'.rpc);

      expect(response.value, 'retry');
      expect(store.state!.accessToken, 'fresh-token');
      expect(refreshCount, 1);
    });
  });
}
