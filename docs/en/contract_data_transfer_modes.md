# Centralized Data Transfer Mode Management

## Overview

RPC Dart contracts now provide centralized data transfer mode management through the constructor. This allows setting a unified strategy for all contract methods and ensures strict validation of codec compliance with the chosen mode.

## Data Transfer Modes

### `RpcDataTransferMode.zeroCopy`
- **Force zero-copy mode**
- All contract methods work without serialization
- Codecs MUST NOT be passed (validation error will occur)
- Works only with `RpcInMemoryTransport`

```dart
// Responder contract
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  @override
  void setup() {
    addUnaryMethod<String, String>(
      methodName: 'echo',
      handler: (request, {context}) async => 'Echo: $request',
      // DON'T specify codecs!
    );
  }
}

// Caller contract
final class MyCaller extends RpcCallerContract {
  MyCaller(RpcCallerEndpoint endpoint) 
      : super('MyService', endpoint, dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  Future<String> echo(String message) {
    return callUnary<String, String>(
      methodName: 'echo',
      request: message,
      // DON'T specify codecs!
    );
  }
}
```

### `RpcDataTransferMode.codec`
- **Force serialization mode**
- All contract methods work through codecs
- Codecs are REQUIRED for all methods (validation error if not specified)
- Works with any transports

```dart
// Responder contract
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.codec);
  
  @override
  void setup() {
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      handler: (request, {context}) async => MyResponse('Processed: ${request.data}'),
      requestCodec: MyRequest.codec,   // ← REQUIRED
      responseCodec: MyResponse.codec, // ← REQUIRED
    );
  }
}

// Caller contract
final class MyCaller extends RpcCallerContract {
  MyCaller(RpcCallerEndpoint endpoint) 
      : super('MyService', endpoint, dataTransferMode: RpcDataTransferMode.codec);
  
  Future<MyResponse> process(MyRequest request) {
    return callUnary<MyRequest, MyResponse>(
      methodName: 'process',
      request: request,
      requestCodec: MyRequest.codec,   // ← REQUIRED
      responseCodec: MyResponse.codec, // ← REQUIRED
    );
  }
}
```

### `RpcDataTransferMode.auto` (default)
- **Automatic mode selection**
- If codecs specified → use serialization
- If codecs NOT specified → use zero-copy
- Allows mixing modes in one contract
- Validation: either both codecs specified or both absent

```dart
// Responder contract with mixed modes
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.auto);
  
  @override
  void setup() {
    // Zero-copy method
    addUnaryMethod<String, String>(
      methodName: 'simpleEcho',
      handler: (request, {context}) async => 'Echo: $request',
      // Codecs NOT specified = zero-copy
    );
    
    // Codec method
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'complexProcess',
      handler: (request, {context}) async => MyResponse('Result'),
      requestCodec: MyRequest.codec,   // Codecs specified = codec
      responseCodec: MyResponse.codec,
    );
  }
}
```

## Validation

The system automatically validates codec compliance with the contract mode:

### Zero-copy mode
```dart
// ❌ ERROR - codecs passed in zero-copy mode
await caller.callUnary<MyRequest, MyResponse>(
  methodName: 'test',
  request: request,
  requestCodec: codec1,  // ← Error!
  responseCodec: codec2, // ← Error!
);
// Throws: "Contract configured for forced zero-copy mode..."
```

### Codec mode
```dart
// ❌ ERROR - codecs not passed in codec mode
await caller.callUnary<String, String>(
  methodName: 'test',
  request: 'hello',
  // Codecs absent in codec mode - error!
);
// Throws: "Contract configured for forced codec mode..."
```

### Auto mode
```dart
// ❌ ERROR - only one codec specified
await caller.callUnary<MyRequest, MyResponse>(
  methodName: 'test',
  request: request,
  requestCodec: codec1,  // ← Present
  // responseCodec absent ← Error!
);
// Throws: "In auto mode either both codecs must be specified..."
```

## Benefits

### 1. **Type Safety**
Centralized management prevents accidental configuration errors

### 2. **Consistency**
All contract methods use unified data transfer mode

### 3. **Explicitness**
Mode is explicitly specified in constructor, making code more readable

### 4. **Validation**
Automatic verification of codec compliance with chosen mode

### 5. **Flexibility**
Auto mode allows mixing approaches when justified

## Recommendations

### Use `zeroCopy` when:
- Working only with `RpcInMemoryTransport`
- Need maximum performance
- Data is simple (primitives, simple objects)

### Use `codec` when:
- Working with network transports
- Need data serialization
- Require compatibility with external systems

### Use `auto` when:
- Need flexibility in mode selection
- Different methods require different approaches
- Migrating between modes

## Complete Usage Example

See `example/more/contract_modes_example.dart` for detailed example of using all modes. 