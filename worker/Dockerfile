FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATA_DIR=/data
RUN useradd --create-home --uid 1000 worker && mkdir -p /data && chown worker /data
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY lead_hunter ./lead_hunter
USER worker
VOLUME ["/data"]
ENTRYPOINT ["python", "-m", "lead_hunter"]
CMD ["run"]
