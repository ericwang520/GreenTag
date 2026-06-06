"""The chunks file (codes_chunks.json) as the source of truth for what's indexed.

The map reads this to know which cities are "green"; uploads merge into it so
state stays consistent with Moss. Kept separate from the batch pipeline so the
API stays thin.
"""
from __future__ import annotations

import json

from .config import CHUNKS_PATH
from .moss_codes import BASE_CITY


def load_chunks() -> list[dict]:
    if not CHUNKS_PATH.exists():
        return []
    return json.loads(CHUNKS_PATH.read_text())


def save_chunks(chunks: list[dict]) -> None:
    CHUNKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    CHUNKS_PATH.write_text(json.dumps(chunks, indent=2, ensure_ascii=False))


def upsert_city_chunks(city: str, new_chunks: list[dict]) -> list[dict]:
    """Replace a city's chunks with `new_chunks`; return the full merged set."""
    kept = [c for c in load_chunks() if c.get("city") != city]
    merged = kept + new_chunks
    save_chunks(merged)
    return merged


def list_cities() -> list[dict]:
    """Aggregate indexed jurisdictions for the map.

    Returns one entry per city: {city, state, code, chunks, is_base}.
    """
    by_city: dict[str, dict] = {}
    for c in load_chunks():
        city = c["city"]
        entry = by_city.setdefault(
            city,
            {
                "city": city,
                "state": c.get("state", ""),
                "code": c.get("code", ""),
                "chunks": 0,
                "is_base": city == BASE_CITY,
            },
        )
        entry["chunks"] += 1
    return sorted(by_city.values(), key=lambda e: (e["is_base"], e["city"]))
