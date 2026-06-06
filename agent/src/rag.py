"""Moss RAG code-lookup interface — OWNED BY ERIC (data side).

This is the single seam between the data/RAG work and the voice agent. The
agent already imports and calls `lookup_code(...)` on every field observation
(see agent.py `speak`). Today it returns None, so the agent simply announces the
measurement and says it's "checking against local code". The moment Eric fills
in the body to return a CodeRequirement, the agent starts speaking the actual
pass/fail verdict and citing the clause — no other code changes needed.

CONTRACT (do not change field names/types without telling Xiya — this is the
agent-facing API, same spirit as schema.md):

    async def lookup_code(inspection_item: str, location: dict) -> CodeRequirement | None

  - inspection_item: e.g. "wood_stud_spacing" (snake_case, from the event)
  - location:        e.g. {"city": "San Francisco", "state": "CA"}
  - return None       -> no applicable clause found; agent stays tentative
  - return CodeRequirement -> agent announces verdict + cites it

Per schema.md: the standard MUST come from the spec library here. The agent
never trusts any "standard value" sent by the client.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger("agent.rag")


@dataclass
class CodeRequirement:
    """A retrieved code clause the agent can speak and judge against.

    Fill `max_spacing_in` when retrieval can resolve the single applicable limit
    for this observation's conditions — the agent then does a clean deterministic
    pass/fail. Leave it None to let the agent's LLM reason from `summary` instead.
    """

    citation: str  # e.g. "IRC R602.3(5)" — what the agent cites out loud
    summary: str  # one-line plain-English rule, e.g. "Studs 16 inches on center."
    max_spacing_in: float | None = None  # applicable max; pass if measured <= this
    source: str | None = None  # provenance for the dashboard, e.g. "2021 IRC + SF amds"


async def lookup_code(inspection_item: str, location: dict) -> CodeRequirement | None:
    """Query Moss RAG for the applicable code clause. ERIC IMPLEMENTS THIS.

    Steps (per schema.md step 1):
      1. Build a retrieval query from inspection_item + location.
      2. Query Moss, take the top clause.
      3. Map it into a CodeRequirement (citation + one-line summary; set
         max_spacing_in if the numeric limit is unambiguous).
      4. Return None if nothing relevant is found.

    Until implemented, returns None so the demo runs end-to-end without the RAG.
    """
    logger.info(
        "lookup_code not yet implemented; returning None (item=%s, location=%s)",
        inspection_item,
        location,
    )
    return None
