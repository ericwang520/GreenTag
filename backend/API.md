# GreenTag API — endpoint reference (for engineers)

Base URL (dev): `http://localhost:8000`
Run it: `cd backend && .venv/bin/uvicorn greentag.api.main:app --port 8000`

Two kinds of endpoints:
- **Structured / deterministic** (`/codes/max-spacing`, `/codes/verdict`) — return a
  hard number. No LLM at request time. Use these for the AR green/red overlay.
- **Prose / retrieval** (`/codes/lookup`) — return code text + citation for the voice
  agent to read out. Hybrid semantic+keyword search (Moss).

City semantics: a query pools the city **and** the IRC base. A city's own amendment
wins when present; otherwise it falls back to IRC. `source_city` / `fallback` tell you
which answered.

`supports` enum (bearing walls): `roof_ceiling_only`, `one_floor_roof_ceiling`
(default), `two_floors_roof_ceiling`, `one_floor_only`.

---

## GET /health

Liveness check.

```bash
curl http://localhost:8000/health
```
```json
{ "status": "ok" }
```

---

## GET /codes/cities

Indexed jurisdictions — used to color the coverage map.

```bash
curl http://localhost:8000/codes/cities
```
```json
{
  "cities": [
    { "city": "San Francisco", "state": "CA", "code": "CRC R602.3 (adopts IRC R602.3(5))", "chunks": 1, "is_base": false },
    { "city": "Seattle", "state": "WA", "code": "Seattle RC R602.3(5)", "chunks": 2, "is_base": false },
    { "city": "IRC (model)", "state": "US", "code": "IRC R602.3(5)", "chunks": 2, "is_base": true }
  ]
}
```
`is_base: true` = the model code that applies everywhere (don't color it as a state).

---

## GET /codes/max-spacing  ★ AR overlay

The hard maximum on-center spacing (inches) for a wall configuration. Deterministic.

| query param | type | default | notes |
|---|---|---|---|
| `city` | string | (required) | e.g. `San Francisco` |
| `stud_size` | string | `2x4` | `2x3` `2x4` `3x4` `2x5` `2x6` |
| `bearing` | bool | `true` | load-bearing wall? |
| `supports` | enum | `one_floor_roof_ceiling` | bearing-wall load case (see enum above) |

```bash
curl "http://localhost:8000/codes/max-spacing?city=San%20Francisco&stud_size=2x4&bearing=true&supports=one_floor_roof_ceiling"
```
```json
{
  "city": "San Francisco",
  "source_city": "IRC (model)",
  "fallback": true,
  "stud_size": "2x4",
  "bearing": true,
  "supports": "one_floor_roof_ceiling",
  "code": "IRC R602.3(5)",
  "section": "R602.3(5)",
  "max_height_ft": 10,
  "basis": "2x4 bearing wall supporting one floor roof ceiling",
  "max_spacing_in": 16,
  "permitted": true
}
```
- `max_spacing_in`: the number to compare against. `null` + `permitted:false` means that
  stud size isn't allowed for the configuration (use a bigger stud or add support).
- `fallback: true` means the city had no own rule and the IRC base answered.

---

## GET /codes/verdict  ★ AR overlay (pass/fail)

`max-spacing` plus a pass/fail against a measured spacing. Pass = `measured_in <= max`.

| query param | type | default | notes |
|---|---|---|---|
| `city` | string | (required) | |
| `measured_in` | float | (required) | center-to-center inches from ARKit |
| `stud_size` `bearing` `supports` | | same defaults as max-spacing | |

```bash
curl "http://localhost:8000/codes/verdict?city=San%20Francisco&measured_in=15.25"
```
```json
{
  "city": "San Francisco", "source_city": "IRC (model)", "fallback": true,
  "stud_size": "2x4", "bearing": true, "supports": "one_floor_roof_ceiling",
  "code": "IRC R602.3(5)", "section": "R602.3(5)", "max_height_ft": 10,
  "basis": "2x4 bearing wall supporting one floor roof ceiling",
  "max_spacing_in": 16, "permitted": true,
  "measured_in": 15.25, "pass": true
}
```
`pass: true` → green overlay; `false` → red. (e.g. `measured_in=18.0` → `pass: false`.)

---

## GET /codes/lookup  (voice RAG)

Retrieve code text + citation for a question. For the agent to read aloud; the live voice
path actually calls this in-process, but it's here for testing / fallback.

| query param | type | default | notes |
|---|---|---|---|
| `city` | string | (required) | |
| `q` | string | (required) | natural-language question |
| `top_k` | int | `3` | 1–10 |

```bash
curl "http://localhost:8000/codes/lookup?city=Seattle&q=stud%20spacing%20load%20bearing&top_k=1"
```
```json
{
  "city": "Seattle",
  "query": "stud spacing load bearing",
  "results": [
    {
      "id": "Seattle__R602.3__4",
      "score": 0.9875,
      "text": "Per Seattle RC Table R602.3(5), wood studs in load-bearing walls are spaced a maximum of 16 inches on center ...",
      "metadata": {
        "city": "Seattle", "state": "WA",
        "code": "Seattle RC R602.3", "section": "R602.3", "topic": "wood stud spacing"
      }
    }
  ]
}
```
The R602.3(5) table document also carries `default_max_spacing_in` and `spacing_json`
(the structured table as a string) in `metadata`.

---

## POST /ingest/upload  (add a city)

Upload a city's code PDF → parsed by Unsiloed → table AI-parsed by MiniMax-M3 → indexed
into Moss. The city then appears in `/codes/cities` (green on the map) and answers
`max-spacing` / `verdict`. **Offline/admin action** — slow (~1-2 min), not on the demo path.

multipart/form-data:

| field | type | notes |
|---|---|---|
| `file` | file | the code PDF |
| `city` | string | e.g. `Austin` |
| `state` | string | 2-letter, e.g. `TX` |
| `code_base` | string (optional) | citation prefix; defaults to `"<city> RC"` |

```bash
curl -F "file=@code.pdf" -F "city=Austin" -F "state=TX" \
  http://localhost:8000/ingest/upload
```
```json
{
  "ok": true,
  "city": "Austin",
  "state": "TX",
  "chunks": 2,
  "structured_table": true,
  "default_max_spacing_in": 16
}
```
- `structured_table: true` → an R602.3(5) table was found and AI-parsed; `max-spacing`
  now works for this city. `false` → no table in the PDF, the city falls back to IRC base.
- Errors: `400` (not a PDF), `502` (parse/index failed, message in `detail`).

---

## GET /connection-details  (voice session — separate workstream)

Mints a LiveKit token and dispatches the voice agent (added by the voice workstream).
Requires `LIVEKIT_URL` / `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` in `.env` (returns 500
without them). The iOS app calls this to start a hands-free session.

```bash
curl "http://localhost:8000/connection-details?room=greentag-demo&identity=inspector-1"
```
```json
{ "serverUrl": "wss://...", "roomName": "greentag-...", "participantToken": "<jwt>" }
```

---

## Which endpoints does the iOS app call?

- **Live verdict overlay:** `GET /codes/verdict` (or `/codes/max-spacing` if you compare
  client-side) — fast, deterministic.
- **Voice session:** `GET /connection-details` to join LiveKit; the spoken answer comes
  from the agent (which uses retrieval in-process, not over HTTP).
- The coverage-map web page uses `/codes/cities`, `/codes/lookup`, `/ingest/upload`.
