# Flexible Codec Usage in RPC Contracts

## 🎯 New Functionality

Now you can **specify codecs in any mode**, but the system automatically determines whether to use or ignore them for maximum performance.

## 💡 Key Benefits

- ✅ **Flexibility**: Can specify codecs "just in case"
- ✅ **Performance**: In zero-copy mode codecs are ignored automatically
- ✅ **Simplicity**: Same code works in different modes
- ✅ **Safety**: Validation prevents configuration errors

## 📋 Operation Modes

### 1. ZeroCopy Mode (forced)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  @override
  void setup() {
    // ✅ Codecs specified but will be ignored for performance
    addUnaryMethod<String, String>(
      methodName: 'echo',
      requestCodec: myStringCodec,  // 👈 Ignored
      responseCodec: myStringCodec, // 👈 Ignored
      handler: (request, {context}) => Future.value('Echo: $request'),
    );
  }
}
```

### 2. Codec Mode (forced)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.codec);
  
  @override
  void setup() {
    // ✅ Codecs REQUIRED and used for serialization
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      requestCodec: myRequestCodec,  // ← Required!
      responseCodec: myResponseCodec, // ← Required!
      handler: (request, {context}) => processRequest(request),
    );
  }
}
```

### 3. Auto Mode (automatic)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.auto);
  
  @override
  void setup() {
    // Zero-copy method (no codecs specified)
    addUnaryMethod<String, String>(
      methodName: 'fastEcho',
      handler: (request, {context}) => Future.value('Fast: $request'),
    );
    
    // Codec method (codecs specified)
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      requestCodec: myRequestCodec,
      responseCodec: myResponseCodec,
      handler: (request, {context}) => processRequest(request),
    );
  }
}
```

## 🔧 Technical Implementation

### How It Works

1. **Mode Determination**: System analyzes contract's `dataTransferMode`
2. **Getting Effective Codecs**: Calls `_getEffectiveCodecs()`
3. **Applying Logic**:
   - `zeroCopy` mode → codecs nullified (`null`)
   - `codec` mode → codecs used as is
   - `auto` mode → depends on codec presence

### Implementation Methods

```dart
// Determines mode based on contract settings
bool _determineTransferMode<TRequest, TResponse>(
  IRpcCodec<TRequest>? requestCodec,
  IRpcCodec<TResponse>? responseCodec,
) {
  switch (dataTransferMode) {
    case RpcDataTransferMode.zeroCopy:
      return true; // Always zero-copy
    case RpcDataTransferMode.codec:
      return false; // Always codec
    case RpcDataTransferMode.auto:
      return requestCodec == null && responseCodec == null; // Auto
  }
}

// Returns actually used codecs
(IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getEffectiveCodecs<TRequest, TResponse>(
  IRpcCodec<TRequest>? requestCodec,
  IRpcCodec<TResponse>? responseCodec,
) {
  final isZeroCopy = _determineTransferMode(requestCodec, responseCodec);
  
  if (isZeroCopy) {
    return (null, null); // Ignore codecs
  } else {
    return (requestCodec, responseCodec); // Use codecs
  }
}
```

## ⚠️ Validation

### Codec Mode
- **Requires**: Both codecs (request + response)
- **Error**: If any codec is missing

### Auto Mode  
- **For codec**: Requires both codecs or none
- **Error**: If only one codec specified

### ZeroCopy Mode
- **Allows**: Any codecs (ignored)
- **Optimization**: Automatic nullification for performance

## 🚀 Usage Examples

### Universal Contract
```dart
class UniversalContract extends RpcResponderContract {
  UniversalContract({
    required RpcDataTransferMode mode,
  }) : super('UniversalService', dataTransferMode: mode);
  
  @override
  void setup() {
    // Same code works in all modes!
    addUnaryMethod<String, String>(
      methodName: 'echo',
      requestCodec: stringCodec,  // Used in codec, ignored in zeroCopy
      responseCodec: stringCodec,
      handler: (request, {context}) => Future.value('Echo: $request'),
    );
  }
}

// Usage:
final zeroCopyContract = UniversalContract(mode: RpcDataTransferMode.zeroCopy);
final codecContract = UniversalContract(mode: RpcDataTransferMode.codec);
```

### Client Contracts
```dart
class FlexibleClient extends RpcCallerContract {
  FlexibleClient(RpcCallerEndpoint endpoint, {
    RpcDataTransferMode mode = RpcDataTransferMode.auto,
  }) : super('MyService', endpoint, dataTransferMode: mode);

  Future<String> echo(String message) {
    return callUnary<String, String>(
      methodName: 'echo',
      request: message,
      requestCodec: stringCodec,  // Ignored in zeroCopy
      responseCodec: stringCodec, // Ignored in zeroCopy
    );
  }
}
```

## 📊 Performance

| Mode | Codecs | Serialization | Performance |
|------|--------|---------------|-------------|
| `zeroCopy` | Specified | ❌ Ignored | 🚀 Maximum |
| `codec` | Specified | ✅ Used | 📦 Standard |
| `auto` | Not specified | ❌ Zero-copy | 🚀 Maximum |
| `auto` | Specified | ✅ Codec | 📦 Standard |

## 🎉 Conclusion

The new system provides **maximum flexibility** while maintaining **type safety** and **performance**. You can write universal code that adapts to different execution conditions. 