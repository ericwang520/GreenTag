"""Unsiloed PDF parse client (offline ingest only — never on the demo path).

Submits a parse job, polls to completion, and caches the raw response under
data/raw/<key>.json so re-runs don't re-spend quota.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import requests

from .config import RAW_CACHE_DIR, unsiloed_api_key

BASE = "https://prod.visionapi.unsiloed.ai"

# Tuned for building-code PDFs with spacing tables.
PARSE_FORM = {
    "page_range": "1-20",                       # first ~20 pages = R602 + table
    "layout_analysis": "smart_layout_detection",
    "ocr_strategy": "auto_detection",
    "merge_tables": "true",                      # R602.3(5) may span a page break
    "validate_segments": json.dumps(["Table"]),
    "output_fields": json.dumps(
        {"markdown": True, "content": True, "ocr": False, "image": False,
         "bbox": False, "confidence": True}
    ),
}


def _headers(bearer: bool = False) -> dict:
    key = unsiloed_api_key()
    auth = {"Authorization": f"Bearer {key}"} if bearer else {"api-key": key}
    return {"accept": "application/json", **auth}


def _submit(pdf_path: Path) -> str:
    """POST /parse -> job_id. Tries `api-key`, falls back to Bearer on 401."""
    for bearer in (False, True):
        with open(pdf_path, "rb") as fh:
            files = {"file": (pdf_path.name, fh, "application/pdf")}
            resp = requests.post(
                f"{BASE}/parse", headers=_headers(bearer),
                files=files, data=PARSE_FORM, timeout=180,
            )
        if resp.status_code == 401 and not bearer:
            continue  # retry once with Bearer
        if resp.status_code == 402:
            raise RuntimeError(f"Unsiloed quota exhausted (402): {resp.text}")
        resp.raise_for_status()
        return resp.json()["job_id"]
    raise RuntimeError("Unsiloed auth failed (401 with both api-key and Bearer).")


def _poll(job_id: str, *, max_wait: int = 600, interval: int = 5) -> dict:
    """GET /parse/{job_id} until Succeeded. Honors Retry-After on 429/503."""
    deadline = time.time() + max_wait
    while time.time() < deadline:
        resp = requests.get(f"{BASE}/parse/{job_id}", headers=_headers(), timeout=60)
        if resp.status_code in (429, 503):
            time.sleep(int(resp.headers.get("Retry-After", interval)))
            continue
        resp.raise_for_status()
        body = resp.json()
        status = body.get("status")
        if status == "Succeeded":
            return body
        if status == "Failed":
            raise RuntimeError(f"Unsiloed parse failed: {body.get('message', '?')}")
        time.sleep(interval)
    raise TimeoutError(f"Unsiloed polling timed out for job {job_id}.")


def parse_pdf(pdf_path: str | Path, cache_key: str, *, force: bool = False) -> dict:
    """Parse a PDF (cached). Returns the full Succeeded job body.

    Iterate results via body["chunks"][i]["segments"][j], each segment having
    segment_type / content / markdown / page_number.
    """
    RAW_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = RAW_CACHE_DIR / f"{cache_key}.json"
    if cache.exists() and not force:
        return json.loads(cache.read_text())

    job_id = _submit(Path(pdf_path))
    body = _poll(job_id)
    cache.write_text(json.dumps(body, indent=2))
    return body


def iter_segments(body: dict):
    """Yield (segment_type, content, markdown, page_number) for every segment."""
    for chunk in body.get("chunks", []):
        for seg in chunk.get("segments", []):
            yield (
                seg.get("segment_type", ""),
                seg.get("content", "") or "",
                seg.get("markdown", "") or "",
                seg.get("page_number"),
            )
