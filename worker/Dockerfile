# Contexto de build: raiz do repositório (docker build -f worker/Dockerfile .)
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATA_DIR=/data MIGRATIONS_DIR=/app/supabase/migrations
RUN useradd --create-home --uid 1000 worker && mkdir -p /data && chown worker /data
WORKDIR /app/worker
COPY worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker/lead_hunter ./lead_hunter
COPY supabase/migrations /app/supabase/migrations
USER worker
VOLUME ["/data"]
ENTRYPOINT ["python", "-m", "lead_hunter"]
CMD ["run"]
