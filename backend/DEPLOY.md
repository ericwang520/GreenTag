# Deploying the GreenTag backend on Zeabur

The backend is a FastAPI app (codes API + the coverage-map UI). It's stateless at
runtime: the Moss index already lives in **Moss cloud**, so a deploy just queries
it — no database to provision, no ingest step at deploy. The committed
`data/codes_chunks.json` and `data/spacing_table.json` ride in the image.

## Steps

1. **Zeabur → New Project → Deploy from GitHub** → pick `ericwang520/GreenTag`.
2. **Set the service Root Directory to `backend`.** Zeabur detects `backend/Dockerfile`
   and builds from it (Python pinned to 3.12).
3. **Add environment variables** (Service → Variables):

   | var | required for | notes |
   |---|---|---|
   | `MOSS_PROJECT_ID` | retrieval (all `/codes/*`) | from Moss |
   | `MOSS_PROJECT_KEY` | retrieval | from Moss |
   | `UNSILOED_API_KEY` | `POST /ingest/upload` only | parsing uploaded PDFs |
   | `MINIMAX_API_KEY` | `POST /ingest/upload` only | AI table parsing |
   | `LIVEKIT_URL` | `GET /connection-details` | voice session token |
   | `LIVEKIT_API_KEY` | `GET /connection-details` | |
   | `LIVEKIT_API_SECRET` | `GET /connection-details` | |

   Minimum to serve the map + retrieval + structured spacing: the two `MOSS_*` vars.
   Add Unsiloed/MiniMax to enable city uploads; add LiveKit for the voice token.

4. **Networking → generate a domain.** That HTTPS URL serves the map at `/` and the
   API at `/codes/...`. Point the iOS app at it.

Zeabur auto-redeploys on push to the deployed branch.

## Verify after deploy

```bash
curl https://<your-domain>/health                      # {"status":"ok"}
curl https://<your-domain>/codes/cities                # 3 cities
curl "https://<your-domain>/codes/verdict?city=San%20Francisco&measured_in=15.25"
```

## Notes

- `$PORT` is injected by Zeabur; the Dockerfile honors it.
- The app reads secrets from real env vars (no `.env` needed in prod).
- `POST /ingest/upload` runs Unsiloed (~1-2 min) — fine here (no serverless timeout).
  Uploaded cities persist in Moss; the local `spacing_table.json` cache is ephemeral
  on the container, so an uploaded city's `/codes/max-spacing` may need a re-upload
  after a restart (retrieval via `/codes/lookup` still works — it's in Moss).
- The **LiveKit voice agent** (under `agent/`) is a separate long-running worker — deploy
  it on LiveKit Cloud agent hosting or its own Zeabur service, not this one.
