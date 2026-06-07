# GreenTag backend — FastAPI (codes API + map UI). Deploy on Zeabur (or any
# Docker host). Python pinned to 3.12 (3.14 lacks some wheels).
#
# Runtime is light: the Moss index already lives in Moss cloud, so this image
# only queries it (no DB to provision, no ingest at deploy). Set the secrets as
# env vars on the platform — see DEPLOY.md.
FROM python:3.12-slim

WORKDIR /app

# Install deps first for layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code + static map + the generated data the API reads at runtime.
COPY greentag/ ./greentag/
COPY web/ ./web/
COPY data/codes_chunks.json data/spacing_table.json ./data/

# Zeabur injects $PORT; default to 8000 for local `docker run`.
EXPOSE 8000
CMD ["sh", "-c", "uvicorn greentag.api.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
