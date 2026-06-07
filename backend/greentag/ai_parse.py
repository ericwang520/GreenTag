"""AI table parsing (offline, ingest-time only — never on the demo path).

Unsiloed's table markdown varies in layout (column order, footnotes, HTML vs
pipes), so positional code parsing is brittle. Here MiniMax reads the table and
returns a strict schema; we validate the numbers before trusting them. Parsed
once at ingest, stored on the Moss document — the demo never calls an LLM here.
"""
from __future__ import annotations

import json
import re

import requests

from .config import MINIMAX_BASE_URL, MINIMAX_MODEL, minimax_api_key

# Spacing values that are plausible for wood stud framing (sanity gate).
_PLAUSIBLE_SPACING = {12, 16, 24}
_SUPPORT_KEYS = {
    "roof_ceiling_only",
    "one_floor_roof_ceiling",
    "two_floors_roof_ceiling",
    "one_floor_only",
}

_PROMPT = """You are extracting building-code data from IRC/CRC Table R602.3(5)
"Size, Height and Spacing of Wood Studs". Convert the table below into JSON.

Return ONLY a JSON object of this exact shape (no prose, no markdown fence):
{
  "rows": [
    {"stud_size":"2x4","bearing":true,"max_height_ft":10,
     "supports":{"roof_ceiling_only":24,"one_floor_roof_ceiling":16,
                 "two_floors_roof_ceiling":null,"one_floor_only":24}},
    {"stud_size":"2x4","bearing":false,"max_height_ft":14,"max_spacing_in":24}
  ]
}
Rules:
- One bearing row and one non-bearing row per stud size.
- stud_size like "2x4","2x6" (lowercase x, no spaces).
- Spacing/height are integers (inches / feet). Use null where the table shows a
  dash or the configuration is not permitted. Strip footnote letters (24c -> 24).
- supports keys are exactly: roof_ceiling_only, one_floor_roof_ceiling,
  two_floors_roof_ceiling, one_floor_only.

TABLE:
"""


def _call_minimax(markdown: str) -> str:
    headers = {"Authorization": f"Bearer {minimax_api_key()}", "Content-Type": "application/json"}
    body = {
        "model": MINIMAX_MODEL,
        "messages": [{"role": "user", "content": _PROMPT + markdown}],
        "temperature": 0.0,
        # No max_tokens cap — M3 is a reasoning model; let it use what it needs.
    }
    resp = requests.post(MINIMAX_BASE_URL, headers=headers, json=body, timeout=90)
    resp.raise_for_status()
    data = resp.json()
    base = data.get("base_resp", {})
    if base.get("status_code") not in (0, None):
        raise RuntimeError(f"MiniMax error {base.get('status_code')}: {base.get('status_msg')}")
    return data["choices"][0]["message"]["content"]


def _extract_json(text: str) -> dict:
    text = text.strip()
    # Tolerate a ```json fence or surrounding prose.
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError(f"no JSON object in model output: {text[:200]}")
    return json.loads(m.group(0))


def _validate(rows: list[dict]) -> list[dict]:
    if not rows:
        raise ValueError("AI returned no rows")
    seen_spacing = False
    for r in rows:
        if not re.match(r"^\d+x\d+$", str(r.get("stud_size", ""))):
            raise ValueError(f"bad stud_size: {r.get('stud_size')!r}")
        if not isinstance(r.get("bearing"), bool):
            raise ValueError("bearing must be boolean")
        values = []
        if r["bearing"]:
            sup = r.get("supports") or {}
            if set(sup) - _SUPPORT_KEYS:
                raise ValueError(f"unexpected support keys: {set(sup) - _SUPPORT_KEYS}")
            values = [v for v in sup.values() if v is not None]
        else:
            v = r.get("max_spacing_in")
            values = [v] if v is not None else []
        for v in values:
            if not isinstance(v, int) or v not in _PLAUSIBLE_SPACING:
                raise ValueError(f"implausible spacing {v!r} (expected one of {_PLAUSIBLE_SPACING})")
            seen_spacing = True
    if not seen_spacing:
        raise ValueError("no plausible spacing value found in any row")
    return rows


def parse_table_with_ai(markdown: str) -> list[dict]:
    """Parse R602.3(5) markdown into validated structured rows via MiniMax.

    Raises on API error, malformed JSON, or values that fail the sanity gate —
    the caller decides whether to fall back to code parsing.
    """
    raw = _call_minimax(markdown)
    obj = _extract_json(raw)
    return _validate(obj.get("rows", []))
