"""Filter parsed segments down to wood stud-spacing content.

Precision over recall: a smaller clean set beats a noisy one. The OCR text
segments come back badly reordered, so the reliable signal is the structured
R602.3(5) table — that's what we anchor on.
"""
from __future__ import annotations

import re

# The R602.3(5) studs table is identifiable by its header columns. Other tables
# on the same pages (fastener schedule R602.3(1), sheathing R602.3(3)/(4),
# girder/header spans R602.7) mention "stud" too — exclude them by requiring
# BOTH the stud-size and bearing-wall column headers.
_STUDS_TABLE_HEADER = re.compile(r"STUD\s*SIZE", re.I)
_BEARING_HEADER = re.compile(r"BEARING\s*WALL", re.I)

# Keyword set for reporting which non-table segments touched stud spacing.
_STUD_KW = re.compile(
    r"\b(stud|R602\.3|on\s*center|o\.c\.|bearing wall|spacing of wood studs)\b", re.I
)


def find_studs_table(segments) -> str | None:
    """Return the markdown of the R602.3(5) studs table, or None.

    `segments` is an iterable of (segment_type, content, markdown, page).
    """
    for seg_type, content, markdown, _page in segments:
        if seg_type != "Table":
            continue
        body = markdown or content
        if _STUDS_TABLE_HEADER.search(body) and _BEARING_HEADER.search(body):
            return body
    return None


def stud_segment_count(segments) -> int:
    """How many segments mention stud spacing at all (for the drop report)."""
    return sum(
        1
        for _t, c, m, _p in segments
        if _STUD_KW.search(c or "") or _STUD_KW.search(m or "")
    )
