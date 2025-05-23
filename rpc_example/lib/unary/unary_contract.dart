import 'package:rpc_dart/rpc_dart.dart';

import 'unary_models.dart';

/// Базовый контракт для базовых операций
abstract base class BasicServiceContract extends OldRpcServiceContract {
  BasicServiceContract() : super('BasicService');

  @override
  void setup() {
    // Метод работы с примитивными числовыми значениями
    addUnaryRequestMethod<ComputeRequest, ComputeResult>(
      methodName: 'compute',
      handler: compute,
      argumentParser: ComputeRequest.fromJson,
      responseParser: ComputeResult.fromJson,
    );

    super.setup();
  }

  /// Абстрактный метод вычислений
  Future<ComputeResult> compute(ComputeRequest request);
}

/// Серверная реализация контракта базового сервиса
final class ServerBasicServiceContract extends BasicServiceContract {
  ServerBasicServiceContract();

  @override
  Future<ComputeResult> compute(ComputeRequest request) async {
    final value1 = request.value1;
    final value2 = request.value2;

    // Выполняем вычисления
    final sum = value1 + value2;
    final difference = value1 - value2;
    final product = value1 * value2;
    final quotient = value1 / value2;

    // Возвращаем результат
    return ComputeResult(
      sum: sum,
      difference: difference,
      product: product,
      quotient: quotient,
    );
  }
}

/// Клиентская реализация контракта базового сервиса
final class ClientBasicServiceContract extends BasicServiceContract {
  final RpcEndpoint _endpoint;

  // Принимаем эндпоинт, но НЕ регистрируем контракт автоматически
  // Это должно делаться явно через вызов registerServiceContract
  ClientBasicServiceContract(this._endpoint);

  @override
  Future<ComputeResult> compute(ComputeRequest request) async {
    return _endpoint
        .unaryRequest(serviceName: serviceName, methodName: 'compute')
        .call<ComputeRequest, ComputeResult>(
          request: request,
          responseParser: ComputeResult.fromJson,
        );
  }
}
