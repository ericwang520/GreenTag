# GreenTag backend

The Python side of GreenTag: building-code retrieval for the voice inspection
agent, the offline ingest pipeline, a thin API, and the coverage-map UI.

```
backend/
  greentag/
    config.py        secrets (.env) + filesystem paths
    moss_codes.py    THE shared retrieval module (agent + API import this)
    unsiloed.py      Unsiloed PDF parse client (offline only)
    registry.py      codes_chunks.json as the map's source of truth
    ingest/          parse -> filter -> chunk -> Moss pipeline
    api/main.py      FastAPI: /health /codes/cities /codes/lookup /ingest/upload
  scripts/ingest.py  CLI for the offline pipeline
  web/               SVG US coverage map (served at / by the API)
  data/
    codes_raw/       source PDFs (gitignored; mirrored in agent/data)
    raw/             cached Unsiloed responses (committed; saves quota)
    codes_chunks.json generated chunks (the deliverable)
```

## Setup

Use Python 3.12 (3.14 lacks some wheels). Secrets live in `../.env` (repo root,
gitignored): `UNSILOED_API_KEY`, `MOSS_PROJECT_ID`, `MOSS_PROJECT_KEY`.

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Run the offline ingest (pre-demo batch job — never on the live demo path)

```bash
.venv/bin/python scripts/ingest.py            # uses cached parses
.venv/bin/python scripts/ingest.py --force    # re-parse PDFs (spends Unsiloed quota)
```

Prints a verification report: per-city chunk counts, the skipped electrical PDF,
acceptance checks, and the SF test query's top result.

## Run the API + map

```bash
.venv/bin/uvicorn greentag.api.main:app --port 8000
# open http://localhost:8000/
```

- `GET /codes/cities` — indexed jurisdictions (map coloring)
- `GET /codes/lookup?city=San Francisco&q=stud spacing` — retrieval
- `POST /ingest/upload` — upload a city's code PDF; it then goes green on the map

## How retrieval works

`lookup_code(city, question)` queries the single `building_codes` Moss index with
a hybrid score (`alpha=0.6`), pooling `{city, "IRC (model)"}`. A city's own
amendment wins when relevant; otherwise the IRC base rule surfaces — mirroring US
code adoption (cities inherit the model code and override only specifics). The
voice agent imports `lookup_code` directly (in-process, low latency); the API is
for testing, the map, and iOS fallback.

> Honest framing for the demo: SF and Seattle resolve to the **same** 16"/24"
> numbers (both derive from IRC R602.3(5)). SF didn't amend stud spacing, so it
> falls back to the base; Seattle restates it. The story is "one model code,
> per-city overrides, Moss switches by `city` metadata" — not "different spacing
> per city."
