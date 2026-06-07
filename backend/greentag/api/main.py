"""GreenTag API — a thin surface for testing, the map UI, and iOS fallback.

It imports the SAME `lookup_code` the voice agent uses (no duplicated retrieval
logic). The live voice demo path does NOT go through HTTP — the agent calls
lookup_code in-process to keep latency low. This API is for everything else:
inspect retrieval from a browser, list indexed cities, and upload a new city's
code PDF (which turns it green on the map).

Run:
    uvicorn greentag.api.main:app --reload --port 8000
"""
from __future__ import annotations

import os
import secrets
from pathlib import Path

from fastapi import FastAPI, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from livekit import api as lkapi

from ..ingest.pipeline import ingest_uploaded
from ..moss_codes import lookup_code
from ..registry import list_cities

# The voice worker registers under this name (see agent/src/agent.py
# `@server.rtc_session(agent_name=...)`). Because the agent uses a name, it is
# only dispatched when a token explicitly requests it — which this endpoint does.
AGENT_NAME = "my-agent"

app = FastAPI(title="GreenTag Codes API", version="0.1.0")

# Allow the static map page (and iOS) to call the API from anywhere in dev.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/connection-details")
async def connection_details(
    room: str | None = Query(None, description="room name (generated if omitted)"),
    identity: str | None = Query(None, description="participant identity (generated if omitted)"),
) -> dict:
    """Mint a LiveKit access token for the iOS app and dispatch the voice agent.

    The token carries a RoomConfiguration that dispatches the named agent into
    the room, so the inspector hears the agent as soon as they connect. Keys
    never leave the server — the app only receives a short-lived JWT.
    """
    url = os.environ.get("LIVEKIT_URL")
    api_key = os.environ.get("LIVEKIT_API_KEY")
    api_secret = os.environ.get("LIVEKIT_API_SECRET")
    if not (url and api_key and api_secret):
        raise HTTPException(
            500, "LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured."
        )

    room_name = room or f"greentag-{secrets.token_hex(4)}"
    user_identity = identity or f"inspector-{secrets.token_hex(3)}"

    token = (
        lkapi.AccessToken(api_key, api_secret)
        .with_identity(user_identity)
        .with_name("Inspector")
        .with_grants(
            lkapi.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            )
        )
        .with_room_config(
            lkapi.RoomConfiguration(
                agents=[lkapi.RoomAgentDispatch(agent_name=AGENT_NAME)]
            )
        )
        .to_jwt()
    )

    return {
        "serverUrl": url,
        "roomName": room_name,
        "participantName": user_identity,
        "participantToken": token,
    }


@app.get("/codes/cities")
async def codes_cities() -> dict:
    """Indexed jurisdictions, for coloring the map."""
    return {"cities": list_cities()}


@app.get("/codes/lookup")
async def codes_lookup(
    city: str = Query(..., description="jurisdiction, e.g. 'San Francisco'"),
    q: str = Query(..., description="natural-language code question"),
    top_k: int = Query(3, ge=1, le=10),
) -> dict:
    """Retrieve applicable code chunks for a city (pools the IRC base)."""
    results = await lookup_code(city, q, top_k=top_k)
    return {"city": city, "query": q, "results": results}


@app.post("/ingest/upload")
async def ingest_upload(
    file: UploadFile,
    city: str = Form(...),
    state: str = Form(...),
    code_base: str | None = Form(None),
) -> dict:
    """Upload a city's code PDF -> parse -> index. The city then goes green."""
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(400, "Please upload a PDF file.")
    pdf_bytes = await file.read()
    try:
        result = await ingest_uploaded(pdf_bytes, city=city, state=state, code_base=code_base)
    except Exception as exc:  # surface parse/index errors to the UI
        raise HTTPException(502, f"Ingest failed: {exc}") from exc
    return {"ok": True, **result}


# Serve the static map UI at / (mounted last so it doesn't shadow the API).
_WEB_DIR = Path(__file__).resolve().parent.parent.parent / "web"
if _WEB_DIR.is_dir():
    app.mount("/", StaticFiles(directory=str(_WEB_DIR), html=True), name="web")
