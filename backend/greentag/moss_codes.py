"""Moss retrieval — the single source of truth for building-code lookup.

This module is imported DIRECTLY by:
  - the LiveKit voice agent (hot path — must stay in-process for sub-10ms feel)
  - the FastAPI app (test / iOS fallback)

Both call the same `lookup_code()`; there is no second implementation. The
ingest pipeline calls `ingest_codes()` to (re)build the index offline.

All MossClient methods are async, so everything here is `async`.
"""
from __future__ import annotations

from functools import lru_cache

from moss import DocumentInfo, MossClient, MutationOptions, QueryOptions

from .config import MOSS_INDEX, moss_credentials

# Hybrid retrieval weight: 1.0 = pure semantic, 0.0 = pure keyword.
# 0.6 keeps semantics while still matching exact tokens like "R602.3(5)".
DEFAULT_ALPHA = 0.6

# The model/base code every city adopts. A city query always pools its own
# chunks WITH this base, so cities that didn't amend a rule fall back to it.
BASE_CITY = "IRC (model)"

# Tracks whether load_index() has run this process (load once, then query).
_state = {"loaded": False}


@lru_cache(maxsize=1)
def get_client() -> MossClient:
    """Process-wide Moss client (constructed once)."""
    project_id, project_key = moss_credentials()
    return MossClient(project_id, project_key)


def _doc_id(chunk: dict, index: int) -> str:
    """Stable, readable document id (id collisions = silent overwrite in Moss)."""
    city = chunk["city"].replace(" ", "_").replace("(", "").replace(")", "")
    section = (chunk.get("section") or "R602").replace(" ", "")
    return f"{city}__{section}__{index}"


def chunks_to_documents(chunks: list[dict]) -> list[DocumentInfo]:
    """Map plain chunk dicts -> Moss DocumentInfo, carrying full metadata.

    Metadata (city/state/code/section/topic) is what the agent filters and
    cites on, so every field rides along with the vector.
    """
    docs: list[DocumentInfo] = []
    for i, c in enumerate(chunks):
        docs.append(
            DocumentInfo(
                id=_doc_id(c, i),
                text=c["text"],
                metadata={
                    "city": c["city"],
                    "state": c["state"],
                    "code": c["code"],
                    "section": c.get("section", ""),
                    "topic": c.get("topic", "wood stud spacing"),
                },
            )
        )
    return docs


async def ingest_codes(chunks: list[dict], *, rebuild: bool = True) -> int:
    """(Re)build the `building_codes` index from chunks. Returns doc count.

    rebuild=True  -> delete + create (idempotent; no duplicate docs on re-run)
    rebuild=False -> upsert into the existing index
    """
    client = get_client()
    docs = chunks_to_documents(chunks)
    if not docs:
        raise ValueError("Refusing to ingest 0 documents.")

    if rebuild:
        try:
            await client.delete_index(MOSS_INDEX)
        except Exception:
            pass  # index may not exist yet — fine
        await client.create_index(MOSS_INDEX, docs)
    else:
        await client.add_docs(MOSS_INDEX, docs, MutationOptions(upsert=True))

    _state["loaded"] = False  # force a reload before the next query
    return len(docs)


async def _ensure_loaded() -> None:
    if not _state["loaded"]:
        await get_client().load_index(MOSS_INDEX)
        _state["loaded"] = True


async def lookup_code(
    city: str, question: str, top_k: int = 3, alpha: float = DEFAULT_ALPHA
) -> list[dict]:
    """Retrieve top code chunks for `question`, applicable to `city`.

    The query pool is {city, BASE_CITY}: a city's own amendment wins when it's
    relevant, otherwise the IRC base rule surfaces. This mirrors how US code
    adoption works — cities inherit the model code and only override specifics.
    When `city` is the base itself (or falsy), only the base is queried.

    Returns a list of {id, score, text, metadata} dicts (highest score first).
    """
    client = get_client()
    await _ensure_loaded()

    cities = [city, BASE_CITY] if city and city != BASE_CITY else [BASE_CITY]
    options = QueryOptions(
        top_k=top_k,
        alpha=alpha,
        filter={"$and": [{"field": "city", "condition": {"$in": cities}}]},
    )
    result = await client.query(MOSS_INDEX, question, options)
    return [
        {"id": d.id, "score": d.score, "text": d.text, "metadata": d.metadata}
        for d in result.docs
    ]
