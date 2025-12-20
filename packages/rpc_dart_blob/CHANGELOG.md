## 1.0.1

- S3 adapter now fetches object tags (`?tagging`) and merges them into `BlobDescriptor.metadata` without overwriting metadata provided on upload.
- Added `xml` dependency to parse S3 tag responses.

## 1.0.0

- Added `S3BlobStorageAdapter` (S3/MinIO/Ceph-compatible) storing blobs under `<prefix><collection>/<id>` with metadata-based versioning and optimistic checks.
- New `S3BlobStorageAdapter.connect(...)` helper for quick setup; list/Head/read/write/delete/listCollections wired to S3 operations; descriptors include a presigned download URL.
- README now documents S3/MinIO usage; pubspec updated with the MinIO client dependency.
- Initial version.
