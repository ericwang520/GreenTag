"""GreenTag backend — building-code retrieval for the voice inspection agent.

Modules:
  config      env/secrets + filesystem paths (single place to read settings)
  moss_codes  Moss retrieval — THE shared lookup path (agent + API import this)
  unsiloed    Unsiloed PDF parse client (offline ingest only)
  ingest/     offline pipeline: parse PDFs -> filter -> chunk -> ingest to Moss
  api/        thin FastAPI surface (test / trigger / iOS fallback)
"""
