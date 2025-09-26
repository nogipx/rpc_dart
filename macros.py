"""Custom MkDocs macros for RPC Dart documentation."""

from __future__ import annotations

import json
from urllib.error import URLError
from urllib.request import urlopen

PACKAGE_NAME = "rpc_dart"
SCORE_ENDPOINT = f"https://pub.dev/api/packages/{PACKAGE_NAME}/score"

def _format_number(value: int | None) -> str:
    if value is None:
        return "N/A"
    return f"{value:,}".replace(",", " ")

def _fetch_downloads() -> int | None:
    try:
        with urlopen(SCORE_ENDPOINT, timeout=5) as response:  # type: ignore[arg-type]
            data = json.load(response)
    except (URLError, TimeoutError, ValueError, json.JSONDecodeError):
        return None

    downloads = data.get("downloadCount30Days")
    if isinstance(downloads, int):
        return downloads
    try:
        return int(downloads)
    except (TypeError, ValueError):
        return None

def define_env(env) -> None:  # pragma: no cover - executed by mkdocs
    """Hook into the MkDocs macros plugin."""

    @env.macro  # type: ignore[attr-defined]
    def pub_downloads() -> str:
        """Return formatted download count for the package."""

        return _format_number(_fetch_downloads())

    @env.macro  # type: ignore[attr-defined]
    def pub_package_url() -> str:
        """Return the public pub.dev URL for the package."""

        return f"https://pub.dev/packages/{PACKAGE_NAME}"
