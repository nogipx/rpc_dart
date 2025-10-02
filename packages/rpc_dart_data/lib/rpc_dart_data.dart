/// Data service RPC toolkit: контракт, модели, клиент/серверные обёртки и фасад.
export 'src/data_caller.dart'
    show
        DataServiceCaller,
        OfflineCommandQueue,
        DataCommand; // низкоуровневый клиент
export 'src/data_contract.dart';
export 'src/data_repository.dart'
    show
        DataRepository,
        DataStorageAdapter,
        BaseDataRepository,
        InMemoryDataRepository,
        InMemoryStorageAdapter;
export 'src/data_responder.dart'
    show DataServiceResponder; // низкоуровневый респондёр
export 'src/data_service_facade.dart'
    show
        DataService,
        DataServiceClient,
        DataServiceServer,
        DataServiceFactory,
        InMemoryDataServiceEnvironment;
export 'src/models.dart';
// Сохранён старый базовый файл для совместимости (пока пустой публичный API там не нужен)
export 'src/rpc_dart_data_base.dart';

// TODO: Export any libraries intended for clients of this package.
