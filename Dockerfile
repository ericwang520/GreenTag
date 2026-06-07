# Root Dockerfile — for Railway's GitHub-connected deploy (builds from the repo
# root, so no "Root Directory" service setting is needed). Auto-deploy on push is
# scoped to backend/ via railway.json watchPatterns.
#
# For `railway up` from backend/ or Zeabur (Root Directory = backend), the
# equivalent backend/Dockerfile is used instead.
FROM python:3.12-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/greentag/ ./greentag/
COPY backend/web/ ./web/
COPY backend/data/codes_chunks.json backend/data/spacing_table.json ./data/

EXPOSE 8000
CMD ["sh", "-c", "uvicorn greentag.api.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
