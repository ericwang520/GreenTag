# Deploying the GreenTag backend

The backend is a FastAPI app (codes API + the coverage-map UI). It's stateless at
runtime: the Moss index already lives in **Moss cloud**, so a deploy just queries
it — no database to provision, no ingest step at deploy. The committed
`data/codes_chunks.json` and `data/spacing_table.json` ride in the image.

Both platforms below build the same `backend/Dockerfile` (Python pinned to 3.12).

## Environment variables (both platforms)

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

## Railway (primary)

1. **railway.com → New Project → Deploy from GitHub repo** → pick `ericwang520/GreenTag`.
2. Open the service → **Settings → Root Directory = `backend`**. Railway then reads
   `backend/railway.json`, which builds `backend/Dockerfile` and health-checks `/health`.
3. **Variables** tab → add the env vars from the table above.
4. **Settings → Networking → Generate Domain.** That HTTPS URL serves the map at `/`
   and the API at `/codes/...`. Point the iOS app at it.

Railway injects `$PORT` (the Dockerfile honors it).

### Monorepo: auto-deploy only on backend changes
- **Root Directory = `backend`** scopes the build to this folder.
- **`railway.json` → `build.watchPatterns: ["backend/**"]`** means a push only redeploys
  when files under `backend/` change — edits to `app-ios/` etc. won't trigger a deploy.
  (Watch paths are repo-root relative.) Adjust the glob there to change what's watched.
- Auto-deploy-on-push requires the **GitHub-connected** deploy (the dashboard flow above).
  `railway up` from the CLI is a manual one-shot deploy and does not watch the repo.

### Railway CLI (optional)
```bash
npm i -g @railway/cli
railway login
railway link        # select the project
railway up          # deploy current dir (run from backend/)
railway variables --set MOSS_PROJECT_ID=... --set MOSS_PROJECT_KEY=...
```

## Zeabur (alternative — same Dockerfile)

1. **Zeabur → New Project → Deploy from GitHub** → pick the repo.
2. Set the service **Root Directory to `backend`** (it detects `backend/Dockerfile`).
3. Add the same env vars; **Networking → Generate Domain**.

## Verify after deploy

```bash
curl https://<your-domain>/health                      # {"status":"ok"}
curl https://<your-domain>/codes/cities                # 3 cities
curl "https://<your-domain>/codes/verdict?city=San%20Francisco&measured_in=15.25"
```

## Notes

- The app reads secrets from real env vars (no `.env` needed in prod).
- `POST /ingest/upload` runs Unsiloed (~1-2 min) — fine here (no serverless timeout).
  Uploaded cities persist in Moss; the local `spacing_table.json` cache is ephemeral
  on the container, so an uploaded city's `/codes/max-spacing` may need a re-upload
  after a restart (`/codes/lookup` still works — it's in Moss).
- The **LiveKit voice agent** (under `agent/`) is a separate long-running worker — deploy
  it on LiveKit Cloud agent hosting or its own service, not this one.
