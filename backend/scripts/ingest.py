#!/usr/bin/env python
"""CLI entry for the offline ingest pipeline.

    python scripts/ingest.py            # parse (cached) -> chunk -> ingest -> verify
    python scripts/ingest.py --force    # re-parse PDFs via Unsiloed (spends quota)
    python scripts/ingest.py --no-rebuild   # upsert instead of rebuilding the index

Run from the backend/ directory (or anywhere — paths are anchored to backend/).
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

# Allow running as a script: add backend/ to sys.path so `greentag` imports.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from greentag.ingest.pipeline import run_ingest  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="GreenTag building-code ingest pipeline")
    parser.add_argument("--force", action="store_true", help="re-parse PDFs (spends Unsiloed quota)")
    parser.add_argument("--no-rebuild", action="store_true", help="upsert instead of rebuilding index")
    args = parser.parse_args()

    report = asyncio.run(run_ingest(force_parse=args.force, rebuild=not args.no_rebuild))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
