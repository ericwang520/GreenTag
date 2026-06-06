"""Turn one source's parsed segments into clean, self-contained code chunks.

Each chunk is one coherent rule or one flattened table (~100-400 words), with
the 6 schema fields. Numbers come straight from the parsed R602.3(5) table, so
chunks are grounded, not invented.
"""
from __future__ import annotations

import re

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


def flatten_studs_table(markdown: str) -> list[str]:
    """Flatten R602.3(5) data rows into readable per-size sentences.

    Falls back to a raw numeric dump for any row that doesn't fit the 7-column
    shape, rather than dropping the rule.
    """
    rows: list[str] = []
    for line in markdown.splitlines():
        if not line.lstrip().startswith("|"):
            continue
        cells = _cells(line)
        if not cells or not _SIZE_RE.match(cells[0]):
            continue
        size = _norm_size(cells[0])
        values = cells[1:]

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


def build_chunks(source: Source, segments) -> list[dict]:
    """Produce all chunks for one source.

    - If the source restates Table R602.3(5): one flattened-table chunk + one
      plain-language rule summary.
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
            chunks.append(
                _chunk(source, f"{source.code_base} R602.3(5)", "R602.3(5)", table_text)
            )
        chunks.append(
            _chunk(source, f"{source.code_base} R602.3", "R602.3", _summary_text(source))
        )
    else:
        code = f"{source.code_base} R602.3 (adopts IRC R602.3(5))"
        chunks.append(_chunk(source, code, "R602.3", _adoption_text(source)))

    return chunks
