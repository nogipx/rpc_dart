// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';
import 'package:rpc_dart/rpc_dart.dart';

enum ChecksumAlgorithm { sha256 }

@immutable
class BlobDescriptor extends Equatable implements IRpcSerializable {
  const BlobDescriptor({
    required this.id,
    required this.collection,
    required this.length,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.contentType,
    this.checksum,
    this.metadata = const {},
    this.downloadUrl,
  });

  factory BlobDescriptor.fromJson(Map<String, dynamic> json) {
    return BlobDescriptor(
      id: json['id'] as String,
      collection: json['collection'] as String,
      length: json['length'] as int? ?? 0,
      version: json['version'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      contentType: json['contentType'] as String?,
      checksum: json['checksum'] as String?,
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? const {}),
      downloadUrl: json['downloadUrl'] as String?,
    );
  }

  final String id;
  final String collection;
  final int length;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? contentType;
  final String? checksum;
  final Map<String, String> metadata;
  final String? downloadUrl;

  @override
  List<Object?> get props => [
    id,
    collection,
    length,
    version,
    createdAt,
    updatedAt,
    contentType,
    checksum,
    metadata,
    downloadUrl,
  ];

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'collection': collection,
    'length': length,
    'version': version,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (contentType != null) 'contentType': contentType,
    if (checksum != null) 'checksum': checksum,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
  };
}

@immutable
class HeadBlobRequest extends Equatable implements IRpcSerializable {
  const HeadBlobRequest({required this.collection, required this.id});

  factory HeadBlobRequest.fromJson(Map<String, dynamic> json) =>
      HeadBlobRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
      );

  final String collection;
  final String id;

  @override
  List<Object?> get props => [collection, id];

  @override
  Map<String, dynamic> toJson() => {'collection': collection, 'id': id};
}

@immutable
class HeadBlobResponse extends Equatable implements IRpcSerializable {
  const HeadBlobResponse({this.descriptor});

  factory HeadBlobResponse.fromJson(Map<String, dynamic> json) =>
      HeadBlobResponse(
        descriptor: json['descriptor'] == null
            ? null
            : BlobDescriptor.fromJson(
                Map<String, dynamic>.from(json['descriptor'] as Map),
              ),
      );

  final BlobDescriptor? descriptor;

  @override
  List<Object?> get props => [descriptor];

  @override
  Map<String, dynamic> toJson() => {'descriptor': descriptor?.toJson()};
}

@immutable
class DeleteBlobRequest extends Equatable implements IRpcSerializable {
  const DeleteBlobRequest({
    required this.collection,
    required this.id,
    this.expectedVersion,
  });

  factory DeleteBlobRequest.fromJson(Map<String, dynamic> json) =>
      DeleteBlobRequest(
        collection: json['collection'] as String,
        id: json['id'] as String,
        expectedVersion: json['expectedVersion'] as int?,
      );

  final String collection;
  final String id;
  final int? expectedVersion;

  @override
  List<Object?> get props => [collection, id, expectedVersion];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
  };
}

@immutable
class DeleteBlobResponse extends Equatable implements IRpcSerializable {
  const DeleteBlobResponse({required this.deleted});

  factory DeleteBlobResponse.fromJson(Map<String, dynamic> json) =>
      DeleteBlobResponse(deleted: json['deleted'] as bool? ?? false);

  final bool deleted;

  @override
  List<Object?> get props => [deleted];

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

@immutable
class BulkHeadBlobRequest extends Equatable implements IRpcSerializable {
  const BulkHeadBlobRequest({required this.items});

  factory BulkHeadBlobRequest.fromJson(Map<String, dynamic> json) =>
      BulkHeadBlobRequest(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) =>
                  HeadBlobRequest.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(growable: false),
      );

  final List<HeadBlobRequest> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

@immutable
class BulkHeadBlobResult extends Equatable implements IRpcSerializable {
  const BulkHeadBlobResult({
    required this.collection,
    required this.id,
    this.descriptor,
  });

  factory BulkHeadBlobResult.fromJson(Map<String, dynamic> json) =>
      BulkHeadBlobResult(
        collection: json['collection'] as String,
        id: json['id'] as String,
        descriptor: json['descriptor'] == null
            ? null
            : BlobDescriptor.fromJson(
                Map<String, dynamic>.from(json['descriptor'] as Map),
              ),
      );

  final String collection;
  final String id;
  final BlobDescriptor? descriptor;

  @override
  List<Object?> get props => [collection, id, descriptor];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    if (descriptor != null) 'descriptor': descriptor!.toJson(),
  };
}

@immutable
class BulkHeadBlobResponse extends Equatable implements IRpcSerializable {
  const BulkHeadBlobResponse({required this.items});

  factory BulkHeadBlobResponse.fromJson(Map<String, dynamic> json) =>
      BulkHeadBlobResponse(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) => BulkHeadBlobResult.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(growable: false),
      );

  final List<BulkHeadBlobResult> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

@immutable
class BulkDeleteBlobRequest extends Equatable implements IRpcSerializable {
  const BulkDeleteBlobRequest({required this.items});

  factory BulkDeleteBlobRequest.fromJson(Map<String, dynamic> json) =>
      BulkDeleteBlobRequest(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) => DeleteBlobRequest.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(growable: false),
      );

  final List<DeleteBlobRequest> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

@immutable
class BulkDeleteBlobResult extends Equatable implements IRpcSerializable {
  const BulkDeleteBlobResult({
    required this.collection,
    required this.id,
    required this.deleted,
  });

  factory BulkDeleteBlobResult.fromJson(Map<String, dynamic> json) =>
      BulkDeleteBlobResult(
        collection: json['collection'] as String,
        id: json['id'] as String,
        deleted: json['deleted'] as bool? ?? false,
      );

  final String collection;
  final String id;
  final bool deleted;

  @override
  List<Object?> get props => [collection, id, deleted];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    'deleted': deleted,
  };
}

@immutable
class BulkDeleteBlobResponse extends Equatable implements IRpcSerializable {
  const BulkDeleteBlobResponse({required this.items});

  factory BulkDeleteBlobResponse.fromJson(Map<String, dynamic> json) =>
      BulkDeleteBlobResponse(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) => BulkDeleteBlobResult.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(growable: false),
      );

  final List<BulkDeleteBlobResult> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

@immutable
class ListBlobsRequest extends Equatable implements IRpcSerializable {
  const ListBlobsRequest({
    required this.collection,
    this.cursor,
    this.limit = 50,
    this.prefix,
    this.includeMetadata = false,
  }) : assert(limit > 0, 'limit must be positive');

  factory ListBlobsRequest.fromJson(Map<String, dynamic> json) =>
      ListBlobsRequest(
        collection: json['collection'] as String,
        cursor: json['cursor'] as String?,
        limit: json['limit'] as int? ?? 50,
        prefix: json['prefix'] as String?,
        includeMetadata: json['includeMetadata'] as bool? ?? false,
      );

  final String collection;
  final String? cursor;
  final int limit;
  final String? prefix;
  final bool includeMetadata;

  @override
  List<Object?> get props => [
    collection,
    cursor,
    limit,
    prefix,
    includeMetadata,
  ];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'limit': limit,
    if (cursor != null) 'cursor': cursor,
    if (prefix != null) 'prefix': prefix,
    if (includeMetadata) 'includeMetadata': includeMetadata,
  };
}

@immutable
class ListBlobsResponse extends Equatable implements IRpcSerializable {
  const ListBlobsResponse({required this.items, this.nextCursor});

  factory ListBlobsResponse.fromJson(Map<String, dynamic> json) =>
      ListBlobsResponse(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) =>
                  BlobDescriptor.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(growable: false),
        nextCursor: json['nextCursor'] as String?,
      );

  final List<BlobDescriptor> items;
  final String? nextCursor;

  @override
  List<Object?> get props => [items, nextCursor];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
    if (nextCursor != null) 'nextCursor': nextCursor,
  };
}

@immutable
class GetBlobRequest extends Equatable implements IRpcSerializable {
  const GetBlobRequest({
    required this.collection,
    required this.id,
    this.rangeStart,
    this.rangeEnd,
  });

  factory GetBlobRequest.fromJson(Map<String, dynamic> json) => GetBlobRequest(
    collection: json['collection'] as String,
    id: json['id'] as String,
    rangeStart: json['rangeStart'] as int?,
    rangeEnd: json['rangeEnd'] as int?,
  );

  final String collection;
  final String id;
  final int? rangeStart;
  final int? rangeEnd;

  @override
  List<Object?> get props => [collection, id, rangeStart, rangeEnd];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    if (rangeStart != null) 'rangeStart': rangeStart,
    if (rangeEnd != null) 'rangeEnd': rangeEnd,
  };
}

/// Client-stream upload chunk. First chunk carries metadata; subsequent ones
/// may only set bytes/offset/last.
@immutable
class BlobUploadChunk extends Equatable implements IRpcSerializable {
  const BlobUploadChunk({
    required this.collection,
    required this.blobId,
    required this.offset,
    required this.bytes,
    this.totalLength,
    this.contentType,
    this.checksum,
    this.chunkChecksum,
    this.checksumAlgorithm,
    this.metadata = const {},
    this.expectedVersion,
    this.last = false,
  });

  factory BlobUploadChunk.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final byteData = _bytesFromJsonValue(raw);
    return BlobUploadChunk(
      collection: json['collection'] as String,
      blobId: json['blobId'] as String,
      offset: json['offset'] as int? ?? 0,
      bytes: byteData,
      totalLength: json['totalLength'] as int?,
      contentType: json['contentType'] as String?,
      checksum: json['checksum'] as String?,
      chunkChecksum: json['chunkChecksum'] as String?,
      checksumAlgorithm: _checksumAlgorithmFromJson(json['checksumAlgorithm']),
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? const {}),
      expectedVersion: json['expectedVersion'] as int?,
      last: json['last'] as bool? ?? false,
    );
  }

  final String collection;
  final String blobId;
  final int offset;
  final Uint8List bytes;
  final int? totalLength;
  final String? contentType;
  final String? checksum;
  final String? chunkChecksum;
  final ChecksumAlgorithm? checksumAlgorithm;
  final Map<String, String> metadata;
  final int? expectedVersion;
  final bool last;

  @override
  List<Object?> get props => [
    collection,
    blobId,
    offset,
    bytes,
    totalLength,
    contentType,
    checksum,
    chunkChecksum,
    checksumAlgorithm,
    metadata,
    expectedVersion,
    last,
  ];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'blobId': blobId,
    'offset': offset,
    'data': bytes,
    if (totalLength != null) 'totalLength': totalLength,
    if (contentType != null) 'contentType': contentType,
    if (checksum != null) 'checksum': checksum,
    if (chunkChecksum != null) 'chunkChecksum': chunkChecksum,
    if (checksumAlgorithm != null) 'checksumAlgorithm': checksumAlgorithm!.name,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
    if (last) 'last': last,
  };
}

/// Server-stream download frame: first frame can carry descriptor.
@immutable
class BlobDownloadFrame extends Equatable implements IRpcSerializable {
  const BlobDownloadFrame({
    required this.offset,
    required this.bytes,
    this.descriptor,
    this.rangeStart,
    this.rangeEnd,
    this.last = false,
  });

  factory BlobDownloadFrame.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    final byteData = _bytesFromJsonValue(raw);
    return BlobDownloadFrame(
      offset: json['offset'] as int? ?? 0,
      bytes: byteData,
      descriptor: json['descriptor'] == null
          ? null
          : BlobDescriptor.fromJson(
              Map<String, dynamic>.from(json['descriptor'] as Map),
            ),
      rangeStart: json['rangeStart'] as int?,
      rangeEnd: json['rangeEnd'] as int?,
      last: json['last'] as bool? ?? false,
    );
  }

  final int offset;
  final Uint8List bytes;
  final BlobDescriptor? descriptor;
  final int? rangeStart;
  final int? rangeEnd;
  final bool last;

  @override
  List<Object?> get props => [
    offset,
    bytes,
    descriptor,
    rangeStart,
    rangeEnd,
    last,
  ];

  @override
  Map<String, dynamic> toJson() => {
    'offset': offset,
    'data': bytes,
    if (descriptor != null) 'descriptor': descriptor!.toJson(),
    if (rangeStart != null) 'rangeStart': rangeStart,
    if (rangeEnd != null) 'rangeEnd': rangeEnd,
    if (last) 'last': last,
  };
}

@immutable
class PutBlobResponse extends Equatable implements IRpcSerializable {
  const PutBlobResponse({required this.descriptor});

  factory PutBlobResponse.fromJson(Map<String, dynamic> json) =>
      PutBlobResponse(
        descriptor: BlobDescriptor.fromJson(
          Map<String, dynamic>.from(json['descriptor'] as Map),
        ),
      );

  final BlobDescriptor descriptor;

  @override
  List<Object?> get props => [descriptor];

  @override
  Map<String, dynamic> toJson() => {'descriptor': descriptor.toJson()};
}

@immutable
class ListCollectionsResponse extends Equatable implements IRpcSerializable {
  const ListCollectionsResponse({required this.collections});

  factory ListCollectionsResponse.fromJson(Map<String, dynamic> json) =>
      ListCollectionsResponse(
        collections: List<String>.from(
          json['collections'] as List? ?? const [],
        ),
      );

  final List<String> collections;

  @override
  List<Object?> get props => [collections];

  @override
  Map<String, dynamic> toJson() => {'collections': collections};
}

@immutable
class ListCollectionsRequest extends Equatable implements IRpcSerializable {
  const ListCollectionsRequest();

  factory ListCollectionsRequest.fromJson(Map<String, dynamic> json) =>
      const ListCollectionsRequest();

  @override
  List<Object?> get props => const [];

  @override
  Map<String, dynamic> toJson() => const {};
}

@immutable
class DeleteCollectionRequest extends Equatable implements IRpcSerializable {
  const DeleteCollectionRequest({required this.collection});

  factory DeleteCollectionRequest.fromJson(Map<String, dynamic> json) =>
      DeleteCollectionRequest(collection: json['collection'] as String);

  final String collection;

  @override
  List<Object?> get props => [collection];

  @override
  Map<String, dynamic> toJson() => {'collection': collection};
}

@immutable
class DeleteCollectionResponse extends Equatable implements IRpcSerializable {
  const DeleteCollectionResponse({required this.deleted});

  factory DeleteCollectionResponse.fromJson(Map<String, dynamic> json) =>
      DeleteCollectionResponse(deleted: json['deleted'] as bool? ?? false);

  final bool deleted;

  @override
  List<Object?> get props => [deleted];

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

@immutable
class CollectionSizeRequest extends Equatable implements IRpcSerializable {
  const CollectionSizeRequest({required this.collection});

  factory CollectionSizeRequest.fromJson(Map<String, dynamic> json) =>
      CollectionSizeRequest(collection: json['collection'] as String);

  final String collection;

  @override
  List<Object?> get props => [collection];

  @override
  Map<String, dynamic> toJson() => {'collection': collection};
}

@immutable
class CollectionSizeResponse extends Equatable implements IRpcSerializable {
  const CollectionSizeResponse({required this.sizeBytes});

  factory CollectionSizeResponse.fromJson(Map<String, dynamic> json) =>
      CollectionSizeResponse(sizeBytes: json['size_bytes'] as int? ?? 0);

  final int sizeBytes;

  @override
  List<Object?> get props => [sizeBytes];

  @override
  Map<String, dynamic> toJson() => {'size_bytes': sizeBytes};
}

/// === Bulk operations ===

@immutable
class BulkPutBlobResponse extends Equatable implements IRpcSerializable {
  const BulkPutBlobResponse({required this.items});

  factory BulkPutBlobResponse.fromJson(Map<String, dynamic> json) =>
      BulkPutBlobResponse(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) =>
                  BlobDescriptor.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(growable: false),
      );

  final List<BlobDescriptor> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

@immutable
class BulkGetBlobRequest extends Equatable implements IRpcSerializable {
  const BulkGetBlobRequest({required this.items});

  factory BulkGetBlobRequest.fromJson(Map<String, dynamic> json) =>
      BulkGetBlobRequest(
        items: (json['items'] as List? ?? const [])
            .map(
              (e) =>
                  GetBlobRequest.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(growable: false),
      );

  final List<GetBlobRequest> items;

  @override
  List<Object?> get props => [items];

  @override
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(growable: false),
  };
}

/// Frame for bulk download: identifies blob and carries a regular download
/// frame as payload.
@immutable
class BulkBlobDownloadFrame extends Equatable implements IRpcSerializable {
  const BulkBlobDownloadFrame({
    required this.collection,
    required this.id,
    required this.frame,
  });

  factory BulkBlobDownloadFrame.fromJson(Map<String, dynamic> json) =>
      BulkBlobDownloadFrame(
        collection: json['collection'] as String,
        id: json['id'] as String,
        frame: BlobDownloadFrame.fromJson(
          Map<String, dynamic>.from(json['frame'] as Map),
        ),
      );

  final String collection;
  final String id;
  final BlobDownloadFrame frame;

  @override
  List<Object?> get props => [collection, id, frame];

  @override
  Map<String, dynamic> toJson() => {
    'collection': collection,
    'id': id,
    'frame': frame.toJson(),
  };
}

Uint8List _bytesFromJsonValue(Object? raw) {
  if (raw == null) {
    return Uint8List(0);
  }
  if (raw is Uint8List) {
    return raw;
  }
  if (raw is List<int>) {
    return Uint8List.fromList(raw);
  }
  throw ArgumentError.value(raw, 'data', 'Unsupported byte representation');
}

ChecksumAlgorithm? _checksumAlgorithmFromJson(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    switch (raw.toLowerCase()) {
      case 'sha256':
        return ChecksumAlgorithm.sha256;
    }
  }
  throw ArgumentError.value(
    raw,
    'checksumAlgorithm',
    'Unsupported checksum algorithm',
  );
}

extension Uint8ListStreamX on Stream<Uint8List> {
  /// Collect the entire byte stream into a single [Uint8List].
  Future<Uint8List> collectBytes() async {
    final builder = BytesBuilder();
    await for (final chunk in this) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
