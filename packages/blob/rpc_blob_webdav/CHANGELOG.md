<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Changelog

## 1.0.0

- Initial release: `WebDavBlobRepository` — a WebDAV-backed `IBlobRepository`.
- Faithful `IBlobRepository`: content ranges, cursor pagination, per-blob
  version + timestamps + user metadata via WebDAV dead properties
  (PROPPATCH/PROPFIND) with graceful degradation.
- dart2js / VM / Flutter compatible (`package:http` + `package:xml`, no
  `dart:io`).
- Auth: HTTP Basic, Bearer, or none.
