# GreenTag — the AI inspector for the construction site

### 🦺 Pokémon Go for contractors.

**Point your phone at a wall, and a voice-driven AR layer checks the framing against local
building code in real time — so contractors pass inspection the first time.**

Same instinct as the game: raise your phone, and an overlay appears on the real world. But
instead of catching creatures, you're catching code violations before they cost you a wall.

A contractor points their phone at a framed wall. GreenTag detects the studs, measures
the center-to-center spacing in AR, and a voice agent tells them — out loud, hands-free —
whether the spacing passes local code (16" or 24" on-center) and what to do next. No
typing: they're on a ladder, in gloves, with both hands full.

> YC Conversational AI Hackathon · SF · 2026-06-06/07 · built in 24h by **Eric** (iOS/AR) × **Xiya** (AI/Voice/RAG)

---

## Why it matters

Framing spacing that's out of spec means tearing the wall back down and re-nailing —
**thousands of dollars in rework** per miss. ~200k US residential contractors face this
daily, and they catch it only when the official inspector shows up. GreenTag moves that
check to the moment the wall goes up, by voice, with a real code citation behind every
verdict.

---

## The one demo loop

```
Roboflow (detect studs)
   └─> ARKit (measure center-to-center, inches)
          └─> [field_observation JSON]  ──LiveKit data channel (topic="field_observation")──┐
                                                                                             v
   User speaks: "Is this one ok?" ──LiveKit audio──> MiniMax STT ──> LLM               Agent worker
                                                                       │  stores latest_observation
                                                                       │  get_current_reading()
                                                                       │  lookup_code(city, question)
                                                                       v
                                            Moss query (hybrid, filter by city) <── Unsiloed-parsed codes
                                                                       │            (pre-indexed, offline)
                                                                       v
                                            LLM composes verdict ──> MiniMax TTS ──> spoken answer
```

The AR side sends **facts only** — a raw measurement, never a pass/fail. Whether 16" or
24" applies depends on the wall (load-bearing? number of floors?), so the verdict is the
agent's call, grounded in the retrieved code. The agent holds the latest reading and only
speaks when the contractor asks.

---

## Architecture — three pieces

```
  ┌───────────────────────────────────────┐         ┌──────────────────────────────────────────┐
  │            📱 iOS device               │         │              ☁️  Agent worker              │
  │              app-ios/                  │         │                  agent/                    │
  │                                        │         │                                            │
  │  ┌──────────┐   ┌──────────────────┐   │         │   ┌────────────────────────────────────┐   │
  │  │ Roboflow │──▶│ ARKit            │   │  audio  │   │ MiniMax  STT ─▶ LLM ─▶ TTS          │   │
  │  │ (CoreML) │   │ center-to-center │   │◀───────▶│   │          (verdict, spoken, short)  │   │
  │  │  detect  │   │  spacing (in)    │   │  ┌────┐ │   └───────────────┬────────────────────┘   │
  │  └──────────┘   └────────┬─────────┘   │  │ Li │ │       holds latest_observation             │
  │                          │             │  │ ve │ │       get_current_reading()                │
  │   green / red AR overlay │             │  │ Ki │ │                │  lookup_code(city, q)      │
  │                          ▼             │  │ t  │ │                ▼   (in-process import)      │
  │            field_observation JSON ─────┼─▶│    │─┼─▶ ┌────────────────────────────────────┐   │
  │            (facts only, no verdict)    │  └────┘ │   │           backend/                 │   │
  │                                        │   data  │   │   moss_codes.lookup_code()         │   │
  └────────────────────────────────────────┘  channel│   │   Moss index ◀─ Unsiloed chunks    │   │
                                                      │   │   (hybrid α=0.6, filter by city)   │   │
                                                      │   │   FastAPI /codes/* + US map        │   │
                                                      │   └────────────────────────────────────┘   │
                                                      └──────────────────────────────────────────┘
        Roboflow · ARKit            ──── LiveKit ────            MiniMax            Moss · Unsiloed
```

| Directory | Owner | What it does |
|---|---|---|
| [`app-ios/`](app-ios/) | Eric | SwiftUI + ARKit app. Roboflow CoreML model detects lumber, ARKit measures center-to-center spacing, AR overlay shows green/red, and it publishes `field_observation` events over the LiveKit data channel + streams mic audio. |
| [`agent/`](agent/README.md) | Xiya | LiveKit Agents voice worker. MiniMax STT → LLM → TTS. Holds the latest observation, exposes `get_current_reading()` and a code-lookup tool, and speaks short verdicts with citations. |
| [`backend/`](backend/README.md) | Xiya | Moss retrieval (`lookup_code`), the offline Unsiloed ingest pipeline, a FastAPI service, and a US coverage map. The agent imports `lookup_code` **in-process** for sub-10ms retrieval. |

The agent and backend share one Python workspace, so the voice loop calls Moss directly
(no network hop). iOS talks to the agent purely over LiveKit.

---

## The stack — every layer is a sponsor tool

| Layer | Tool | Role |
|---|---|---|
| Object detection | **Roboflow** | detect `lumber`/stud in the camera frame (CoreML, on-device) |
| Measurement | **ARKit** | center-to-center spacing in inches |
| Voice transport | **LiveKit** | realtime audio + data channel between phone and agent |
| Speech + LLM | **MiniMax** | STT, reasoning/verdict, TTS |
| Code parsing | **Unsiloed** | building-code PDFs → structured chunks (offline, pre-demo) |
| Retrieval | **Moss** | semantic + keyword search over codes, <10ms, filter by city |

> *Parsing by Unsiloed, retrieval by Moss, voice on LiveKit + MiniMax, detection by Roboflow, measurement in ARKit.*

---

## What's working

- **Real ARKit measurement** of center-to-center stud spacing, with an on-device green/red overlay.
- **On-device Roboflow CoreML** lumber detection feeding the measurement.
- **Full MiniMax voice loop** — STT → LLM verdict → TTS — over LiveKit, answering live spoken questions.
- **Moss retrieval** over building codes pre-parsed by Unsiloed, tagged by city, queried hybrid (`alpha=0.6`) so exact tokens like `R602.3` still hit.
- **Four jurisdictions indexed**: San Francisco, Seattle, Austin, and the IRC model code as the base.
- **A US coverage map** (served by the backend) showing which cities are live.

**Honest framing:** SF and Seattle resolve to the *same* 16"/24" numbers — both derive from
IRC `R602.3(5)`. The story isn't "different spacing per city"; it's *one model code with
per-city overrides, and Moss switching jurisdiction by `city` metadata*. And nothing here is
offline — LiveKit and MiniMax are cloud. Moss's real win is **sub-10ms retrieval = no voice
lag and big token savings**.

---

## Quickstart

Each component has its own README with full setup. The short version:

```bash
# 1. Backend — build the Moss index from pre-parsed code chunks (one-time, offline)
cd backend && .venv/bin/python scripts/ingest.py     # see backend/README.md

# 2. Agent — start the LiveKit voice worker (imports the backend's lookup_code)
cd agent && uv run python src/agent.py dev            # see agent/README.md

# 3. iOS — open app-ios/ in Xcode and run on a device with ARKit + camera
```

Secrets live in the repo-root `.env` (gitignored): `MOSS_PROJECT_ID`, `MOSS_PROJECT_KEY`,
`UNSILOED_API_KEY`, plus the LiveKit and MiniMax credentials.

- **Agent setup & run** → [`agent/README.md`](agent/README.md)
- **Backend retrieval, ingest & API** → [`backend/README.md`](backend/README.md) · [`backend/API.md`](backend/API.md)
- **iOS → agent event contract** → [`schema.md`](schema.md)

---

## Team

| | |
|---|---|
| **Eric** | iOS / AR — ARKit, Roboflow CoreML, measurement, LiveKit publishing |
| **Xiya** | AI / Voice / RAG — LiveKit worker, MiniMax STT/LLM/TTS, Moss + Unsiloed |

Built for the YC Conversational AI Hackathon, San Francisco, June 2026.
