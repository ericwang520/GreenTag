"""Offline ingest pipeline: parse -> filter -> chunk -> write -> Moss -> verify.

This is a pre-demo batch job. It must never run on the live demo path.
"""
from __future__ import annotations

import json

import re

from ..config import CHUNKS_PATH, CODES_RAW_DIR, SPACING_PATH
from ..moss_codes import ingest_codes, lookup_code
from ..registry import upsert_city_chunks, upsert_spacing_entry
from ..unsiloed import iter_segments, parse_pdf
from .chunking import build_chunks, build_spacing_entry
from .extract import stud_segment_count
from .sources import SOURCES, Source, active_sources


def build_all_chunks(*, force_parse: bool = False) -> tuple[list[dict], dict, dict]:
    """Parse every active source. Returns (chunks, spacing_table, report).

    chunks        prose for voice RAG
    spacing_table {city: structured R602.3(5)} for the AR overlay
    """
    chunks: list[dict] = []
    spacing_table: dict = {}
    report: dict = {"per_city": {}, "skipped": [], "stud_segments": {}}

    for source in SOURCES:
        if source.skip:
            report["skipped"].append(source.filename)
            continue

    for source in active_sources():
        body = parse_pdf(source.path, source.cache_key, force=force_parse)
        segments = list(iter_segments(body))
        report["stud_segments"][source.city] = stud_segment_count(segments)
        entry = build_spacing_entry(source, segments)  # AI parse once
        if entry:
            spacing_table[source.city] = entry
        city_chunks = build_chunks(source, segments, spacing_entry=entry)
        chunks.extend(city_chunks)
        report["per_city"][source.city] = len(city_chunks)

    return chunks, spacing_table, report


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
    segments = list(iter_segments(body))
    entry = build_spacing_entry(source, segments)  # AI parse once
    chunks = build_chunks(source, segments, spacing_entry=entry)

    upsert_city_chunks(city, chunks)
    await ingest_codes(chunks, rebuild=False)  # upsert into existing index
    upsert_spacing_entry(city, entry)  # None removes any stale structured table

    return {
        "city": city, "state": state, "chunks": len(chunks),
        "structured_table": entry is not None,
        "default_max_spacing_in": entry.get("default_max_spacing_in") if entry else None,
    }


def write_chunks(chunks: list[dict]) -> None:
    CHUNKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    CHUNKS_PATH.write_text(json.dumps(chunks, indent=2, ensure_ascii=False))


def write_spacing(spacing_table: dict) -> None:
    SPACING_PATH.parent.mkdir(parents=True, exist_ok=True)
    SPACING_PATH.write_text(json.dumps(spacing_table, indent=2, ensure_ascii=False))


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
    chunks, spacing_table, report = build_all_chunks(force_parse=force_parse)
    write_chunks(chunks)
    write_spacing(spacing_table)

    report["total_chunks"] = len(chunks)
    report["spacing_cities"] = sorted(spacing_table)
    report["failures"] = _validate(chunks)
    report["chunks_path"] = str(CHUNKS_PATH)

    # Ingest into Moss (rebuild = idempotent).
    report["docs_ingested"] = await ingest_codes(chunks, rebuild=rebuild)

    # Live acceptance query: SF stud spacing should surface the 16" rule.
    sf_top = await lookup_code("San Francisco", "stud spacing for a load bearing wall")
    report["sf_query_top"] = sf_top[0] if sf_top else None

    # Structured spacing: SF (no own table) must resolve to the IRC base 16".
    from ..spacing import get_max_spacing
    report["sf_max_spacing"] = get_max_spacing("San Francisco")

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
    print(f"structured spacing tables: {r.get('spacing_cities')}")

    sms = r.get("sf_max_spacing") or {}
    print("\nSF structured spacing — get_max_spacing('San Francisco') [defaults: 2x4, bearing, one_floor_roof_ceiling]:")
    print(f"  max_spacing_in={sms.get('max_spacing_in')}  via {sms.get('source_city')} {sms.get('code')}")

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
