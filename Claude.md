# StudCheck — CLAUDE.md

> Hackathon project · Moss Conversational AI Hackathon (YC SF, 2026-06-06/07)
> 2-person team · 24h build · 1-minute demo video

## What this project is

**GreenTag** is a hands-free, voice-driven AR inspection assistant for framing contractors.

A contractor points their phone at a framed wall. The app detects the studs, measures
the center-to-center spacing in real time, and a **voice agent** tells them — out loud,
hands-free — whether the spacing passes local building code (16" or 24" on-center) and
what to do next. No typing: contractors are on ladders with gloves and full hands.

**Why it matters:** framing spacing out of spec means tearing the wall down and
re-nailing — thousands of dollars in rework. ~200k US residential contractors face
this daily. Job sites also have poor connectivity, so retrieval must be fast/local.

## Scope (DO NOT exceed for the hackathon)

Build exactly ONE end-to-end loop. Depth > breadth.

- **One inspection item:** wood stud spacing (16"/24" on-center).
- **One+ cities of code** pre-indexed (San Francisco primary; Seattle / IRC as bonus).
- **One demo path:** point → measure → ask out loud → agent answers with a code citation.

Explicitly OUT of scope: login/accounts, other building elements, electrical/plumbing,
live PDF parsing during demo, all 50 states.

## The one demo loop (data flow)

```
Roboflow (detect studs)
   └─> ARKit (measure center-to-center)
          └─> [field_observation JSON]  ──LiveKit data channel (topic="inspection")──┐
                                                                                      v
   User speaks: "Is this one ok?" ──LiveKit audio──> MiniMax STT ──> LLM            Agent worker
                                                                       │  stores latest_observation
                                                                       │  calls tool get_current_reading()
                                                                       │  calls tool lookup_code(city, q)
                                                                       v
                                            Moss query (filter by city) <── Unsiloed-parsed codes (pre-indexed)
                                                                       │
                                                                       v
                                            LLM composes verdict ──> MiniMax TTS ──> spoken answer
```

## Stack (each maps to a sponsor tool — use them all)

| Layer | Tool | Role |
|---|---|---|
| Object detection | **Roboflow** | detect `lumber`/stud in camera frame |
| Measurement | **ARKit** | center-to-center spacing in inches |
| Voice transport | **LiveKit** | realtime audio + data channel between phone and agent |
| Speech + LLM | **MiniMax** | STT, reasoning/verdict, TTS |
| Code parsing | **Unsiloed** | building-code PDFs -> structured chunks (pre-build, offline) |
| Retrieval | **Moss** | semantic search over codes, <10ms, filter by city |

## Key interfaces (contracts both sides build against)

### 1. AR -> Agent: field observation (pure state, no verdict)

Published by the iOS app on LiveKit data channel, topic `"inspection"`, when the reading
is stable. The AR side sends FACTS ONLY. It never decides pass/fail.

```json
{
  "event": "field_observation.updated",
  "source": "greentag_ios",
  "observation_id": "obs_001",
  "timestamp": "2026-06-06T20:10:00Z",
  "inspection_item": "wood_stud_spacing",
  "construction_phase": "framing",
  "location": { "city": "San Francisco", "state": "CA" },
  "measurement": { "spacing_in": 15.25, "confidence": 0.86, "method": "center_to_center", "stable": true },
  "detections": [ { "class": "lumber", "confidence": 0.91 }, { "class": "lumber", "confidence": 0.88 } ]
}
```

The agent worker keeps the latest one as `latest_observation`. It does NOT speak on every
update — it only speaks when the user asks via voice.

### 2. Agent -> Moss: code lookup

`lookup_code(city, question)` (see `moss_codes.py`): loads the `building_codes` index once,
queries with `alpha=0.6` (hybrid) and a metadata filter on `city`. Returns top code chunks
for the LLM to cite.

## Repo layout (target)

```
/ios            # ARKit + Roboflow CoreML app  (Person A)
/agent          # LiveKit worker + MiniMax STT/LLM/TTS  (Person B)
  agent.py            # connects to room, holds latest_observation, defines tools
  moss_codes.py       # ingest + lookup_code (Moss retrieval)
/data
  codes_raw/          # building-code PDFs (input to Unsiloed)
  codes_chunks.json   # Unsiloed output -> ingested into Moss
/tools
  mock_publisher.py   # fake AR feed so /agent can run before iOS is ready
```

## Division of labor

- **Person A — iOS / AR:** ARKit app, Roboflow CoreML model, measure center-to-center,
  AR overlay (green=pass / red=fail visual), publish `field_observation` over LiveKit.
- **Person B — AI / Voice / RAG:** LiveKit worker, MiniMax STT/LLM/TTS, Moss ingest +
  `lookup_code`, agent tools, verdict phrasing. Unblocked by `mock_publisher.py`.

First task for both: agree on the JSON contract above, then build in parallel with mocks.
Integrate in the last ~6h. Reserve ≥2h for recording the demo.

## Conventions & gotchas (read before coding)

- **AR sends facts; agent decides.** Never put pass/fail or `expected_spacing_in` in the
  AR payload. 16 vs 24 depends on load-bearing/wall type — that's the agent + code's call.
- **One Moss index, many cities.** Tag each chunk with `city` metadata; filter at query
  time. Switching city = changing the filter, not the index.
- **Moss query `alpha=0.6`** (hybrid). Pure semantic misses exact tokens like "R602.3".
- **Unsiloed runs offline / pre-demo.** Never parse PDFs live in the demo path.
- **Do NOT claim "works offline."** LiveKit + MiniMax are cloud. Sell Moss's real win:
  sub-10ms retrieval = no awkward voice lag + big token savings.
- **Keep spoken answers short.** Voice judges score "feel"; low latency + crisp > verbose.
- **Confidence gate:** if `measurement.confidence < 0.85`, agent says "re-aim", not a verdict.
- **Name-drop sponsors** in the demo: "retrieval by Moss, parsing by Unsiloed, voice on
  LiveKit + MiniMax."

## Run

```bash
# Agent side
pip install inferedge-moss livekit
export MOSS_PROJECT_ID=...   MOSS_PROJECT_KEY=...
export LIVEKIT_URL=...       LIVEKIT_TOKEN=...

python data/ingest.py          # one-time: load Unsiloed chunks into Moss
python tools/mock_publisher.py # fake AR feed (until iOS is ready)
python agent/agent.py          # start the voice agent worker
```
