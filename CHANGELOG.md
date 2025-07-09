## 2.1.0
- Added dispose base method to responder to cleanup resources

## 2.0.0
- Updated license to MIT
- Added logo to the package
- Added readme translations (RU, EN)

## 1.8.0
- Added ability to specify data transfer mode in contract (zero-copy, codec, auto)

## 1.7.0
- Added ability to specify whether transport supports Zero-Copy

## 1.6.0
- Added Zero-Copy optimization for `RpcInMemoryTransport` - object transfer without serialization/deserialization

## 1.5.0
- Added Transport Router for smart routing of RPC calls between transports
- Added typedef RpcRoutingCondition for typing routing condition functions
- Added support for routing rules with priorities (routeCall, routeWhen)
- Added conditional routing capability with access to RpcContext
- Added automatic validation of transport roles (client/server)
- Implemented correct Stream ID routing between transports
- Added router statistics and detailed logging
- Updated documentation with Transport Router usage examples
- `RpcLoggerSettings` -> `RpcLogger`
- `RpcContextPropagation` -> `RpcContext`

## 1.4.0
- Added RpcContext API with full gRPC-style context support
- Added support for headers, metadata, deadline and timeout
- Added distributed tracing support with trace ID
- Added `internal` logging level for library internal details
- Eliminated log duplication, library is "silent" by default
- Optimized InMemoryTransport for improved performance
- Fixed race conditions and deadlock situations
- Increased reliability of tests and CI/CD pipeline

## 1.3.2
- Removed auto-start of Responders
- Removed bundleId from `StreamDistributor`
- Updated documentation

## 1.3.1
- Optimized CBOR serializer and deserializer
- Added benchmarks for performance testing

## 1.3.0
- Updated documentation

## 1.2.2
- Added 1ms delay for data transfer stability

## 1.2.1
- Fixed specific errors in rpc-method operations (timeouts)

## 1.2.0
- Fixed critical bug with stream processing in Stream Processor
- Added explicit support for `bindToMessageStream()` method for manual stream binding
- Improved error handling in streams through gRPC statuses in metadata
- Fixed deadlock situations in client, server and bidirectional streams
- Optimized timeouts in tests for faster execution
- Improved documentation on working with streams and error handling
- Fixed issue with double stream listening in ClientStreamResponder

## 1.1.0
- Added `RpcStreamIdManager` for stream ID management

## 1.0.3
- CBOR serializer now works only with `Map<String, dynamic>`

## 1.0.2
- Added `StreamDistributor`
- Fixed linter issues

## 1.0.1
- Added subcontract registration
- Fixed unary method operations

## 1.0.0
- First stable release
- Implemented contract-based Backend-for-Domain (BFD) architecture
- Added support for all RPC types: unary calls, server streaming, client streaming, bidirectional streaming
- Added efficient CBOR serialization
- Added primitive types (String, Int, Double, Bool, Null) with operator support
- Implemented extensible logging system with color and level support
- Added universal transports: InMemoryTransport and IsolateTransport
- Implemented timeout handling and informative errors
- Main package contains only platform-independent transports, platform-specific ones will be available in separate packages

## 0.2.0
- Improved stream handling (BidiStream, ClientStreamingBidiStream, ServerStreamingBidiStream)
- Added support for diagnostic metrics and monitoring
- Improved marker handling in streams for more reliable interaction
- Added typed markers for various operations (stream completion, timeouts, etc.)
- Improved error handling and status transfer between client and server
- Optimized metadata handling in requests and responses
- Improved deadline and timeout handling in RPC operations
- Added operation cancellation mechanism

## 0.1.1

- Fixed error when registering contracts
- Added MsgPack serializer

## 0.1.0

- Initial release
