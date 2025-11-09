"""Cloudflare cache management helpers."""
from __future__ import annotations

import logging
import os
from typing import Iterable, List, Tuple, Any

import requests

LOGGER = logging.getLogger(__name__)
API_BASE = "https://api.cloudflare.com/client/v4"


def _config() -> Tuple[str, str]:
    zone_id = (os.environ.get("CLOUDFLARE_ZONE_ID", "") or "").strip()
    token = (os.environ.get("CLOUDFLARE_API_TOKEN", "") or "").strip()
    return zone_id, token


def _normalize_domain(domain: str | None) -> str | None:
    if not domain:
        return None
    domain = domain.strip()
    if not domain:
        return None
    if not domain.startswith("http://") and not domain.startswith("https://"):
        domain = f"https://{domain}"
    return domain.rstrip("/")


def _build_full_url(domain: str | None, path: str) -> str | None:
    normalized = _normalize_domain(domain)
    if not normalized:
        return None
    return f"{normalized}/{path.lstrip('/')}"


class CloudflareService:
    """Wrapper around the Cloudflare purge API."""

    @staticmethod
    def purge_urls(urls: Iterable[str]) -> Tuple[bool, Any]:
        url_list = [u for u in urls if u]
        if not url_list:
            return True, "No URLs provided"

        zone_id, token = _config()
        if not zone_id or not token:
            return True, "Cloudflare not configured"

        endpoint = f"{API_BASE}/zones/{zone_id}/purge_cache"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

        try:
            response = requests.post(endpoint, headers=headers, json={"files": url_list}, timeout=15)
            response.raise_for_status()
            data = response.json()
            if data.get("success", True):
                return True, data
            return False, data.get("errors", data)
        except Exception as exc:  # noqa: BLE001
            LOGGER.exception("Cloudflare purge failed for %s", url_list)
            return False, str(exc)

    @staticmethod
    def playlist_urls(domain: str, tokens: Iterable[str]) -> List[str]:
        return [_build_full_url(domain, f"playlist/{token}.m3u8") for token in tokens]

    @staticmethod
    def channel_urls(domain: str, channel_id: str) -> List[str]:
        return [
            _build_full_url(domain, f"live/stream_{channel_id}.m3u8"),
            _build_full_url(domain, f"live/{channel_id}.m3u8"),
        ]
