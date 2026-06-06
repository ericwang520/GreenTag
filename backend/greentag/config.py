"""Configuration: secrets and filesystem paths.

Secrets load from a `.env` at the monorepo root (gitignored). Each consumer
requires only the keys it needs — the runtime retrieval path (Moss) must not
fail just because the offline Unsiloed key is absent, and vice versa.
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import find_dotenv, load_dotenv

# Walk up from cwd to find the repo-root .env, then load it.
load_dotenv(find_dotenv(usecwd=True))

# --- Paths (anchored to backend/, independent of cwd) -----------------------
BACKEND_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BACKEND_DIR / "data"
CODES_RAW_DIR = DATA_DIR / "codes_raw"     # source PDFs (input to Unsiloed)
RAW_CACHE_DIR = DATA_DIR / "raw"           # cached Unsiloed responses
CHUNKS_PATH = DATA_DIR / "codes_chunks.json"  # pipeline output

# --- Moss ------------------------------------------------------------------
MOSS_INDEX = "building_codes"  # ONE index; cities separated by `city` metadata


def require_env(name: str) -> str:
    """Return env var `name` or fail fast with an actionable message."""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(
            f"Missing required env var {name!r}. "
            f"Add it to .env at the repo root ({BACKEND_DIR.parent}/.env)."
        )
    return value


def moss_credentials() -> tuple[str, str]:
    """(project_id, project_key) for Moss — needed by retrieval + ingest."""
    return require_env("MOSS_PROJECT_ID"), require_env("MOSS_PROJECT_KEY")


def unsiloed_api_key() -> str:
    """Unsiloed API key — needed by the offline parse step only."""
    return require_env("UNSILOED_API_KEY")
