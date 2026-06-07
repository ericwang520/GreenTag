"""Turn one source's parsed segments into clean, self-contained code chunks.

Each chunk is one coherent rule or one flattened table (~100-400 words), with
the 6 schema fields. Numbers come straight from the parsed R602.3(5) table, so
chunks are grounded, not invented.
"""
from __future__ import annotations

import json
import re

from ..ai_parse import parse_table_with_ai
from .extract import find_studs_table
from .sources import Source

# Column meaning of the R602.3(5) data rows (after the stud-size cell).
# Verified against the real IRC + Seattle parses: 7 value columns.
_BEARING_LABELS = [
    "up to {v} ft tall (laterally unsupported)",
    "max {v} in o.c. supporting a roof and ceiling only",
    "max {v} in o.c. supporting one floor plus roof and ceiling",
    "max {v} in o.c. supporting two floors plus roof and ceiling",
    "max {v} in o.c. supporting one floor only",
]
_NONBEARING_LABELS = [
    "up to {v} ft tall",
    "max {v} in o.c.",
]

_SIZE_RE = re.compile(r"^\s*\d+\s*[×xX]\s*\d+", re.I)


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _num(cell: str) -> str | None:
    """Leading integer of a cell, dropping footnote letters ('24c' -> '24')."""
    cell = cell.strip()
    if cell in ("", "—", "-", "–"):
        return None
    m = re.match(r"(\d+)", cell)
    return m.group(1) if m else None


def _norm_size(cell: str) -> str:
    return re.sub(r"\s*[×xX]\s*", "x", re.sub(r"[a-zA-Z].*$", "", cell).strip())


# Structured column keys for a bearing-wall row (after the height column).
SUPPORT_KEYS = [
    "roof_ceiling_only",
    "one_floor_roof_ceiling",
    "two_floors_roof_ceiling",
    "one_floor_only",
]


def _int(cell: str):
    n = _num(cell)
    return int(n) if n is not None and n.isdigit() else None


def _iter_data_rows(markdown: str):
    """Yield (normalized_size, [value cells]) for each R602.3(5) data row."""
    for line in markdown.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        cells = _cells(line)
        if not cells or not _SIZE_RE.match(cells[0]):
            continue
        yield _norm_size(cells[0]), cells[1:]


def parse_studs_table(markdown: str) -> list[dict]:
    """Parse R602.3(5) into structured rows (one bearing + one non-bearing per size).

    Columns (after stud size): height, roof+ceiling only, one floor+roof+ceiling,
    two floors+roof+ceiling, one floor only, non-bearing height, non-bearing spacing.
    """
    rows: list[dict] = []
    for size, values in _iter_data_rows(markdown):
        if len(values) < 7:
            continue
        rows.append({
            "stud_size": size,
            "bearing": True,
            "max_height_ft": _int(values[0]),
            "supports": {SUPPORT_KEYS[i]: _int(values[1 + i]) for i in range(4)},
        })
        rows.append({
            "stud_size": size,
            "bearing": False,
            "max_height_ft": _int(values[5]),
            "max_spacing_in": _int(values[6]),
        })
    return rows


def flatten_studs_table(markdown: str) -> list[str]:
    """Flatten R602.3(5) data rows into readable per-size sentences.

    Falls back to a raw numeric dump for any row that doesn't fit the 7-column
    shape, rather than dropping the rule.
    """
    rows: list[str] = []
    for size, values in _iter_data_rows(markdown):
        if len(values) >= 7:
            bearing = [
                lbl.format(v=_num(values[i]))
                for i, lbl in enumerate(_BEARING_LABELS)
                if _num(values[i]) is not None
            ]
            nonbearing = [
                lbl.format(v=_num(values[5 + i]))
                for i, lbl in enumerate(_NONBEARING_LABELS)
                if _num(values[5 + i]) is not None
            ]
            parts = []
            if bearing:
                parts.append("bearing walls: " + ", ".join(bearing))
            if nonbearing:
                parts.append("non-bearing walls: " + ", ".join(nonbearing))
            rows.append(f"{size} studs — " + "; ".join(parts) + ".")
        else:
            nums = [n for c in values if (n := _num(c))]
            if nums:
                rows.append(f"{size} studs — spacing/height values (in/ft): {', '.join(nums)}.")
    return rows


def _chunk(source: Source, code: str, section: str, text: str) -> dict:
    return {
        "city": source.city,
        "state": source.state,
        "code": code,
        "section": section,
        "topic": "wood stud spacing",
        "text": " ".join(text.split()),  # collapse whitespace; keep self-contained
    }


def _summary_text(source: Source) -> str:
    return (
        f"Per {source.code_base} Table R602.3(5), wood studs in load-bearing walls "
        "are spaced a maximum of 16 inches on center for the common case of a 2x4 "
        "stud supporting one floor plus a roof-ceiling assembly. Lighter loads "
        "(roof and ceiling only) and larger studs such as 2x6 may be spaced up to "
        "24 inches on center. Laterally unsupported bearing-wall studs are limited "
        "to about 10 feet in height. Non-bearing wall studs may be spaced up to 24 "
        "inches on center (up to 14 feet for 2x4). Utility-grade studs are limited "
        "to 16 inches on center. Whether 16 or 24 inches applies depends on stud "
        "size, wall height, and the loads carried."
    )


def _adoption_text(source: Source) -> str:
    return (
        f"{source.city} enforces its local building code together with {source.adopts}. "
        "The local amendments do not modify wood stud spacing (Section R602.3), so the "
        f"adopted base rule applies in {source.city}: studs in load-bearing walls are "
        "spaced a maximum of 16 inches on center (for example a 2x4 supporting one floor "
        "plus roof and ceiling), and may be spaced up to 24 inches on center for lighter "
        "loads or larger studs, per Table R602.3(5)."
    )


def _default_max_spacing(rows: list[dict]) -> int | None:
    """The headline number: 2x4 bearing wall supporting one floor + roof/ceiling.

    This is the common framing case (the 16" most contractors mean). Returns the
    smallest plausible value found if that exact cell is missing.
    """
    for r in rows:
        if r.get("stud_size") == "2x4" and r.get("bearing"):
            v = (r.get("supports") or {}).get("one_floor_roof_ceiling")
            if v:
                return v
    vals = [
        v for r in rows for v in (
            list((r.get("supports") or {}).values()) + [r.get("max_spacing_in")]
        ) if isinstance(v, int)
    ]
    return min(vals) if vals else None


def build_spacing_entry(source: Source, segments) -> dict | None:
    """Structured R602.3(5) for a source, or None if it has no studs table.

    AI-parses the table (robust to layout variation); falls back to positional
    code parsing if the AI call or its validation fails, so ingest never breaks.
    Cities without their own table fall back to the IRC base at query time.
    """
    table_md = find_studs_table(segments)
    if not table_md:
        return None

    method = "ai"
    try:
        rows = parse_table_with_ai(table_md)
    except Exception as exc:  # noqa: BLE001 — degrade gracefully, log which path
        print(f"  [spacing] AI parse failed for {source.city} ({exc}); using code parser")
        rows = parse_studs_table(table_md)
        method = "code"
    if not rows:
        return None

    return {
        "city": source.city,
        "state": source.state,
        "code": f"{source.code_base} R602.3(5)",
        "section": "R602.3(5)",
        "parsed_by": method,
        "default_max_spacing_in": _default_max_spacing(rows),
        "rows": rows,
    }


def build_chunks(source: Source, segments, spacing_entry: dict | None = None) -> list[dict]:
    """Produce all chunks for one source.

    - If the source restates Table R602.3(5): one flattened-table chunk + one
      plain-language rule summary. When `spacing_entry` is given, its structured
      fields ride on the table chunk into Moss metadata (per-city spacing fields).
    - If it doesn't (e.g. SF amendments don't touch studs): one "adopts base"
      chunk that states the applicable 16"/24" rule with its provenance.
    """
    chunks: list[dict] = []
    table_md = find_studs_table(segments)

    if table_md:
        rows = flatten_studs_table(table_md)
        if rows:
            table_text = (
                "Table R602.3(5) — Size, Height and Spacing of Wood Studs. " + " ".join(rows)
            )
            table_chunk = _chunk(
                source, f"{source.code_base} R602.3(5)", "R602.3(5)", table_text
            )
            if spacing_entry:
                # These become Moss metadata fields on this city's document.
                table_chunk["default_max_spacing_in"] = spacing_entry["default_max_spacing_in"]
                table_chunk["spacing_json"] = json.dumps(spacing_entry["rows"], separators=(",", ":"))
            chunks.append(table_chunk)
        chunks.append(
            _chunk(source, f"{source.code_base} R602.3", "R602.3", _summary_text(source))
        )
    else:
        code = f"{source.code_base} R602.3 (adopts IRC R602.3(5))"
        chunks.append(_chunk(source, code, "R602.3", _adoption_text(source)))

    return chunks
