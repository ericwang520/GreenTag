# GreenTag — Pokémon GO for AI Construction 🏗️

[GreenTag](https://github.com/ericwang520/GreenTag) is the **AI inspector for the construction site** it checks work against local building codes in real time and catches violations *before* the official inspection, so contractors pass the first time.

> Point your phone at the work. Ask out loud. GreenTag tells you if it's up to code — hands-free.

<p align="center">
  <img width="201" height="437" alt="GreenTag app" src="https://github.com/user-attachments/assets/6568a4a5-f7d5-44b1-b561-c23ef00e43dc" />
</p>

---

## The problem

Framing studs have to sit **16″ on center** (24″ in some cases). If they're even half an inch off-code, the city inspector fails the job and the crew tears the wall down and rebuilds it. That's days of labor and thousands of dollars in rework. And nobody finds out until the official inspection, when it's already too late.

~170k+ U.S. residential contractors live with this risk on every job.

## What GreenTag does

1. **Point** your phone at the framing.
2. GreenTag's **vision model** detects the studs and **ARKit** measures the true center-to-center spacing in AR.
3. **Ask out loud** — "Does this pass?" — and a **voice agent** answers instantly, citing the exact local building code.
4. When you're done, GreenTag generates a full **inspection report**: every stud, its measurement, pass/fail, and the code it was checked against.

No typing. Contractors are on ladders with gloves and full hands — so the whole loop is hands-free.

## How it works

```
 Custom vision model (lumber detection)
        └─► ARKit  ──► center-to-center spacing  ──┐
                                                   │  field_observation (JSON)
                                                   ▼
  "Does this pass?" ──► LiveKit (audio) ──► Deepgram (STT) ──► MiniMax (reasoning · TTS)
                                                   │
                                                   ▼
                              Moss  ◄── building codes (Unsiloed-parsed)
                         <10ms semantic search, filtered by city
                                                   │
                                                   ▼
                          spoken verdict + inspection report
```

**The data layer (how the agent knows every city's rules):**
Building codes are messy, city-specific PDFs. We use **Unsiloed** to parse them into clean, structured rules, and **Moss** as our data-integration layer — it unifies every city's codes and serves the right one to the agent in **under 10 ms**, filtered by location. Switch the city, and the same agent inspects against that city's code — no retraining, just a different filter.

## Tech stack

| Layer | Tool |
|---|---|
| Object detection | Custom-trained model (Roboflow) |
| Spatial measurement | ARKit (center-to-center, inches) |
| Realtime voice transport + orchestration | LiveKit |
| Speech-to-text (STT) | Deepgram (via LiveKit) |
| Reasoning (LLM) + text-to-speech (TTS) | MiniMax |
| Building-code document parsing | Unsiloed |
| Real-time code retrieval / data integration | Moss (<10 ms semantic search) |

## Repo structure

```
ios/                 # ARKit + vision app — detect studs, measure spacing, publish observations
agent/               # LiveKit worker + MiniMax voice agent
  agent.py           #   holds latest observation, defines tools, speaks verdicts
  moss_codes.py      #   Moss ingest + lookup_code (city-filtered retrieval)
data/
  ingest.py          # Unsiloed → Moss pipeline (offline, pre-demo)
  codes_chunks.json  # parsed, city-tagged building-code chunks
tools/
  mock_publisher.py  # fake AR feed so the agent runs before the iOS app is ready
```

## Getting started

```bash
# 1. Install
pip install moss livekit requests python-dotenv   # if `moss` fails, use `inferedge-moss`

# 2. Configure secrets (.env)
cp .env.example .env        # fill in Moss / Unsiloed / LiveKit / MiniMax keys

# 3. Build the building-code index (one-time, offline)
python data/ingest.py       # Unsiloed parses the PDFs → Moss "building_codes" index

# 4. Run the voice agent
python agent/agent.py

# 5. (Optional) simulate the phone before the iOS app is wired up
python tools/mock_publisher.py
```

Currently indexed: **San Francisco** & **Seattle** (with IRC as the model-code fallback). One inspection item: **wood stud spacing**.

## Team

Built by **Eric × Holly** at the **YC Conversational AI Hackathon**, June 6–7, 2026.
Powered by **Moss · Unsiloed · LiveKit · Deepgram · MiniMax**.

---
