"""Structured stud-spacing thresholds — the deterministic, machine-readable half.

Where `moss_codes.lookup_code` returns prose for the voice agent to cite, this
returns a hard number (e.g. 16) the AR overlay can compare a measurement against
for a green/red verdict — no LLM interpretation needed.

There is no single "16 or 24": the max spacing is a function of stud size,
bearing vs non-bearing, what the wall supports, and height (per Table R602.3(5)).
Inputs that the AR payload doesn't carry (stud size, bearing, supports) come from
voice or a demo default. City resolves with the same IRC fallback as retrieval.
"""
from __future__ import annotations

from .config import SPACING_PATH
from .moss_codes import BASE_CITY
from .registry import load_spacing

# Load options for a bearing wall, matching Table R602.3(5)'s columns.
SUPPORTS = [
    "roof_ceiling_only",
    "one_floor_roof_ceiling",
    "two_floors_roof_ceiling",
    "one_floor_only",
]
DEFAULT_SUPPORTS = "one_floor_roof_ceiling"  # the common load-bearing demo case


def _norm_size(stud_size: str) -> str:
    return stud_size.lower().replace("×", "x").replace(" ", "")


def get_max_spacing(
    city: str,
    stud_size: str = "2x4",
    bearing: bool = True,
    supports: str = DEFAULT_SUPPORTS,
) -> dict:
    """Return the max on-center spacing (inches) for a wall configuration.

    Resolves `city` to its own table if present, else the IRC base. Returns a
    dict with max_spacing_in (None if the size isn't permitted for the config),
    max_height_ft, the code citation, and which city's table answered.
    """
    table = load_spacing()
    if not table:
        return {"error": f"no spacing table indexed (run the ingest pipeline). {SPACING_PATH}"}

    source_city = city if city in table else BASE_CITY
    entry = table.get(source_city) or table.get(BASE_CITY)
    if not entry:
        return {"error": f"no spacing data for {city!r} or base code"}

    size = _norm_size(stud_size)
    row = next(
        (r for r in entry["rows"] if r["stud_size"] == size and r["bearing"] == bearing),
        None,
    )

    result = {
        "city": city,
        "source_city": source_city,
        "fallback": source_city != city,
        "stud_size": size,
        "bearing": bearing,
        "supports": supports if bearing else None,
        "code": entry["code"],
        "section": entry["section"],
    }

    if row is None:
        result.update(
            {"max_spacing_in": None, "permitted": False,
             "note": f"No row for {size} ({'bearing' if bearing else 'non-bearing'}) in this table."}
        )
        return result

    if bearing:
        if supports not in SUPPORTS:
            result.update({"error": f"supports must be one of {SUPPORTS}"})
            return result
        value = row["supports"].get(supports)
        basis = f"{size} bearing wall supporting {supports.replace('_', ' ')}"
    else:
        value = row.get("max_spacing_in")
        basis = f"{size} non-bearing wall"

    result["max_height_ft"] = row["max_height_ft"]
    result["basis"] = basis
    if value is None:
        result.update(
            {"max_spacing_in": None, "permitted": False,
             "note": "Not permitted for this configuration — use a larger stud or add support."}
        )
    else:
        result.update({"max_spacing_in": value, "permitted": True})
    return result


def evaluate(measured_in: float, **kwargs) -> dict:
    """get_max_spacing(**kwargs) plus a pass/fail against a measured spacing.

    Pass = measured <= max (a tighter spacing than the maximum is always fine).
    """
    result = get_max_spacing(**kwargs)
    result["measured_in"] = measured_in
    mx = result.get("max_spacing_in")
    result["pass"] = (mx is not None) and (measured_in <= mx)
    return result
