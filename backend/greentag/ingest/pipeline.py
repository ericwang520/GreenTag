"""Offline ingest pipeline: parse -> filter -> chunk -> write -> Moss -> verify.

This is a pre-demo batch job. It must never run on the live demo path.
"""
from __future__ import annotations

import json

import re

from ..config import CHUNKS_PATH, CODES_RAW_DIR
from ..moss_codes import ingest_codes, lookup_code
from ..registry import upsert_city_chunks
from ..unsiloed import iter_segments, parse_pdf
from .chunking import build_chunks
from .extract import stud_segment_count
from .sources import SOURCES, Source, active_sources


def build_all_chunks(*, force_parse: bool = False) -> tuple[list[dict], dict]:
    """Parse every active source and build chunks. Returns (chunks, report)."""
    chunks: list[dict] = []
    report: dict = {"per_city": {}, "skipped": [], "stud_segments": {}}

    for source in SOURCES:
        if source.skip:
            report["skipped"].append(source.filename)
            continue

    for source in active_sources():
        body = parse_pdf(source.path, source.cache_key, force=force_parse)
        segments = list(iter_segments(body))
        report["stud_segments"][source.city] = stud_segment_count(segments)
        city_chunks = build_chunks(source, segments)
        chunks.extend(city_chunks)
        report["per_city"][source.city] = len(city_chunks)

    return chunks, report


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or "city"


async def ingest_uploaded(
    pdf_bytes: bytes, city: str, state: str, code_base: str | None = None
) -> dict:
    """Parse one uploaded PDF for a new/updated city and add it to the index.

    Saves the PDF, parses it via Unsiloed, builds chunks, upserts them into
    Moss and the chunks registry. Returns {city, state, chunks}.
    """
    code_base = code_base or f"{city} RC"
    slug = _slug(city)
    pdf_path = CODES_RAW_DIR / f"upload_{slug}.pdf"
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    pdf_path.write_bytes(pdf_bytes)

    source = Source(pdf_path.name, city, state, code_base, f"upload_{slug}")
    body = parse_pdf(pdf_path, source.cache_key, force=True)
    chunks = build_chunks(source, list(iter_segments(body)))

    upsert_city_chunks(city, chunks)
    await ingest_codes(chunks, rebuild=False)  # upsert into existing index
    return {"city": city, "state": state, "chunks": len(chunks)}


def write_chunks(chunks: list[dict]) -> None:
    CHUNKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    CHUNKS_PATH.write_text(json.dumps(chunks, indent=2, ensure_ascii=False))


def _validate(chunks: list[dict]) -> list[str]:
    """Hard acceptance checks. Returns a list of failure messages (empty = OK)."""
    failures: list[str] = []
    fields = {"city", "state", "code", "section", "topic", "text"}

    # Every chunk has all 6 fields, non-empty.
    for i, c in enumerate(chunks):
        missing = [f for f in fields if not str(c.get(f, "")).strip()]
        if missing:
            failures.append(f"chunk {i} missing/empty fields: {missing}")

    # Electrical produced zero chunks.
    if any("electric" in c.get("code", "").lower() or c.get("city") == "-" for c in chunks):
        failures.append("electrical content leaked into chunks")

    # Each real city has >=1 chunk stating 16"/24" on center.
    for city in {c["city"] for c in chunks}:
        texts = " ".join(c["text"] for c in chunks if c["city"] == city).lower()
        if not (("16" in texts or "24" in texts) and ("on center" in texts or "o.c." in texts)):
            failures.append(f"{city}: no chunk states the 16/24 on-center rule")

    return failures


async def run_ingest(*, force_parse: bool = False, rebuild: bool = True) -> dict:
    """Full pipeline. Returns a verification report dict (also prints it)."""
    chunks, report = build_all_chunks(force_parse=force_parse)
    write_chunks(chunks)

    report["total_chunks"] = len(chunks)
    report["failures"] = _validate(chunks)
    report["chunks_path"] = str(CHUNKS_PATH)

    # Ingest into Moss (rebuild = idempotent).
    report["docs_ingested"] = await ingest_codes(chunks, rebuild=rebuild)

    # Live acceptance query: SF stud spacing should surface the 16" rule.
    sf_top = await lookup_code("San Francisco", "stud spacing for a load bearing wall")
    report["sf_query_top"] = sf_top[0] if sf_top else None

    _print_report(report)
    return report


def _print_report(r: dict) -> None:
    print("\n" + "=" * 68)
    print("GREENTAG INGEST — VERIFICATION REPORT")
    print("=" * 68)
    print(f"chunks written: {r['total_chunks']} -> {r['chunks_path']}")
    print(f"docs ingested into Moss 'building_codes': {r['docs_ingested']}")
    print("\nper-city chunk count:")
    for city, n in r["per_city"].items():
        seg = r["stud_segments"].get(city, "?")
        print(f"  - {city:16s} {n} chunk(s)   ({seg} stud-related segments parsed)")
    print(f"\nskipped (never indexed): {r['skipped']}")

    print("\nSF acceptance query — lookup_code('San Francisco', 'stud spacing for a load bearing wall'):")
    top = r["sf_query_top"]
    if top:
        md = top["metadata"]
        print(f"  TOP  score={top['score']:.4f}  city={md.get('city')}  code={md.get('code')}")
        print(f"       {top['text'][:200]}...")
    else:
        print("  !! no result")

    print("\nacceptance checks:", "PASS ✅" if not r["failures"] else "FAIL ❌")
    for f in r["failures"]:
        print(f"  - {f}")
    print("=" * 68 + "\n")
