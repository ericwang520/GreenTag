"""Source PDFs and their city/citation mapping. Edit here to add a city."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ..config import CODES_RAW_DIR


@dataclass(frozen=True)
class Source:
    filename: str       # under data/codes_raw/
    city: str           # metadata + query filter value
    state: str
    code_base: str      # citation prefix the agent will speak (e.g. "IRC")
    cache_key: str      # data/raw/<cache_key>.json
    skip: bool = False  # electrical = parsed/indexed never
    # How this jurisdiction adopts the base code — used when its PDF carries no
    # stud-spacing amendment (then the base R602.3(5) rule applies verbatim).
    adopts: str = "the model International Residential Code (IRC)"

    @property
    def path(self) -> Path:
        return CODES_RAW_DIR / self.filename


SOURCES: list[Source] = [
    Source("IRC_Chapter6_Wall_Construction.pdf", "IRC (model)", "US", "IRC", "irc"),
    Source(
        "2025_SFBC_Amendments.pdf", "San Francisco", "CA", "CRC", "san_francisco",
        adopts="the 2025 California Residential Code (CRC), which adopts IRC R602.3",
    ),
    Source("Seattle_RC_Chapter6.pdf", "Seattle", "WA", "Seattle RC", "seattle"),
    # Electrical code is irrelevant to framing — would pollute retrieval. SKIP.
    Source("2025_SF_Electrical_Code.pdf", "-", "-", "-", "sf_electrical", skip=True),
]


def active_sources() -> list[Source]:
    return [s for s in SOURCES if not s.skip]
